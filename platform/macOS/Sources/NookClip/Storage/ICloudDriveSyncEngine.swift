import Foundation
import Observation
import os

public enum CloudSyncMode: String, CaseIterable, Identifiable {
    case iCloudDrive = "icloud"
    case localDirectory = "local_dir"
    case webdav = "webdav"

    public var id: String { rawValue }

    /// 当前版本在设置页真正开放给用户选择的同步通道。
    ///
    /// 本地目录映射与 WebDAV 暂时关闭入口（「先关闭」）：引擎能力、Keychain 凭据与
    /// 各通道独立配置全部保留，只是不再出现在「同步方式」选择器里，用户也无法切过去。
    /// 后续版本要重新放开时，只要把对应 case 加回本数组，设置页与迁移逻辑会一起生效。
    public static let userSelectableModes: [CloudSyncMode] = [.iCloudDrive]

    /// 该通道是否对用户可见可选
    public var isUserSelectable: Bool { Self.userSelectableModes.contains(self) }
}

/// 多端云同步管理引擎：管理同步通道（iCloud / 本地目录 / WebDAV）、密钥与触发器调度。
@Observable
final class ICloudDriveSyncEngine {
    static let shared = ICloudDriveSyncEngine()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.lx3xun.nookclip",
        category: "ICloudDriveSyncEngine"
    )

    private(set) var state: SyncState = .idle
    private(set) var lastSyncDate: Date?
    private(set) var lastSyncResult: SyncResult = .idle
    /// 敏感同步配置版本号（可观测）。
    ///
    /// E2EE 开关、口令、敏感同步开关都落在 UserDefaults / Keychain，`@Observation` 追踪不到
    /// 这些读取，视图若直接依赖 `isE2EESensitiveSyncActive` 这类派生判定，用户改完设置后
    /// 不会收到失效通知（预览区胶囊会继续显示旧文案）。因此在全部写入路径上自增本版本号，
    /// 并在派生判定里读一次它，让 SwiftUI 的观测依赖落在真的会变的东西上。
    private(set) var sensitiveSyncConfigRevision: Int = 0
    var onRemoteChange: (() -> Void)?
    @ObservationIgnored var onDebouncedPush: (() async -> Void)?
    @ObservationIgnored private var pushDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var lastPullAt: Date?

    @MainActor
    func updateObservableState(_ newState: SyncState, lastSyncDate: Date? = nil) {
        state = newState
        if let lastSyncDate {
            self.lastSyncDate = lastSyncDate
        }
    }

    @MainActor
    func recordSuccess(_ date: Date = Date()) {
        lastSyncResult = .success(date)
        updateObservableState(.success(date), lastSyncDate: date)
    }

    @MainActor
    func recordFailure(_ error: Error, at date: Date = Date()) {
        let reason = SyncFailureReason.from(error: error, syncMode: syncMode)
        lastSyncResult = .failure(reason, at: date)
        updateObservableState(.failed(reason.localizedDescription))
    }

    @MainActor
    func recordFailureMessage(_ message: String, at date: Date = Date()) {
        lastSyncResult = .failure(.custom(message), at: date)
        updateObservableState(.failed(message))
    }
    @MainActor
    func schedulePushDebounce() {
        guard isEnabled else { return }
        pushDebounceTask?.cancel()
        pushDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.onDebouncedPush?()
        }
    }

    func shouldPull(minInterval: TimeInterval?) -> Bool {
        guard let minInterval, let lastPullAt else { return true }
        return Date().timeIntervalSince(lastPullAt) >= minInterval
    }

    func markPulled() {
        lastPullAt = Date()
    }

    private static let syncModeDefaultsKey = "nook.sync.mode"
    private static let isSyncEnabledDefaultsKey = "enableICloudSync"
    private var isSyncEnabledKey: String { Self.isSyncEnabledDefaultsKey }
    private var syncModeKey: String { Self.syncModeDefaultsKey }
    private let webDavUrlKey = "nook.sync.webdav.url"
    private let webDavUsernameKey = "nook.sync.webdav.username"
    private let isE2EEEnabledKey = "nook.sync.e2ee.enabled"
    private let syncSensitiveKey = "nook.sync.e2ee.syncSensitive"

    private let defaults: UserDefaults
    private let repository: CloudFileRepository
    private let monitor: CloudDirectoryMonitor
    @ObservationIgnored private var webDavPollingTimer: Timer?
    @ObservationIgnored private var quickPopoverObserver: NSObjectProtocol?
    @ObservationIgnored private let keychainCacheLock = NSLock()
    @ObservationIgnored private var cachedWebDavPassword: String?
    @ObservationIgnored private var cachedE2EEPassphrases: [CloudSyncMode: String] = [:]
    @ObservationIgnored private let secretStore: SyncSecretStore
    /// 旧钥匙串读取入口（仅用于一次性迁移）。测试可注入假实现，避免真的写系统钥匙串。
    @ObservationIgnored private let legacySecretReader: (_ service: String, _ account: String) -> String?

    /// - Parameters:
    ///   - secretsNamespace: 仅测试使用，给同步密钥文件加命名后缀，避免用例之间互相污染。
    ///   - legacySecretReader: 仅测试使用，替换旧钥匙串读取。
    init(
        customBaseURL: URL? = nil,
        defaults: UserDefaults = .standard,
        secretsNamespace: String? = nil,
        secretStoreDirectory: URL? = nil,
        legacySecretReader: ((_ service: String, _ account: String) -> String?)? = nil
    ) {
        self.defaults = defaults
        self.repository = CloudFileRepository(defaults: defaults, customBaseURL: customBaseURL)
        self.monitor = CloudDirectoryMonitor()
        // 测试进程里每个引擎实例默认独立命名空间，避免用例之间口令互相串味。
        let isTestProcess = NSClassFromString("XCTestCase") != nil
        let namespace = secretsNamespace ?? (isTestProcess ? "inst-\(UUID().uuidString)" : nil)
        self.secretStore = SyncSecretStore(
            directoryURL: secretStoreDirectory ?? SyncSecretStore.defaultDirectory(),
            namespace: namespace
        )
        self.legacySecretReader = legacySecretReader ?? { service, account in
            LegacySyncKeychainReader.readPassword(service: service, account: account)
        }
        monitor.onDirectoryChange = { [weak self] in
            self?.onRemoteChange?()
        }
        Self.migrateUnsupportedSyncMode(in: defaults)
    }

    /// 「本地目录映射 / WebDAV」入口已关闭：启动时把遗留在这两条通道上的用户收敛回 iCloud。
    ///
    /// 两个动作：
    /// 1. 通道写回 iCloud——否则设置页里选不到这两条通道，实际同步却仍在走 WebDAV 轮询或
    ///    自定义目录，界面与真实行为对不上；
    /// 2. 同时关闭同步开关——不能默默把原本只走自建 WebDAV / 指定目录的数据改道 iCloud，
    ///    这是用户没同意过的数据流向。开关留给用户自己重新打开，那时明确就是 iCloud 同步。
    ///
    /// 通道专属配置（WebDAV 地址 / 用户名 / Keychain 口令 / 各通道 E2EE 与敏感同步开关）
    /// 一律原样保留——后续版本重新放开时，用户不必重新配置。
    private static func migrateUnsupportedSyncMode(in defaults: UserDefaults) {
        guard let raw = defaults.string(forKey: Self.syncModeDefaultsKey),
              let stored = CloudSyncMode(rawValue: raw),
              !stored.isUserSelectable else { return }
        defaults.set(CloudSyncMode.iCloudDrive.rawValue, forKey: Self.syncModeDefaultsKey)
        defaults.set(false, forKey: Self.isSyncEnabledDefaultsKey)
        logger.notice(
            "Sync mode \(raw, privacy: .public) is no longer user-selectable; moved to iCloud and sync disabled"
        )
    }

    // MARK: - 开关与通道模式

    var isEnabled: Bool {
        get {
            defaults.bool(forKey: isSyncEnabledKey)
        }
        set {
            defaults.set(newValue, forKey: isSyncEnabledKey)
            if newValue {
                setupSyncTriggers()
            } else {
                stopSyncTriggers()
            }
        }
    }

    var syncMode: CloudSyncMode {
        get {
            let raw = defaults.string(forKey: syncModeKey) ?? CloudSyncMode.iCloudDrive.rawValue
            return CloudSyncMode(rawValue: raw) ?? .iCloudDrive
        }
        set {
            defaults.set(newValue.rawValue, forKey: syncModeKey)
            bumpSensitiveSyncConfigRevision()
            setupSyncTriggers()
        }
    }

    var webDavURL: String {
        get { defaults.string(forKey: webDavUrlKey) ?? "" }
        set { defaults.set(newValue, forKey: webDavUrlKey) }
    }

    var webDavUsername: String {
        get { defaults.string(forKey: webDavUsernameKey) ?? "" }
        set { defaults.set(newValue, forKey: webDavUsernameKey) }
    }

    private var isTestingEnvironment: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    /// 旧版本把这些口令存在系统钥匙串里，服务名固定（前缀仅测试使用）。
    private var legacyWebDavKeychainService: String {
        isTestingEnvironment ? "test.nook.webdav.\(ProcessInfo.processInfo.processIdentifier)" : "com.lx3xun.nookclip.webdav"
    }

    private var legacyE2EEKeychainService: String {
        isTestingEnvironment ? "test.nook.e2ee.\(ProcessInfo.processInfo.processIdentifier)" : "com.lx3xun.nookclip.e2ee"
    }

    var webDavPassword: String {
        get {
            if let cached = keychainCacheLock.withLock({ cachedWebDavPassword }) {
                return cached
            }
            let account = "webdav_account"
            let value = resolveSecret(account: account, legacyService: legacyWebDavKeychainService)
            // 已完成一次性迁移（或已有非空值）时直接缓存，避免空口令用户反复查询系统钥匙串；
            // 仅在同步未开启、尚未尝试迁移时保留 nil，待开启同步后再做唯一一次迁移尝试。
            if !value.isEmpty || hasMigratedSecret(for: account) {
                keychainCacheLock.withLock { cachedWebDavPassword = value }
            }
            return value
        }
        set {
            let account = "webdav_account"
            keychainCacheLock.withLock { cachedWebDavPassword = newValue }
            secretStore.setValue(newValue, for: account)
            markSecretMigrated(for: account)
        }
    }

    private func secretMigratedKey(for account: String) -> String {
        "nook.sync.secretMigrated.\(account)"
    }

    private func hasMigratedSecret(for account: String) -> Bool {
        defaults.bool(forKey: secretMigratedKey(for: account))
    }

    private func markSecretMigrated(for account: String) {
        defaults.set(true, forKey: secretMigratedKey(for: account))
    }

    /// 同步密钥（E2EE 口令 / WebDAV 密码）统一读取入口。
    ///
    /// 1. 先读 0600 文件——正常路径，完全本地、不触发任何系统授权弹窗；
    /// 2. 文件里还没有时，**仅在同步开关打开且该账号尚未尝试过迁移时**从旧钥匙串读取一次，
    ///    无论旧钥匙串中有无条目都立刻标记「已迁移」，读到非空值则落盘。
    ///    这样：
    ///    - 「同步关闭」的用户（默认状态）启动、开设置页都不会碰钥匙串；
    ///    - 「同步开启但未设口令」的用户最多只查一次旧钥匙串，不会每次渲染都穿透 IPC；
    ///    - 用户主动清空口令后重启，不会再从保留在旧钥匙串里的条目「复活」旧口令。
    /// 迁移后旧条目保留不删：用户若回退到旧版本仍能读到口令。
    private func resolveSecret(account: String, legacyService: String) -> String {
        if let value = secretStore.value(for: account) {
            if !hasMigratedSecret(for: account) {
                markSecretMigrated(for: account)
            }
            return value
        }
        guard isEnabled, !hasMigratedSecret(for: account) else { return "" }
        markSecretMigrated(for: account)
        guard let legacyValue = legacySecretReader(legacyService, account),
              !legacyValue.isEmpty else {
            return ""
        }
        secretStore.setValue(legacyValue, for: account)
        Self.logger.notice("Migrated sync secret \(account, privacy: .public) from Keychain to 0600 file")
        return legacyValue
    }

    // MARK: - 多通道独立配置存储键与读写

    private func e2eeEnabledKey(for mode: CloudSyncMode) -> String {
        "nook.sync.e2ee.enabled.\(mode.rawValue)"
    }

    private func syncSensitiveKey(for mode: CloudSyncMode) -> String {
        "nook.sync.e2ee.syncSensitive.\(mode.rawValue)"
    }

    private func e2eeKeychainAccount(for mode: CloudSyncMode) -> String {
        "sync_passphrase_\(mode.rawValue)"
    }

    func isE2EEEnabled(for mode: CloudSyncMode) -> Bool {
        let key = e2eeEnabledKey(for: mode)
        if defaults.object(forKey: key) != nil {
            return defaults.bool(forKey: key)
        }
        // WebDAV 或 本地网盘（OneDrive / Dropbox 等第三方网盘）默认开启端到端加密，促使用户配置同步口令
        if mode == .webdav || mode == .localDirectory {
            return defaults.object(forKey: isE2EEEnabledKey) != nil ? defaults.bool(forKey: isE2EEEnabledKey) : true
        }
        return false
    }

    func setE2EEEnabled(_ enabled: Bool, for mode: CloudSyncMode) {
        defaults.set(enabled, forKey: e2eeEnabledKey(for: mode))
        bumpSensitiveSyncConfigRevision()
    }

    func e2eePassphrase(for mode: CloudSyncMode) -> String {
        if let cached = keychainCacheLock.withLock({ cachedE2EEPassphrases[mode] }) {
            return cached
        }

        let account = e2eeKeychainAccount(for: mode)
        // 两代旧格式都要迁：先按通道后缀（旧钥匙串的账号名与本文件的键同名，可直接搬迁），
        // 再兜底更早的单通道 "sync_passphrase"，迁完立刻清掉兜底键并打上已迁移标记，
        // 避免「用户清空口令后下次又读回旧值」或跨通道串味。
        var resolved = resolveSecret(account: account, legacyService: legacyE2EEKeychainService)
        if resolved.isEmpty {
            let legacyPass = resolveSecret(account: "sync_passphrase", legacyService: legacyE2EEKeychainService)
            if !legacyPass.isEmpty {
                secretStore.setValue(legacyPass, for: account)
                secretStore.setValue(nil, for: "sync_passphrase")
                resolved = legacyPass
            }
        }
        // 已完成一次性迁移（或已有非空值）时缓存结果（含空字符串），防止空口令反复穿透；
        // 仅在同步关闭、尚未执行迁移时保持未缓存，待同步开启后再触发唯一一次迁移。
        if !resolved.isEmpty || hasMigratedSecret(for: account) {
            keychainCacheLock.withLock { cachedE2EEPassphrases[mode] = resolved }
        }
        return resolved
    }

    func setE2EEPassphrase(_ pass: String, for mode: CloudSyncMode) {
        let account = e2eeKeychainAccount(for: mode)
        keychainCacheLock.withLock { cachedE2EEPassphrases[mode] = pass }
        secretStore.setValue(pass, for: account)
        markSecretMigrated(for: account)
        markSecretMigrated(for: "sync_passphrase")
        if pass.isEmpty {
            secretStore.setValue(nil, for: "sync_passphrase")
        }
        bumpSensitiveSyncConfigRevision()
    }

    /// 只要有写入路径改动「E2EE 开关 / 口令 / 敏感同步开关」之一，就让派生判定失效。
    /// 主线程写入是常态（设置页、引导弹窗）；跨线程写入时把失效通知转回主线程，
    /// 避免在后台线程上触发 SwiftUI 的观测变更。
    private func bumpSensitiveSyncConfigRevision() {
        if Thread.isMainThread {
            sensitiveSyncConfigRevision &+= 1
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.sensitiveSyncConfigRevision &+= 1
            }
        }
    }

    /// 敏感条目跨端同步**实际生效**的唯一判定点：必须同时满足
    /// 1) E2EE 已开启；2) 本机口令非空；3) 用户显式开启「同步敏感数据」。
    /// 设置页文案、一次性引导与 `SyncOptions.allowSensitive` 全部派生自本判定，
    /// 避免出现「文案说已加密同步、实际走明文拉取」的状态漂移。
    func isE2EESensitiveSyncActive(for mode: CloudSyncMode) -> Bool {
        // 同步整体关闭时，敏感条目必然只留在本机：直接返回 false，
        // 顺带避免为了回答这个问题去读口令（钥匙串/文件都不碰）。
        guard isEnabled else { return false }
        guard isE2EEEnabled(for: mode), syncSensitiveItems(for: mode) else { return false }
        return !e2eePassphrase(for: mode).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isE2EESensitiveSyncActive: Bool {
        // 读一次版本号：判定本身来自 UserDefaults / Keychain，不可观测；
        // 依赖版本号才能让预览区胶囊等 UI 在设置变更后立刻失效重算。
        _ = sensitiveSyncConfigRevision
        return isE2EESensitiveSyncActive(for: syncMode)
    }

    /// 一次性引导是否已完成（按通道独立记录）。
    /// 未完成时，敏感条目的跨端同步策略仍保持旧的安全默认（仅本机）。
    func hasDecidedSensitiveSync(for mode: CloudSyncMode) -> Bool {
        defaults.object(forKey: sensitiveSyncDecidedKey(for: mode)) != nil
    }

    func markSensitiveSyncDecided(for mode: CloudSyncMode) {
        defaults.set(true, forKey: sensitiveSyncDecidedKey(for: mode))
    }

    private func sensitiveSyncDecidedKey(for mode: CloudSyncMode) -> String {
        "nook.sync.e2ee.syncSensitiveDecided.\(mode.rawValue)"
    }

    func syncSensitiveItems(for mode: CloudSyncMode) -> Bool {
        let key = syncSensitiveKey(for: mode)
        if defaults.object(forKey: key) != nil {
            return defaults.bool(forKey: key)
        }
        return false
    }

    func setSyncSensitiveItems(_ allowed: Bool, for mode: CloudSyncMode) {
        defaults.set(allowed, forKey: syncSensitiveKey(for: mode))
        bumpSensitiveSyncConfigRevision()
    }

    var isE2EEEnabled: Bool {
        get { isE2EEEnabled(for: syncMode) }
        set { setE2EEEnabled(newValue, for: syncMode) }
    }

    var e2eePassphrase: String {
        get { e2eePassphrase(for: syncMode) }
        set { setE2EEPassphrase(newValue, for: syncMode) }
    }

    var syncSensitiveItems: Bool {
        get { syncSensitiveItems(for: syncMode) }
        set { setSyncSensitiveItems(newValue, for: syncMode) }
    }
    func makeSyncOptions(deviceId: String, localAssetsDir: String) -> SyncOptions {
        makeSyncOptionsSync(deviceId: deviceId, localAssetsDir: localAssetsDir)
    }

    private func makeSyncOptionsSync(deviceId: String, localAssetsDir: String) -> SyncOptions {
        let backend: SyncBackendConfig
        switch syncMode {
        case .iCloudDrive, .localDirectory:
            backend = .localDirectory(syncDir: baseDirectoryURL.path)
        case .webdav:
            backend = .webDav(
                baseUrl: webDavURL.trimmingCharacters(in: .whitespacesAndNewlines),
                username: webDavUsername.trimmingCharacters(in: .whitespacesAndNewlines),
                password: webDavPassword,
                timeoutSecs: 15
            )
        }
        let trimmedPass = isE2EEEnabled ? e2eePassphrase.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let hasValidPass = isE2EEEnabled && !trimmedPass.isEmpty
        return SyncOptions(
            backend: backend,
            deviceId: deviceId,
            localAssetsDir: localAssetsDir,
            passphrase: hasValidPass ? trimmedPass : nil,
            allowSensitive: hasValidPass && syncSensitiveItems
        )
    }

    /// 异步构造同步选项。
    ///
    /// 口令已改为 0600 本地文件存储（不再访问钥匙串），读取是纯本地 IO，
    /// 但仍保留 async 形态：调用点已在后台/异步上下文，且避免后续再改签名。
    func makeSyncOptionsAsync(deviceId: String, localAssetsDir: String) async -> SyncOptions {
        let mode = syncMode
        let syncDir = baseDirectoryURL.path
        let webdavURL = webDavURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let webdavUser = webDavUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let e2eeEnabled = isE2EEEnabled
        let sensitiveAllowed = syncSensitiveItems

        let passphrase = e2eeEnabled ? e2eePassphrase(for: mode) : ""
        let webdavPass = (mode == .webdav) ? webDavPassword : ""

        let backend: SyncBackendConfig
        switch mode {
        case .iCloudDrive, .localDirectory:
            backend = .localDirectory(syncDir: syncDir)
        case .webdav:
            backend = .webDav(
                baseUrl: webdavURL,
                username: webdavUser,
                password: webdavPass,
                timeoutSecs: 15
            )
        }
        let trimmedPass = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasValidPass = e2eeEnabled && !trimmedPass.isEmpty
        return SyncOptions(
            backend: backend,
            deviceId: deviceId,
            localAssetsDir: localAssetsDir,
            passphrase: hasValidPass ? trimmedPass : nil,
            // 与同步路径同源：口令非空 + 加密开启 + 用户显式开启敏感同步
            allowSensitive: hasValidPass && sensitiveAllowed
        )
    }

    var baseDirectoryURL: URL {
        if repository.hasExplicitBaseDirectoryURL {
            return repository.baseDirectoryURL
        }
        switch syncMode {
        case .iCloudDrive:
            return repository.defaultICloudDirectoryURL
        case .localDirectory:
            return repository.customLocalDirectoryURL
        case .webdav:
            return repository.defaultICloudDirectoryURL
        }
    }
    var devicesDirectoryURL: URL { baseDirectoryURL.appendingPathComponent("devices", isDirectory: true) }
    var assetsDirectoryURL: URL { baseDirectoryURL.appendingPathComponent("assets", isDirectory: true) }

    // MARK: - 目录配置与权限

    func setCustomDirectory(url: URL) throws {
        try repository.setCustomDirectory(url)
        setupDirectoryMonitoring()
    }

    func resetToDefaultDirectory() {
        repository.resetToDefaultDirectory()
        setupDirectoryMonitoring()
    }

    func ensureDirectoriesExist() throws {
        let fm = FileManager.default
        for dir in [devicesDirectoryURL, assetsDirectoryURL] {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
    }

    // MARK: - 目录与网络触发器

    func setupSyncTriggers() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.setupSyncTriggers()
            }
            return
        }
        stopSyncTriggers()
        guard isEnabled else { return }
        quickPopoverObserver = NotificationCenter.default.addObserver(
            forName: .quickPopoverDidOpen,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onRemoteChange?()
        }
        switch syncMode {
        case .iCloudDrive, .localDirectory:
            try? ensureDirectoriesExist()
            monitor.start(watching: devicesDirectoryURL)
        case .webdav:
            guard !webDavURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            // 后台自适应轻量轮询：每 45 秒探测一次远端变更（有指纹缓存，未变则 0 下载）
            let timer = Timer(timeInterval: 45.0, repeats: true) { [weak self] _ in
                self?.onRemoteChange?()
            }
            timer.tolerance = 10.0
            RunLoop.main.add(timer, forMode: .common)
            self.webDavPollingTimer = timer
        }
    }

    func stopSyncTriggers() {
        monitor.stop()
        if Thread.isMainThread {
            webDavPollingTimer?.invalidate()
            webDavPollingTimer = nil
        } else {
            let timer = webDavPollingTimer
            webDavPollingTimer = nil
            DispatchQueue.main.async {
                timer?.invalidate()
            }
        }
        if let obs = quickPopoverObserver {
            NotificationCenter.default.removeObserver(obs)
            quickPopoverObserver = nil
        }
    }

    func setupDirectoryMonitoring() {
        setupSyncTriggers()
    }

    func stopDirectoryMonitoring() {
        stopSyncTriggers()
    }

    deinit {
        stopSyncTriggers()
        repository.releaseSecurityScope()
    }
}

/// 旧版同步口令的钥匙串读取器。
///
/// 已被 0600 文件存储（`SyncSecretStore`）取代，**只保留读取**用于一次性迁移：
/// 新版不再向钥匙串写入任何东西，旧条目留给回退到旧版本的用户自行清理。
enum LegacySyncKeychainReader {
    static func readPassword(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
