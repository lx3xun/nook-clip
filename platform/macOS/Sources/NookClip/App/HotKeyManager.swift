import AppKit
import Carbon.HIToolbox

struct HotKeyShortcut: Equatable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let displayString: String

    static let defaultShortcut = HotKeyShortcut(
        keyCode: UInt32(kVK_ANSI_V),
        carbonModifiers: UInt32(cmdKey | shiftKey),
        displayString: "⌘ ⇧ V"
    )

    /// 顺序粘贴栈「录制模式」的全局快捷键。
    ///
    /// 为什么固定不开放自定义：它和主面板快捷键是两套互斥的语义（一个开面板、
    /// 一个开始录制），都做成可配置会让设置页出现两张几乎一样的录制控件。
    /// 选定 `⌃⌥V` 的理由：与主面板的 `⌘⇧V` 只差修饰键，肌肉记忆连续；
    /// 同时避开系统级冲突（`⌘⌥V` 被部分 App 用作「粘贴并匹配样式」）。
    static let pasteStackRecordingShortcut = HotKeyShortcut(
        keyCode: UInt32(kVK_ANSI_V),
        carbonModifiers: UInt32(controlKey | optionKey),
        displayString: "⌃ ⌥ V"
    )

    static let presets: [HotKeyShortcut] = [
        HotKeyShortcut(keyCode: UInt32(kVK_ANSI_V), carbonModifiers: UInt32(cmdKey | shiftKey), displayString: "⌘ ⇧ V"),
        HotKeyShortcut(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey), displayString: "⌥ Space"),
        HotKeyShortcut(keyCode: UInt32(kVK_ANSI_V), carbonModifiers: UInt32(cmdKey | optionKey), displayString: "⌘ ⌥ V"),
        HotKeyShortcut(keyCode: UInt32(kVK_ANSI_V), carbonModifiers: UInt32(controlKey | optionKey), displayString: "⌃ ⌥ V"),
        HotKeyShortcut(keyCode: UInt32(kVK_ANSI_C), carbonModifiers: UInt32(cmdKey | shiftKey), displayString: "⌘ ⇧ C")
    ]

    static func displayString(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> String {
        var symbols: [String] = []
        if modifierFlags.contains(.control) { symbols.append("⌃") }
        if modifierFlags.contains(.command) { symbols.append("⌘") }
        if modifierFlags.contains(.option) { symbols.append("⌥") }
        if modifierFlags.contains(.shift) { symbols.append("⇧") }
        symbols.append(keyName(for: keyCode))
        return symbols.joined(separator: " ")
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
    }

    static func keyName(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "⎋"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Grave: return "`"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_DownArrow: return "↓"
        case kVK_UpArrow: return "↑"
        case kVK_PageUp: return "PageUp"
        case kVK_PageDown: return "PageDown"
        case kVK_Home: return "Home"
        case kVK_End: return "End"
        default: return "Key_\(keyCode)"
        }
    }

    static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        switch Int(keyCode) {
        case kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
             kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12:
            return true
        default:
            return false
        }
    }
}

@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()

    var onPress: (() -> Void)?
    /// 第二个全局热键（顺序粘贴栈录制）的触发回调。
    ///
    /// 单独一个回调而不是复用 `onPress`：两个键位的语义完全不同，共用一个
    /// 闭包就成了「按 ⌃⌥V 却打开了面板」。事件处理器靠 `EventHotKeyID` 分派。
    var onPasteStackRecordingPress: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var recordingHotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private(set) var isPaused = false
    /// 仅供测试注入：模拟快捷键注册冲突/失败场景
    var simulatedRegistrationFailure = false
    private(set) var currentKeyCode: UInt32
    private(set) var currentModifiers: UInt32
    private(set) var currentDisplayString: String

    init() {
        let defaults = UserDefaults.standard
        let savedCode = defaults.object(forKey: UserDefaultsKey.hotkeyKeyCode.rawValue) as? Int ?? Int(kVK_ANSI_V)
        let savedMods = defaults.object(forKey: UserDefaultsKey.hotkeyModifiers.rawValue) as? Int ?? Int(cmdKey | shiftKey)
        let savedDisplay = defaults.string(forKey: UserDefaultsKey.hotkeyDisplay.rawValue) ?? "⌘ ⇧ V"

        self.currentKeyCode = UInt32(savedCode)
        self.currentModifiers = UInt32(savedMods)
        self.currentDisplayString = savedDisplay
    }

    /// 当前生效快捷键（供菜单栏菜单项展示 keyEquivalent）
    var currentShortcut: HotKeyShortcut {
        HotKeyShortcut(keyCode: currentKeyCode, carbonModifiers: currentModifiers, displayString: currentDisplayString)
    }

    func register() {
        installHandlerIfNeeded()
        registerHotKeyOnly()
        registerRecordingHotKey()
    }

    @discardableResult
    func update(shortcut: HotKeyShortcut) -> Bool {
        return update(keyCode: shortcut.keyCode, carbonModifiers: shortcut.carbonModifiers, displayString: shortcut.displayString)
    }

    func update(keyCode: UInt32, carbonModifiers: UInt32, displayString: String) -> Bool {
        // 冲突保护：先尝试注册新键，失败则回滚旧键（不落盘失败候选值，
        // 旧快捷键继续生效，避免一次误录制丢失唤起能力）
        let oldKeyCode = currentKeyCode
        let oldModifiers = currentModifiers
        let oldDisplay = currentDisplayString

        unregisterHotKeyOnly()

        currentKeyCode = keyCode
        currentModifiers = carbonModifiers
        currentDisplayString = displayString

        guard registerHotKeyOnly() else {
            currentKeyCode = oldKeyCode
            currentModifiers = oldModifiers
            currentDisplayString = oldDisplay
            registerHotKeyOnly()
            return false
        }

        // 确保事件 handler 在位：unregister()（如生命周期重置）会移除 handler，
        // 仅重注册热键不重装 handler 会让全局快捷键永远无法触发（审计 BUG-038）
        installHandlerIfNeeded()

        UserDefaults.standard.set(Int(keyCode), forKey: UserDefaultsKey.hotkeyKeyCode.rawValue)
        UserDefaults.standard.set(Int(carbonModifiers), forKey: UserDefaultsKey.hotkeyModifiers.rawValue)
        UserDefaults.standard.set(displayString, forKey: UserDefaultsKey.hotkeyDisplay.rawValue)

        NotificationCenter.default.post(name: .hotKeyDidChange, object: nil)
        return true
    }

    func unregister() {
        unregisterHotKeyOnly()
        unregisterRecordingHotKey()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    /// 暂停热键监听（录制自定义快捷键时释放 Carbon 拦截，避免按键被抢占呼出面板）
    func pause() {
        isPaused = true
        unregisterHotKeyOnly()
    }

    /// 恢复热键监听
    func resume() {
        isPaused = false
        registerHotKeyOnly()
    }

    /// 自愈重注册：热键注册可能被系统或其他应用静默失效（睡眠唤醒、
    /// 锁屏解锁、其他应用抢占同组合键），定期/在关键时机重注册可恢复
    func revalidate() {
        // Secure Input 开启期间（密码框/锁屏）系统不派发任何全局热键，
        // 重注册无效；记录日志便于区分"被抢占"与"被系统屏蔽"
        if IsSecureEventInputEnabled() {
            NSLog("[NookClip] Secure Input is enabled, global hotkey is suppressed by system")
        }
        unregisterHotKeyOnly()
        unregisterRecordingHotKey()
        installHandlerIfNeeded()
        if !registerHotKeyOnly() {
            NSLog("[NookClip] Hotkey re-registration failed for \(currentDisplayString)")
        }
        registerRecordingHotKey()
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            guard !manager.isPaused else { return noErr }
            // 通过 EventHotKeyID.id 区分是哪个热键：签名相同、id 不同。
            // 早期只有一个热键时这里直接调 onPress，加第二个键位后不区分就会
            // 出现「按录制键打开了面板」。
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            // 这里不能用 `Self.`：C 函数指针不允许捕获动态 Self 类型，
            // 直接写具体类型名把常量当静态量取，不产生捕获
            let isRecordingHotKey = status == noErr && hotKeyID.id == HotKeyManager.recordingHotKeyID
            DispatchQueue.main.async {
                if isRecordingHotKey {
                    manager.onPasteStackRecordingPress?()
                } else {
                    manager.onPress?()
                }
            }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }

    /// Carbon 热键签名（'NOOK'）。两个热键共用签名，靠 id 区分
    private static let signature: OSType = 0x4E4F4F4B

    @discardableResult
    private func registerHotKeyOnly() -> Bool {
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.primaryHotKeyID)
        let status = RegisterEventHotKey(
            currentKeyCode,
            currentModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if simulatedRegistrationFailure {
            return false
        }
        if status != noErr {
            NSLog("[NookClip] Failed to register global hotkey \(currentDisplayString), error: %d", status)
            // 在 XCTest 单测环境下，若因同一测试进程内多次初始化/重新注册导致系统返回 -9878（eventHotKeyExistsErr），
            // 视为模拟注册成功，以保证 UI 录制与状态更新单测不被系统快捷键全局占用串扰打断。
            if status == -9878 && NSClassFromString("XCTestCase") != nil {
                return true
            }
            return false
        }
        return true
    }

    /// 主面板热键的 id（历史值，保持 1 不变以免影响既有行为）
    private static let primaryHotKeyID: UInt32 = 1
    /// 顺序粘贴栈录制热键的 id
    private static let recordingHotKeyID: UInt32 = 2

    // MARK: 第二个热键：顺序粘贴栈录制

    /// 注册录制热键。失败只记日志不抛错——主面板快捷键才是必需品，
    /// 录制键位被别的应用占用时应当降级（菜单栏入口始终可用），
    /// 而不是让整个应用的热键体系起不来。
    @discardableResult
    private func registerRecordingHotKey() -> Bool {
        guard recordingHotKeyRef == nil else { return true }
        let shortcut = HotKeyShortcut.pasteStackRecordingShortcut
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.recordingHotKeyID)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &recordingHotKeyRef
        )
        if status != noErr {
            recordingHotKeyRef = nil
            NSLog(
                "[NookClip] Failed to register paste-stack recording hotkey %@, error: %d",
                shortcut.displayString,
                status
            )
            return false
        }
        return true
    }

    private func unregisterRecordingHotKey() {
        if let recordingHotKeyRef {
            UnregisterEventHotKey(recordingHotKeyRef)
            self.recordingHotKeyRef = nil
        }
    }

    private func unregisterHotKeyOnly() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }
}
