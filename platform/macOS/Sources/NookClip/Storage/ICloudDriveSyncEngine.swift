import Foundation
import Observation
import os

public enum CloudSyncMode: String, CaseIterable, Identifiable {
    case iCloudDrive = "icloud"
    case localDirectory = "local_dir"
    case webdav = "webdav"

    public var id: String { rawValue }
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

    private let isSyncEnabledKey = "enableICloudSync"
    private let syncModeKey = "nook.sync.mode"
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
    private let keychainServicePrefix: String?

    init(customBaseURL: URL? = nil, defaults: UserDefaults = .standard, keychainServicePrefix: String? = nil) {
        self.defaults = defaults
        self.repository = CloudFileRepository(defaults: defaults, customBaseURL: customBaseURL)
        self.monitor = CloudDirectoryMonitor()
        self.keychainServicePrefix = keychainServicePrefix
        monitor.onDirectoryChange = { [weak self] in
            self?.onRemoteChange?()
        }
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

    private var webDavKeychainService: String {
        if let prefix = keychainServicePrefix {
            return "\(prefix).webdav"
        }
        return isTestingEnvironment ? "test.nook.webdav.\(ProcessInfo.processInfo.processIdentifier)" : "com.lx3xun.nookclip.webdav"
    }

    private var e2eeKeychainService: String {
        if let prefix = keychainServicePrefix {
            return "\(prefix).e2ee"
        }
        return isTestingEnvironment ? "test.nook.e2ee.\(ProcessInfo.processInfo.processIdentifier)" : "com.lx3xun.nookclip.e2ee"
    }

    var webDavPassword: String {
        get {
            if let cached = keychainCacheLock.withLock({ cachedWebDavPassword }) {
                return cached
            }
            let value = SyncKeychainHelper.readPassword(service: webDavKeychainService, account: "webdav_account") ?? ""
            keychainCacheLock.withLock { cachedWebDavPassword = value }
            return value
        }
        set {
            keychainCacheLock.withLock { cachedWebDavPassword = newValue }
            SyncKeychainHelper.savePassword(newValue, service: webDavKeychainService, account: "webdav_account")
        }
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
    }

    func e2eePassphrase(for mode: CloudSyncMode) -> String {
        if let cached = keychainCacheLock.withLock({ cachedE2EEPassphrases[mode] }) {
            return cached
        }

        let account = e2eeKeychainAccount(for: mode)
        let resolved: String
        if let pass = SyncKeychainHelper.readPassword(service: e2eeKeychainService, account: account) {
            resolved = pass
        } else if let legacyPass = SyncKeychainHelper.readPassword(service: e2eeKeychainService, account: "sync_passphrase") {
            // 兼容单通道升级前的旧口令：首次读取时迁移到当前通道并移除旧键，避免清空后再次回退
            SyncKeychainHelper.savePassword(legacyPass, service: e2eeKeychainService, account: account)
            SyncKeychainHelper.savePassword("", service: e2eeKeychainService, account: "sync_passphrase")
            resolved = legacyPass
        } else {
            resolved = ""
        }
        keychainCacheLock.withLock { cachedE2EEPassphrases[mode] = resolved }
        return resolved
    }

    func setE2EEPassphrase(_ pass: String, for mode: CloudSyncMode) {
        keychainCacheLock.withLock { cachedE2EEPassphrases[mode] = pass }
        let account = e2eeKeychainAccount(for: mode)
        SyncKeychainHelper.savePassword(pass, service: e2eeKeychainService, account: account)
        if pass.isEmpty {
            SyncKeychainHelper.savePassword("", service: e2eeKeychainService, account: "sync_passphrase")
        }
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

    /// 异步构造同步选项：Keychain 读取是跨进程 XPC，放在后台执行，
    /// 避免 MainActor 上同步等系统服务导致面板/同步入口卡顿。
    /// 所有实例属性先在当前（主）线程取快照，后台任务只接收不可变值，
    /// 不跨并发域引用 self（引擎非 Sendable，避免数据竞争）。
    func makeSyncOptionsAsync(deviceId: String, localAssetsDir: String) async -> SyncOptions {
        let mode = syncMode
        let syncDir = baseDirectoryURL.path
        let webdavURL = webDavURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let webdavUser = webDavUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let e2eeEnabled = isE2EEEnabled
        let sensitiveAllowed = syncSensitiveItems
        let keychainService = e2eeKeychainService
        let account = e2eeKeychainAccount(for: mode)
        let webdavKeychainService = webDavKeychainService
        let (cachedPass, cachedWebPass) = keychainCacheLock.withLock {
            (
                e2eeEnabled ? cachedE2EEPassphrases[mode] : "",
                (mode == .webdav) ? cachedWebDavPassword : ""
            )
        }
        let passphrase: String
        let webdavPass: String
        if let cachedPass, let cachedWebPass {
            passphrase = cachedPass
            webdavPass = cachedWebPass
        } else {
            // 仅在真正启用对应功能且内存尚未缓存时访问一次 Keychain，
            // 避免每次启动或打开面板同步都反复触发 macOS 钥匙串授权弹窗。
            let loaded = await Task.detached(priority: .utility) {
                let webPass: String = {
                    if let cachedWebPass { return cachedWebPass }
                    guard mode == .webdav else { return "" }
                    return SyncKeychainHelper.readPassword(service: webdavKeychainService, account: "webdav_account") ?? ""
                }()
                let e2eePass: String = {
                    if let cachedPass { return cachedPass }
                    guard e2eeEnabled else { return "" }
                    if let pass = SyncKeychainHelper.readPassword(service: keychainService, account: account) {
                        return pass
                    }
                    // 兼容单通道升级前的旧口令
                    if let legacy = SyncKeychainHelper.readPassword(service: keychainService, account: "sync_passphrase") {
                        SyncKeychainHelper.savePassword(legacy, service: keychainService, account: account)
                        SyncKeychainHelper.savePassword("", service: keychainService, account: "sync_passphrase")
                        return legacy
                    }
                    return ""
                }()
                return (e2eePass, webPass)
            }.value
            passphrase = loaded.0
            webdavPass = loaded.1
            keychainCacheLock.withLock {
                if e2eeEnabled && cachedE2EEPassphrases[mode] == nil {
                    cachedE2EEPassphrases[mode] = passphrase
                }
                if mode == .webdav && cachedWebDavPassword == nil {
                    cachedWebDavPassword = webdavPass
                }
            }
        }
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

enum SyncKeychainHelper {
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

    static func savePassword(_ password: String, service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard let data = password.data(using: .utf8), !password.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
