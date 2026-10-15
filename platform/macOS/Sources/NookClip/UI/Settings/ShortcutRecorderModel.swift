import AppKit
import Carbon.HIToolbox

/// 快捷键录制状态控制器（Seam：处理按键录制、校验、热键暂停及冲突回滚的纯逻辑）
@MainActor
final class ShortcutRecorderModel: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var errorMessage: String?

    private let hotKeyManager: HotKeyManager

    enum KeyCode {
        static let escape: UInt16 = 53
        /// 纯修饰键按键码（左右 ⌘/⌥/Ctrl/⇧/Fn 等）
        static let modifierOnlyKeys: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
    }

    init(hotKeyManager: HotKeyManager) {
        self.hotKeyManager = hotKeyManager
    }

    convenience init() {
        self.init(hotKeyManager: .shared)
    }

    func startRecording() {
        errorMessage = nil
        isRecording = true
        // 关键自愈：进入录制状态时暂停全局热键，避免按下与当前热键冲突的键位时被系统直接拦截呼出面板
        hotKeyManager.pause()
    }

    func cancelRecording() {
        stopRecording()
    }

    func stopRecording() {
        isRecording = false
        hotKeyManager.resume()
    }

    /// 处理键盘按键事件
    /// - Parameters:
    ///   - keyCode: 虚拟键码
    ///   - modifierFlags: NSEvent 修饰键集合
    ///   - onApplied: 成功更新快捷键后的回调（透传 displayString，供外部同步绑定更新）
    /// - Returns: true 表示事件被消费
    @discardableResult
    func handleKeyEvent(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        onApplied: (String) -> Void
    ) -> Bool {
        guard isRecording else { return false }

        if keyCode == KeyCode.escape {
            cancelRecording()
            return true
        }

        // 纯修饰键按下（尚未按主键）：静默等待，不报错不结束
        if KeyCode.modifierOnlyKeys.contains(keyCode) {
            return true
        }

        let flags = modifierFlags.intersection([.command, .shift, .option, .control])
        let isFunction = HotKeyShortcut.isFunctionKey(keyCode)

        // 既不是功能键（F1~F12），又未按修饰键：拒绝并提示
        guard isFunction || !flags.isEmpty else {
            rejectRecording(L10n.tr("settings.hotkey.err_modifiers"))
            return true
        }

        let carbonMods = HotKeyShortcut.carbonModifiers(from: flags)
        let display = HotKeyShortcut.displayString(keyCode: keyCode, modifierFlags: flags)

        // 先恢复监听以支持 update 内部的 registerHotKeyOnly
        hotKeyManager.resume()
        let success = hotKeyManager.update(
            keyCode: UInt32(keyCode),
            carbonModifiers: carbonMods,
            displayString: display
        )

        if success {
            errorMessage = nil
            isRecording = false
            onApplied(display)
        } else {
            // 注册冲突，重新暂停并保持录制态
            hotKeyManager.pause()
            rejectRecording(L10n.tr("settings.hotkey.err_conflict"))
        }

        return true
    }

    func resetToDefault(onApplied: (String) -> Void) {
        let def = HotKeyShortcut.defaultShortcut
        hotKeyManager.update(shortcut: def)
        errorMessage = nil
        onApplied(def.displayString)
    }

    private func rejectRecording(_ message: String) {
        NSSound.beep()
        errorMessage = message
    }
}
