import AppKit
import Carbon.HIToolbox
import XCTest
@testable import NookClip

@MainActor
final class ShortcutRecorderModelTests: XCTestCase {

    func testStartRecordingPausesHotKeyManagerAndSetsFlag() {
        let manager = HotKeyManager.shared
        manager.resume()
        let model = ShortcutRecorderModel(hotKeyManager: manager)

        XCTAssertFalse(model.isRecording)
        XCTAssertFalse(manager.isPaused)

        model.startRecording()

        XCTAssertTrue(model.isRecording, "录制启动后 isRecording 应为 true")
        XCTAssertTrue(manager.isPaused, "录制启动后 HotKeyManager 必须暂停，以防按键被全局拦截")
        XCTAssertNil(model.errorMessage)

        model.stopRecording()
    }

    func testCancelRecordingResumesHotKeyManagerAndClearsFlag() {
        let manager = HotKeyManager.shared
        let model = ShortcutRecorderModel(hotKeyManager: manager)

        model.startRecording()
        XCTAssertTrue(model.isRecording)

        model.cancelRecording()
        XCTAssertFalse(model.isRecording, "取消后 isRecording 应为 false")
        XCTAssertFalse(manager.isPaused, "取消后 HotKeyManager 必须恢复监听")
    }

    func testHandleEscapeKeyCancelsRecording() {
        let manager = HotKeyManager.shared
        let model = ShortcutRecorderModel(hotKeyManager: manager)

        model.startRecording()
        let consumed = model.handleKeyEvent(keyCode: UInt16(kVK_Escape), modifierFlags: []) { _ in }

        XCTAssertTrue(consumed, "Esc 键应被消费")
        XCTAssertFalse(model.isRecording, "按下 Esc 键后应退出录制状态")
        XCTAssertFalse(manager.isPaused)
    }

    func testHandleRegularKeyWithoutModifiersShowsError() {
        let manager = HotKeyManager.shared
        let model = ShortcutRecorderModel(hotKeyManager: manager)

        model.startRecording()
        var appliedDisplay: String?
        let consumed = model.handleKeyEvent(keyCode: UInt16(kVK_ANSI_A), modifierFlags: []) { display in
            appliedDisplay = display
        }

        XCTAssertTrue(consumed)
        XCTAssertTrue(model.isRecording, "校验失败后仍保持录制状态供用户重按")
        XCTAssertNil(appliedDisplay, "未带修饰键的常规键不得落盘")
        XCTAssertNotNil(model.errorMessage, "应产生包含修饰键的错误提示")

        model.cancelRecording()
    }

    func testHandleFunctionKeyWithoutModifiersSucceeds() {
        let manager = HotKeyManager.shared
        let original = manager.currentShortcut
        defer { manager.update(shortcut: original) }

        let model = ShortcutRecorderModel(hotKeyManager: manager)
        model.startRecording()

        var appliedDisplay: String?
        let consumed = model.handleKeyEvent(keyCode: UInt16(kVK_F6), modifierFlags: []) { display in
            appliedDisplay = display
        }

        XCTAssertTrue(consumed)
        XCTAssertFalse(model.isRecording, "功能键 F1~F12 录入成功后应结束录制")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(appliedDisplay, "F6")
        XCTAssertEqual(manager.currentShortcut.displayString, "F6")
    }

    func testHandleValidShortcutUpdatesHotKeyAndStopsRecording() {
        let manager = HotKeyManager.shared
        let original = manager.currentShortcut
        defer { manager.update(shortcut: original) }

        let model = ShortcutRecorderModel(hotKeyManager: manager)
        model.startRecording()

        var appliedDisplay: String?
        let consumed = model.handleKeyEvent(
            keyCode: UInt16(kVK_ANSI_C),
            modifierFlags: [.command, .shift]
        ) { display in
            appliedDisplay = display
        }

        XCTAssertTrue(consumed)
        XCTAssertFalse(model.isRecording)
        XCTAssertEqual(appliedDisplay, "⌘ ⇧ C")
        XCTAssertEqual(manager.currentShortcut.displayString, "⌘ ⇧ C")
        XCTAssertFalse(manager.isPaused, "成功应用新快捷键后必须解除暂停")
    }

    func testModifierOnlyKeysAreIgnored() {
        let manager = HotKeyManager.shared
        let model = ShortcutRecorderModel(hotKeyManager: manager)
        model.startRecording()

        // 键码 55 = Command
        let consumed = model.handleKeyEvent(keyCode: 55, modifierFlags: [.command]) { _ in }

        XCTAssertTrue(consumed)
        XCTAssertTrue(model.isRecording, "纯修饰键按下应静默保持录制状态")
        XCTAssertNil(model.errorMessage)

        model.cancelRecording()
    }

    func testResetToDefaultAppliesDefaultShortcut() {
        let manager = HotKeyManager.shared
        let original = manager.currentShortcut
        defer { manager.update(shortcut: original) }

        // 先改掉
        _ = manager.update(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey), displayString: "⌥ Space")

        let model = ShortcutRecorderModel(hotKeyManager: manager)
        var appliedDisplay: String?
        model.resetToDefault { display in
            appliedDisplay = display
        }

        XCTAssertEqual(appliedDisplay, HotKeyShortcut.defaultShortcut.displayString)
        XCTAssertEqual(manager.currentShortcut, HotKeyShortcut.defaultShortcut)
        XCTAssertNil(model.errorMessage)
    }
}
