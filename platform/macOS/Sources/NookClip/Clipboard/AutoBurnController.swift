import AppKit
import Foundation
import OSLog

/// 粘完即焚（Auto-Burn Clipboard）调度器。
///
/// 要解决的问题：从别处复制验证码、密码或助记词后，明文会一直留在系统剪贴板里
/// ——任何后台应用都能随时读走，macOS 的「剪贴板历史」也会把它留下来。
///
/// 本控制器把「敏感明文在剪贴板里停留多久」从「一直留着」收敛成两条硬规则：
/// 1. **粘一次就擦**：检测到用户完成了一次粘贴，延迟 `pasteClearDelay`（0.3 秒，
///    等目标应用把内容读走）后清空系统剪贴板；
/// 2. **没粘就倒计时擦**：倒计时到期仍未粘贴，同样清空（这条由 `PasteService`
///    已有的 `scheduleSensitiveClipboardClear` 执行，本控制器只负责在到期后
///    把键盘监听收掉，避免常驻监听）。
///
/// 验证码还多一层：复制时把系统剪贴板**原地换成纯验证码**，用户直接 ⌘V 就只
/// 粘出数字，不用再手删「您的验证码是……」那串废话。
///
/// 设计约束：
/// - 只有剪贴板里真的驻留着敏感内容时才挂键盘监听，粘贴/换内容/超时后立刻卸载
///   ——绝不常驻监听键盘；
/// - 没有辅助功能权限时全局监听拿不到 ⌘V，退化为「纯倒计时擦除」，核心安全不失效；
/// - 所有判定走 Rust 核心 `detectAutoBurn`，与 Windows 端共用同一套规则。
@MainActor
final class AutoBurnController {
    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.lx3xun.nookclip",
        category: "AutoBurn"
    )

    /// 组合根访问点：与 `PasteService.shared` 同一写法——实例方法全部 @MainActor
    /// 隔离，只有非隔离静态初始化器取引用本身。
    nonisolated static let shared = AutoBurnController()

    nonisolated(unsafe) var defaults: UserDefaults
    /// 历史彻底销毁出口（AppDelegate 接到 `InMemoryHistoryStore.burnImmediately`）。
    /// 用回调而不是直接持有 store，避免剪贴板层依赖存储层。
    nonisolated(unsafe) var onHistoryBurn: ((UUID) -> Void)?

    nonisolated init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - 可调参数（测试注入，生产用默认值）

    /// 粘贴后延迟多久擦除：目标应用要把剪贴板读走，300ms 是够用的安全余量
    nonisolated(unsafe) var pasteClearDelay: TimeInterval = 0.3
    /// 粘贴后多久把历史记录彻底销毁（验证码默认 5 秒）
    nonisolated(unsafe) var historyBurnDelay: TimeInterval = 5
    /// 键盘监听最长驻留时间：倒计时为「不擦除」时也不能永远挂着监听
    nonisolated(unsafe) var maxMonitorLifetime: TimeInterval = 600

    // MARK: - 驻留态

    /// 当前驻留在系统剪贴板里的敏感内容
    struct Resident: Equatable {
        enum Kind: Equatable {
            /// 验证码（已提纯，剪贴板里是纯码）
            case otp
            /// 密码 / 密钥 / 助记词等长效敏感内容（剪贴板里是原文）
            case secret
        }

        let kind: Kind
        /// 对应的历史条目（未入库时为空，比如敏感保护关闭的场景）
        let itemID: UUID?
        /// 剪贴板里此刻应有的文本：擦除前用它校验内容没被用户换成别的
        let plainText: String
        let armedAt: Date
        /// 兜底倒计时秒数（0 = 不自动擦除）
        let countdownSeconds: Int
    }

    private(set) var resident: Resident?

    /// 最近识别到的验证码（纯码 → 识别时间）。
    ///
    /// 为什么需要这份记忆：从面板粘贴验证码时，剪贴板里只剩纯码「482910」，
    /// 单看这串数字认不出它是验证码（没有「验证码」关键词，也没有凭据特征），
    /// 而「粘完 5 秒焚毁历史」这个动作必须知道它是验证码才敢做。
    /// 捕获时记一笔，粘贴时就能把身份带过去。只存内存、不落盘、15 分钟自动过期。
    private var recentOtpCodes: [String: Date] = [:]
    private static let otpMemoryLifetime: TimeInterval = 15 * 60
    private static let otpMemoryCapacity = 32
    /// 用户已明确点过「保留此条」的条目 ID（不再自动销毁历史）
    private var keptItemIDs: Set<UUID> = []

    /// 外部粘贴检测用的键盘监听（仅在驻留期间存在）
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var pasteClearWorkItem: DispatchWorkItem?
    private var historyBurnWorkItem: DispatchWorkItem?
    private var monitorExpiryWorkItem: DispatchWorkItem?

    /// 测试钩子：拦截「挂载外部 ⌘V 监听」，让用例无需辅助功能权限也能模拟外部粘贴
    nonisolated(unsafe) static var externalPasteMonitorInstaller: ((@escaping () -> Void) -> Any?)?

    // MARK: - 设置读取

    private func boolValue(_ key: UserDefaultsKey, default fallback: Bool) -> Bool {
        defaults.object(forKey: key.rawValue) as? Bool ?? fallback
    }

    /// 复制验证码时自动提纯为纯数字（默认开启）
    private var isOtpPurifyEnabled: Bool {
        boolValue(.autoBurnOtpEnabled, default: true)
    }

    /// 敏感内容粘贴一次后立即清空剪贴板（默认开启）
    private var isClearOnPasteEnabled: Bool {
        boolValue(.autoBurnClearOnPaste, default: true)
    }

    /// 验证码粘贴后从历史彻底销毁（默认关闭：删历史属于不可逆动作，不替用户做主）
    private var isHistoryBurnEnabled: Bool {
        boolValue(.autoBurnHistoryBurnEnabled, default: false)
    }

    /// 兜底倒计时（与 `PasteService.scheduleSensitiveClipboardClear` 同一配置项，
    /// 0 = 不自动擦除）
    private var countdownSeconds: Int {
        if defaults.object(forKey: PasteService.sensitiveTimeoutKey) == nil {
            return PasteService.defaultSensitiveTimeoutSeconds
        }
        return defaults.integer(forKey: PasteService.sensitiveTimeoutKey)
    }

    // MARK: - 捕获侧入口（ClipboardMonitor 每次捕获后调用）

    /// 处理一次**外部复制**（不是从 NookClip 面板发起的粘贴）。
    ///
    /// - Parameters:
    ///   - text: 捕获到的纯文本（图片/文件没有文本，调用方不应传空串）
    ///   - itemID: 该内容入库后的条目 ID；未入库（敏感保护关闭等）时传 nil
    func handleCapturedText(_ text: String, itemID: UUID?) {
        guard !text.isEmpty else {
            cancelResident()
            return
        }

        let signal = detectAutoBurn(text: text)
        switch signal.kind {
        case .otp:
            let code = signal.extractedCode
            guard !code.isEmpty else {
                cancelResident()
                return
            }
            if isOtpPurifyEnabled {
                // 原地提纯：把系统剪贴板换成纯验证码。走 copyText 而不是直写
                // NSPasteboard，是为了复用它的内部标记（防止被自己再捕获一次）、
                // 敏感遮蔽标记与倒计时擦除调度。
                _ = PasteService.shared.copyText(code, containsSensitive: true)
                arm(kind: .otp, itemID: itemID, plainText: code)
            } else {
                arm(kind: .otp, itemID: itemID, plainText: text)
            }
        case .secret:
            arm(kind: .secret, itemID: itemID, plainText: text)
        case .none:
            // 普通内容：剪贴板里不再驻留敏感明文，收掉监听与定时器
            cancelResident()
        }
    }

    // MARK: - 粘贴侧入口（PasteService 写入剪贴板成功后调用）

    /// 写入剪贴板但没有立刻粘贴（⌘C「仅拷贝」、右键「拷贝」、批量拷贝）。
    /// 此时不能假设粘贴已经发生，只登记驻留态并挂上外部 ⌘V 监听，
    /// 等用户真正在别处粘贴时再擦除。
    func handleClipboardWrite(itemID: UUID?, plainText: String, isSensitive: Bool) {
        let kind = resolveKind(plainText)
        // 验证码即使没被凭据规则判为「敏感」（「您的验证码是 482910」里没有密码、
        // 密钥特征），也必须按敏感处理——它同样是过期即作废、不能留在历史里的东西。
        guard kind == .otp || isSensitive else {
            cancelResident()
            return
        }
        arm(kind: kind, itemID: itemID, plainText: plainText)
    }

    /// 粘贴用的提纯文本：验证码只留数字，其余原样。
    /// 验证码提纯开关关闭时一律原样返回。
    func pasteText(for text: String) -> String {
        guard isOtpPurifyEnabled else { return text }
        let signal = detectAutoBurn(text: text)
        if signal.kind == .otp, !signal.extractedCode.isEmpty {
            return signal.extractedCode
        }
        return text
    }

    /// 从 NookClip 面板发起的粘贴已经发生（`⌘V` 由我们合成，外部监听看不到）。
    /// - Parameters:
    ///   - itemID: 被粘贴的条目（批量粘贴无单一 id，传 nil）
    ///   - plainText: 真正写进剪贴板的文本（验证码条目此时已是纯码）
    ///   - isSensitive: 是否敏感条目
    func handlePanelPaste(itemID: UUID?, plainText: String, isSensitive: Bool) {
        let kind = resolveKind(plainText)
        // 同 handleClipboardWrite：验证码不依赖「凭据规则是否判敏感」
        guard kind == .otp || isSensitive else { return }
        // 面板粘贴路径下 PasteService 已经调度了倒计时擦除，这里只补「粘完即焚」
        // 与历史销毁两件事；驻留态也一并登记，方便 UI 显示倒计时。
        resident = Resident(
            kind: kind,
            itemID: itemID,
            plainText: plainText,
            armedAt: Date(),
            countdownSeconds: countdownSeconds
        )
        installPasteMonitorsIfNeeded()
        scheduleClearAfterPaste()
        if kind == .otp, isHistoryBurnEnabled, let itemID {
            scheduleHistoryBurn(itemID: itemID)
        }
    }

    // MARK: - 用户意图入口

    /// 「保留此条」：取消历史销毁，剪贴板照旧按倒计时擦除
    func keep(itemID: UUID) {
        keptItemIDs.insert(itemID)
        historyBurnWorkItem?.cancel()
        historyBurnWorkItem = nil
        Self.logger.debug("用户选择保留条目 \(itemID.uuidString)，取消历史销毁")
    }

    /// 该条目是否已被用户标记为「保留」
    func isKept(itemID: UUID) -> Bool {
        keptItemIDs.contains(itemID)
    }

    /// 「立即焚毁」：马上擦剪贴板 + 马上删历史（用户明确要求，不等延迟）
    func burnNow(itemID: UUID?) {
        clearPasteboardIfUnchanged()
        if let itemID {
            onHistoryBurn?(itemID)
        } else if let residentID = resident?.itemID {
            onHistoryBurn?(residentID)
        }
        cancelResident()
    }

    /// 当前设置下的兜底倒计时秒数（UI 文案用；0 = 不自动擦除）
    var configuredCountdownSeconds: Int { countdownSeconds }

    /// 当前驻留内容的剩余秒数（UI 倒计时用；无驻留或配置为不擦除时返回 nil）
    func remainingSeconds(now: Date = Date()) -> Int? {
        guard let resident, resident.countdownSeconds > 0 else { return nil }
        let elapsed = Int(now.timeIntervalSince(resident.armedAt))
        return max(0, resident.countdownSeconds - elapsed)
    }

    /// 收掉全部定时器与键盘监听（换内容、条目被删、应用退出时调用）
    func cancelResident() {
        pasteClearWorkItem?.cancel()
        pasteClearWorkItem = nil
        historyBurnWorkItem?.cancel()
        historyBurnWorkItem = nil
        monitorExpiryWorkItem?.cancel()
        monitorExpiryWorkItem = nil
        removePasteMonitors()
        resident = nil
    }

    /// 测试与退出清理：复位到初始态
    func resetForTests() {
        cancelResident()
        recentOtpCodes.removeAll()
        keptItemIDs.removeAll()
    }

    // MARK: - 内部：驻留与监听

    private func arm(kind: Resident.Kind, itemID: UUID?, plainText: String) {
        if kind == .otp { rememberOtp(plainText) }
        resident = Resident(
            kind: kind,
            itemID: itemID,
            plainText: plainText,
            armedAt: Date(),
            countdownSeconds: countdownSeconds
        )
        installPasteMonitorsIfNeeded()
        scheduleMonitorExpiry()
    }

    /// 判断这次要处理的文本属于哪一类敏感内容。
    /// 顺序很重要：先看当前驻留态（捕获时已确认是验证码），再看验证码记忆，
    /// 最后才重新识别——纯码「482910」只有前两步认得出来。
    private func resolveKind(_ plainText: String, now: Date = Date()) -> Resident.Kind {
        if let resident, resident.kind == .otp, resident.plainText == plainText {
            return .otp
        }
        if let seen = recentOtpCodes[plainText],
           now.timeIntervalSince(seen) < Self.otpMemoryLifetime {
            return .otp
        }
        return detectAutoBurn(text: plainText).kind == .otp ? .otp : .secret
    }

    private func rememberOtp(_ code: String) {
        guard !code.isEmpty else { return }
        let now = Date()
        recentOtpCodes = recentOtpCodes.filter { now.timeIntervalSince($0.value) < Self.otpMemoryLifetime }
        recentOtpCodes[code] = now
        if recentOtpCodes.count > Self.otpMemoryCapacity {
            // 只留最近的若干条：验证码短时有效，记太多既没用也不安全
            let trimmed = recentOtpCodes.sorted { $0.value > $1.value }.prefix(Self.otpMemoryCapacity)
            recentOtpCodes = Dictionary(uniqueKeysWithValues: trimmed.map { ($0.key, $0.value) })
        }
    }

    /// 只有驻留期间才挂键盘监听：全局通道收「别的应用里按的 ⌘V」，
    /// 本地通道收「我们窗口里按的 ⌘V」。两条都在粘贴或换内容后立刻卸载。
    private func installPasteMonitorsIfNeeded() {
        guard globalMonitor == nil, localMonitor == nil else { return }

        // 测试钩子优先：用例无需辅助功能权限即可模拟一次外部粘贴
        if let installer = Self.externalPasteMonitorInstaller {
            globalMonitor = installer { [weak self] in
                Task { @MainActor in self?.handleExternalPaste() }
            } ?? NSNull()
        } else if PasteService.isAccessibilityTrusted {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard Self.isPasteShortcut(event), !PasteService.isSyntheticPasteEvent(event) else { return }
                Task { @MainActor in self?.handleExternalPaste() }
            }
        } else {
            // 无权限：拿不到全局 ⌘V，退化为纯倒计时擦除（不提示、不打断用户）
            Self.logger.debug("未获得辅助功能权限，粘完即焚退化为倒计时擦除")
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if Self.isPasteShortcut(event), !PasteService.isSyntheticPasteEvent(event) {
                Task { @MainActor in self?.handleExternalPaste() }
            }
            // 不吞按键：⌘V 仍要落给当前输入框完成粘贴
            return event
        }
    }

    private func removePasteMonitors() {
        if let globalMonitor, !(globalMonitor is NSNull) {
            NSEvent.removeMonitor(globalMonitor)
        }
        globalMonitor = nil
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        localMonitor = nil
    }

    /// 倒计时到期后擦除剪贴板（若开启了倒计时）并收掉监听
    private func scheduleMonitorExpiry() {
        monitorExpiryWorkItem?.cancel()
        let seconds = resident?.countdownSeconds ?? 0
        let lifetime = seconds > 0 ? TimeInterval(seconds) : maxMonitorLifetime
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                if seconds > 0 {
                    self?.clearPasteboardIfUnchanged()
                } else {
                    self?.clearClipboardResidentOnly()
                }
            }
        }
        monitorExpiryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + lifetime, execute: work)
    }

    private static func isPasteShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return false }
        if flags.contains(.option) || flags.contains(.control) { return false }
        return event.keyCode == 9 // 虚拟键码 'v'
    }

    // MARK: - 内部：擦除与销毁

    private func handleExternalPaste() {
        guard resident != nil else { return }
        scheduleClearAfterPaste()
        if resident?.kind == .otp, isHistoryBurnEnabled, let itemID = resident?.itemID {
            scheduleHistoryBurn(itemID: itemID)
        }
    }

    private func scheduleClearAfterPaste() {
        guard isClearOnPasteEnabled else { return }
        pasteClearWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.clearPasteboardIfUnchanged() }
        }
        pasteClearWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + pasteClearDelay, execute: work)
    }

    /// 只清理剪贴板驻留态与键盘监听，保留排队中的历史销毁定时器（0.3s 擦剪贴板不能误杀 5s 删历史）
    private func clearClipboardResidentOnly() {
        pasteClearWorkItem?.cancel()
        pasteClearWorkItem = nil
        monitorExpiryWorkItem?.cancel()
        monitorExpiryWorkItem = nil
        removePasteMonitors()
        resident = nil
    }

    /// 只在剪贴板仍是那条敏感内容时清空：用户已经复制了别的东西就不该误擦
    private func clearPasteboardIfUnchanged() {
        guard let resident else { return }
        let pasteboard = PasteboardAccess.general
        let current = pasteboard.string(forType: .string)
        guard current == resident.plainText else {
            Self.logger.debug("剪贴板内容已被替换，跳过擦除")
            clearClipboardResidentOnly()
            return
        }
        pasteboard.clearContents()
        PasteService.markClipboardCleared()
        Self.logger.debug("敏感内容已从系统剪贴板擦除")
        clearClipboardResidentOnly()
    }

    private func scheduleHistoryBurn(itemID: UUID) {
        guard !keptItemIDs.contains(itemID) else { return }
        historyBurnWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, !self.keptItemIDs.contains(itemID) else { return }
                self.historyBurnWorkItem = nil
                self.onHistoryBurn?(itemID)
                Self.logger.debug("验证码历史记录已焚毁：\(itemID.uuidString)")
            }
        }
        historyBurnWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + historyBurnDelay, execute: work)
    }
}
