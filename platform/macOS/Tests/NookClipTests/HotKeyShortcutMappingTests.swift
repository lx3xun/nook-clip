import AppKit
import Carbon.HIToolbox
import SwiftUI
import XCTest
@testable import NookClip

/// 全局热键纯映射测试（Seam：HotKeyShortcut / MenuShortcut 的公开纯函数）。
/// Carbon 真实注册不测（全局热键与他应用冲突，环境不稳定）；
/// 声明式菜单快捷键（⌘,/⌘Q/⌘1..N）由 SwiftUI 内部分发，不在可测边界内。
final class HotKeyShortcutMappingTests: XCTestCase {

    // MARK: - keyName 键位命名

    func testKeyNameMapsLettersDigitsAndSpecialKeys() {
        XCTAssertEqual(HotKeyShortcut.keyName(for: UInt16(kVK_ANSI_V)), "V")
        XCTAssertEqual(HotKeyShortcut.keyName(for: UInt16(kVK_ANSI_C)), "C")
        XCTAssertEqual(HotKeyShortcut.keyName(for: UInt16(kVK_ANSI_9)), "9")
        XCTAssertEqual(HotKeyShortcut.keyName(for: UInt16(kVK_Space)), "Space")
        XCTAssertEqual(HotKeyShortcut.keyName(for: UInt16(kVK_Return)), "↩")
        XCTAssertEqual(HotKeyShortcut.keyName(for: UInt16(kVK_Tab)), "⇥")
        XCTAssertEqual(HotKeyShortcut.keyName(for: UInt16(kVK_Delete)), "⌫")
        XCTAssertEqual(HotKeyShortcut.keyName(for: UInt16(kVK_Escape)), "⎋")
        XCTAssertEqual(HotKeyShortcut.keyName(for: UInt16(kVK_F5)), "F5")
        XCTAssertEqual(HotKeyShortcut.keyName(for: UInt16(kVK_Help)), "Key_\(UInt16(kVK_Help))",
                       "未收录键位应回退 Key_码位")
    }

    func testKeyNameMapsArrowKeysAndFunctionHelper() {
        XCTAssertEqual(HotKeyShortcut.keyName(for: UInt16(kVK_UpArrow)), "↑")
        XCTAssertEqual(HotKeyShortcut.keyName(for: UInt16(kVK_DownArrow)), "↓")
        XCTAssertEqual(HotKeyShortcut.keyName(for: UInt16(kVK_LeftArrow)), "←")
        XCTAssertEqual(HotKeyShortcut.keyName(for: UInt16(kVK_RightArrow)), "→")
        XCTAssertTrue(HotKeyShortcut.isFunctionKey(UInt16(kVK_F1)))
        XCTAssertTrue(HotKeyShortcut.isFunctionKey(UInt16(kVK_F6)))
        XCTAssertFalse(HotKeyShortcut.isFunctionKey(UInt16(kVK_ANSI_A)))
    }

    // MARK: - displayString 展示串

    func testDisplayStringOrdersModifiersControlCommandOptionShift() {
        XCTAssertEqual(
            HotKeyShortcut.displayString(keyCode: UInt16(kVK_ANSI_V), modifierFlags: [.command, .shift]),
            "⌘ ⇧ V",
            "默认快捷键的展示串"
        )
        XCTAssertEqual(
            HotKeyShortcut.displayString(keyCode: UInt16(kVK_ANSI_V), modifierFlags: [.control, .command, .option, .shift]),
            "⌃ ⌘ ⌥ ⇧ V",
            "修饰符固定按 ⌃⌘⌥⇧ 排序"
        )
        XCTAssertEqual(
            HotKeyShortcut.displayString(keyCode: UInt16(kVK_Space), modifierFlags: [.option]),
            "⌥ Space",
            "预设 ⌥Space 的展示串"
        )
    }

    // MARK: - carbonModifiers 修饰符换算

    func testCarbonModifiersConvertsEachNSEventFlag() {
        XCTAssertEqual(HotKeyShortcut.carbonModifiers(from: []), 0)
        XCTAssertEqual(HotKeyShortcut.carbonModifiers(from: [.command]), UInt32(cmdKey))
        XCTAssertEqual(HotKeyShortcut.carbonModifiers(from: [.shift]), UInt32(shiftKey))
        XCTAssertEqual(HotKeyShortcut.carbonModifiers(from: [.option]), UInt32(optionKey))
        XCTAssertEqual(HotKeyShortcut.carbonModifiers(from: [.control]), UInt32(controlKey))
        XCTAssertEqual(
            HotKeyShortcut.carbonModifiers(from: [.command, .shift]),
            UInt32(cmdKey | shiftKey)
        )
    }

    // MARK: - MenuShortcut 键位等效映射（HotKeyShortcut → SwiftUI KeyEquivalent）

    /// 字母/数字键映射为小写单字符；修饰符完整换算
    func testMenuShortcutMapsSimpleKeysAndModifiers() {
        let shortcut = HotKeyShortcut(
            keyCode: UInt32(kVK_ANSI_V),
            carbonModifiers: UInt32(cmdKey | shiftKey),
            displayString: "⌘ ⇧ V"
        )
        let menu = MenuShortcut(shortcut: shortcut)
        XCTAssertEqual(menu.keyEquivalent, KeyEquivalent("v"), "字母键映射为小写字符")
        XCTAssertEqual(menu.modifiers, [.command, .shift], "Carbon 修饰符换算为 SwiftUI 修饰符")
    }

    /// 特殊键位映射为控制字符：Space/↩/⇥/⌫/⎋（审计 BUG-037：不得被单字符分支吞掉）
    func testMenuShortcutMapsSpecialKeysToControlCharacters() {
        func keyEquivalent(keyCode: Int) -> KeyEquivalent? {
            MenuShortcut(shortcut: HotKeyShortcut(
                keyCode: UInt32(keyCode),
                carbonModifiers: UInt32(cmdKey),
                displayString: ""
            )).keyEquivalent
        }
        XCTAssertEqual(keyEquivalent(keyCode: kVK_Space), KeyEquivalent(" "))
        XCTAssertEqual(keyEquivalent(keyCode: kVK_Return), KeyEquivalent("\r"))
        XCTAssertEqual(keyEquivalent(keyCode: kVK_Tab), KeyEquivalent("\t"))
        XCTAssertEqual(keyEquivalent(keyCode: kVK_Delete), KeyEquivalent("\u{8}"))
        XCTAssertEqual(keyEquivalent(keyCode: kVK_Escape), KeyEquivalent("\u{1b}"))
    }

    /// F1–F12 映射为功能键 Unicode；映射不出的键位返回 nil（菜单项退化为无快捷键）
    func testMenuShortcutMapsFunctionKeysAndReturnsNilForUnknown() {
        func keyEquivalent(keyCode: UInt16) -> KeyEquivalent? {
            MenuShortcut(shortcut: HotKeyShortcut(
                keyCode: UInt32(keyCode),
                carbonModifiers: UInt32(cmdKey),
                displayString: ""
            )).keyEquivalent
        }
        XCTAssertEqual(keyEquivalent(keyCode: UInt16(kVK_F1)), KeyEquivalent("\u{F704}"))
        XCTAssertEqual(keyEquivalent(keyCode: UInt16(kVK_F12)), KeyEquivalent("\u{F70F}"))
        XCTAssertNil(keyEquivalent(keyCode: UInt16(kVK_Help)), "未收录键位应返回 nil")
    }

    // MARK: - HotKeyManager 暂停与恢复能力

    @MainActor
    func testHotKeyManagerPauseAndResumeTogglesState() {
        let manager = HotKeyManager.shared
        XCTAssertFalse(manager.isPaused, "初始状态下全局热键不应处于暂停状态")

        manager.pause()
        XCTAssertTrue(manager.isPaused, "调用 pause 后 isPaused 必须置为 true")

        manager.resume()
        XCTAssertFalse(manager.isPaused, "调用 resume 后 isPaused 必须恢复为 false")
    }

    // MARK: - 贴条救回键

    func testPinnedRestoreShortcutIsCommandOptionP() {
        let shortcut = HotKeyShortcut.pinnedRestoreShortcut
        XCTAssertEqual(shortcut.keyCode, UInt32(kVK_ANSI_P), "救回键必须是 P，和界面提示文案一致")
        XCTAssertEqual(
            shortcut.carbonModifiers,
            UInt32(cmdKey | optionKey),
            "只按 P 会误触；加 ⌘⌥ 才不会和普通输入冲突"
        )
        XCTAssertEqual(shortcut.displayString, "⌘ ⌥ P")
    }

    func testPinnedRestoreShortcutDoesNotCollideWithOtherHotKeys() {
        let restore = HotKeyShortcut.pinnedRestoreShortcut
        XCTAssertNotEqual(restore.keyCode, HotKeyShortcut.pasteStackRecordingShortcut.keyCode)
        for preset in HotKeyShortcut.presets {
            XCTAssertFalse(
                preset.keyCode == restore.keyCode && preset.carbonModifiers == restore.carbonModifiers,
                "救回键不能和应用里任何可自定义快捷键撞车，否则用户改完就再也解不开贴条"
            )
        }
        let recording = HotKeyShortcut.pasteStackRecordingShortcut
        for preset in HotKeyShortcut.presets {
            XCTAssertFalse(
                preset.keyCode == recording.keyCode && preset.carbonModifiers == recording.carbonModifiers,
                "顺序粘贴录制热键不能和推荐预设冲突"
            )
        }
    }
}
