import SwiftUI
import Carbon.HIToolbox

@MainActor
struct MenuBarView: View {
    /// 「打开 NookClip」菜单项右侧展示当前全局快捷键；设置里改动后经通知刷新
    @State private var shortcut = HotKeyManager.shared.currentShortcut

    var body: some View {
        Group {
            Button(L10n.tr("menu.open")) {
                NotificationCenter.default.post(name: .openQuickPopover, object: nil)
            }
            .modifier(MenuShortcut(shortcut: shortcut))
            Divider()
            Button(L10n.tr("menu.settings")) {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            }
            .keyboardShortcut(",", modifiers: .command)
            Divider()
            // 顺序粘贴栈录制（US2 的全局入口）：用户按顺序复制多条，
            // 之后在目标应用里连按 ⌘V 一条条贴出；与面板内 ⌥⏎ 的多选直送互补
            Button(L10n.tr("menu.paste_stack_record")) {
                NotificationCenter.default.post(name: .startPasteStackRecording, object: nil)
            }
            // 右侧露出真实全局键位：这个入口不只在菜单里，⌃⌥V 在任何应用里都能触发
            .modifier(MenuShortcut(shortcut: HotKeyShortcut.pasteStackRecordingShortcut))
            Divider()
            pinnedNotesSection
            Button("\(L10n.tr("menu.check_updates")) (v\(AppBranding.appVersion))") {
                // Sparkle 应用内检查并安装更新（替代旧版跳转 GitHub Releases 页）
                UpdateService.shared.checkForUpdates()
            }
            Divider()
            Button(L10n.tr("menu.quit")) { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
        }
        .nookClipLocalized()
        .onReceive(NotificationCenter.default.publisher(for: .hotKeyDidChange)) { _ in
            shortcut = HotKeyManager.shared.currentShortcut
        }
    }

    /// 贴条管理：贴条一旦被压住、被穿透或落在屏幕角落，
    /// 用户手上得有一个能一次收干净的入口，不必满屏幕去找那张纸。
    /// 只在真的有贴条时才出现，菜单不会因为一个用不上的功能长期占位。
    @ViewBuilder
    private var pinnedNotesSection: some View {
        let manager = PinnedWindowManager.shared
        if manager.notes.contains(where: \.isClickThrough) {
            Button(L10n.tr("menu.pinned_unlock")) {
                manager.restoreAllClickThrough()
            }
        }
        if manager.pinnedCount > 0 {
            Button(L10n.tr("menu.pinned_close")) {
                manager.closeAll()
            }
            Divider()
        }
    }
}

/// HotKeyShortcut → SwiftUI keyboardShortcut（映射不出的键位不展示，菜单项退化为无快捷键）
struct MenuShortcut: ViewModifier {
    let shortcut: HotKeyShortcut

    func body(content: Content) -> some View {
        if let key = keyEquivalent {
            content.keyboardShortcut(key, modifiers: modifiers)
        } else {
            content
        }
    }

    var keyEquivalent: KeyEquivalent? {
        let name = HotKeyShortcut.keyName(for: UInt16(shortcut.keyCode))
        // 特殊键位先映射：↩⇥⌫⎋ 均为单字符符号，会被下方 count == 1 分支
        // 提前吞掉成为无效键位字符，后续 case 全为死代码（审计 BUG-037）
        switch name {
        case "Space": return KeyEquivalent(" ")
        case "↩": return KeyEquivalent("\r")
        case "⇥": return KeyEquivalent("\t")
        case "⌫": return KeyEquivalent("\u{8}")
        case "⎋": return KeyEquivalent("\u{1b}")
        case "←": return KeyEquivalent("\u{F702}")
        case "→": return KeyEquivalent("\u{F703}")
        case "↓": return KeyEquivalent("\u{F701}")
        case "↑": return KeyEquivalent("\u{F700}")
        case "PageUp": return KeyEquivalent("\u{F72C}")
        case "PageDown": return KeyEquivalent("\u{F72D}")
        case "Home": return KeyEquivalent("\u{F729}")
        case "End": return KeyEquivalent("\u{F72B}")
        default: break
        }
        if name.count == 1 { return KeyEquivalent(Character(name.lowercased())) }
        switch name {
        case "F1": return KeyEquivalent("\u{F704}")
        case "F2": return KeyEquivalent("\u{F705}")
        case "F3": return KeyEquivalent("\u{F706}")
        case "F4": return KeyEquivalent("\u{F707}")
        case "F5": return KeyEquivalent("\u{F708}")
        case "F6": return KeyEquivalent("\u{F709}")
        case "F7": return KeyEquivalent("\u{F70A}")
        case "F8": return KeyEquivalent("\u{F70B}")
        case "F9": return KeyEquivalent("\u{F70C}")
        case "F10": return KeyEquivalent("\u{F70D}")
        case "F11": return KeyEquivalent("\u{F70E}")
        case "F12": return KeyEquivalent("\u{F70F}")
        default: return nil
        }
    }

    var modifiers: SwiftUI.EventModifiers {
        var mods: SwiftUI.EventModifiers = []
        if shortcut.carbonModifiers & UInt32(cmdKey) != 0 { mods.insert(.command) }
        if shortcut.carbonModifiers & UInt32(shiftKey) != 0 { mods.insert(.shift) }
        if shortcut.carbonModifiers & UInt32(optionKey) != 0 { mods.insert(.option) }
        if shortcut.carbonModifiers & UInt32(controlKey) != 0 { mods.insert(.control) }
        return mods
    }
}
