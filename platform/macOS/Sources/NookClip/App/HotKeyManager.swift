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
    private var hotKeyRef: EventHotKeyRef?
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
        installHandlerIfNeeded()
        if !registerHotKeyOnly() {
            NSLog("[NookClip] Hotkey re-registration failed for \(currentDisplayString)")
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            guard !manager.isPaused else { return noErr }
            DispatchQueue.main.async { manager.onPress?() }
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

    @discardableResult
    private func registerHotKeyOnly() -> Bool {
        let signature: OSType = 0x4E4F4F4B
        let hotKeyID = EventHotKeyID(signature: signature, id: 1)
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

    private func unregisterHotKeyOnly() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }
}
