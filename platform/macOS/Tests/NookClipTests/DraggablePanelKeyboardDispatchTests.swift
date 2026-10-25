import AppKit
import Carbon.HIToolbox
import XCTest
@testable import NookClip

@MainActor
final class DraggablePanelKeyboardDispatchTests: XCTestCase {

    private func makePanel() -> DraggablePanel {
        let panel = DraggablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        return panel
    }

    private func makeKeyEvent(
        keyCode: Int,
        characters: String = "",
        modifierFlags: NSEvent.ModifierFlags = [],
        isARepeat: Bool = false
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: isARepeat,
            keyCode: UInt16(keyCode)
        )!
    }

    func testCommandFCallsFocusSearch() {
        let panel = makePanel()
        var focusSearchCalled = false
        let actions = PanelKeyActions(
            arrow: { _, _ in },
            toggleFilterPanel: {},
            confirm: { _, _ in },
            escape: {},
            cycleCategory: { _ in },
            copySelection: {},
            beginRename: {},
            beginTagEdit: {},
            toggleFavorite: {},
            cycleTimeAnchor: {},
            undoDelete: {},
            deleteSelection: {},
            focusSearch: { focusSearchCalled = true },
            typeToSearch: { _ in },
            removeLastFilterChip: { false }
        )

        let event = makeKeyEvent(keyCode: kVK_ANSI_F, characters: "f", modifierFlags: [.command])
        let handled = panel.dispatchKeyboardEvent(event, actions: actions)

        XCTAssertTrue(handled)
        XCTAssertTrue(focusSearchCalled)
    }

    func testArrowKeysDispatchStepAndExtend() {
        let panel = makePanel()
        var arrowEvents: [(step: Int, extend: Bool)] = []
        let actions = PanelKeyActions(
            arrow: { step, extend in arrowEvents.append((step, extend)) },
            toggleFilterPanel: {},
            confirm: { _, _ in },
            escape: {},
            cycleCategory: { _ in },
            copySelection: {},
            beginRename: {},
            beginTagEdit: {},
            toggleFavorite: {},
            cycleTimeAnchor: {},
            undoDelete: {},
            deleteSelection: {},
            focusSearch: {},
            typeToSearch: { _ in },
            removeLastFilterChip: { false }
        )

        // 下键
        let downEvent = makeKeyEvent(keyCode: kVK_DownArrow)
        XCTAssertTrue(panel.dispatchKeyboardEvent(downEvent, actions: actions))
        XCTAssertEqual(arrowEvents.last?.step, 1)
        XCTAssertEqual(arrowEvents.last?.extend, false)

        // 上键带 Shift 扩展选区
        let shiftUpEvent = makeKeyEvent(keyCode: kVK_UpArrow, modifierFlags: [.shift])
        XCTAssertTrue(panel.dispatchKeyboardEvent(shiftUpEvent, actions: actions))
        XCTAssertEqual(arrowEvents.last?.step, -1)
        XCTAssertEqual(arrowEvents.last?.extend, true)
    }

    func testReturnDispatchesConfirmModifiers() {
        let panel = makePanel()
        var confirmArgs: (keepOpen: Bool, plainTextOnly: Bool)?
        let actions = PanelKeyActions(
            arrow: { _, _ in },
            toggleFilterPanel: {},
            confirm: { keepOpen, plainTextOnly in confirmArgs = (keepOpen, plainTextOnly) },
            escape: {},
            cycleCategory: { _ in },
            copySelection: {},
            beginRename: {},
            beginTagEdit: {},
            toggleFavorite: {},
            cycleTimeAnchor: {},
            undoDelete: {},
            deleteSelection: {},
            focusSearch: {},
            typeToSearch: { _ in },
            removeLastFilterChip: { false }
        )

        // 普通 Return
        let returnEvent = makeKeyEvent(keyCode: kVK_Return)
        XCTAssertTrue(panel.dispatchKeyboardEvent(returnEvent, actions: actions))
        XCTAssertEqual(confirmArgs?.keepOpen, false)
        XCTAssertEqual(confirmArgs?.plainTextOnly, false)

        // ⌘⌥ Return: keepOpen + plainTextOnly
        let cmdOptReturn = makeKeyEvent(keyCode: kVK_Return, modifierFlags: [.command, .option])
        XCTAssertTrue(panel.dispatchKeyboardEvent(cmdOptReturn, actions: actions))
        XCTAssertEqual(confirmArgs?.keepOpen, true)
        XCTAssertEqual(confirmArgs?.plainTextOnly, true)

        // 重复触发按键被忽略 (isARepeat: true)
        let repeatReturn = makeKeyEvent(keyCode: kVK_Return, isARepeat: true)
        XCTAssertFalse(panel.dispatchKeyboardEvent(repeatReturn, actions: actions))
    }

    func testEscapeDispatches() {
        let panel = makePanel()
        var escapeCalled = false
        let actions = PanelKeyActions(
            arrow: { _, _ in },
            toggleFilterPanel: {},
            confirm: { _, _ in },
            escape: { escapeCalled = true },
            cycleCategory: { _ in },
            copySelection: {},
            beginRename: {},
            beginTagEdit: {},
            toggleFavorite: {},
            cycleTimeAnchor: {},
            undoDelete: {},
            deleteSelection: {},
            focusSearch: {},
            typeToSearch: { _ in },
            removeLastFilterChip: { false }
        )

        let escEvent = makeKeyEvent(keyCode: kVK_Escape)
        XCTAssertTrue(panel.dispatchKeyboardEvent(escEvent, actions: actions))
        XCTAssertTrue(escapeCalled)
    }

    func testCategoryCyclingBrackets() {
        let panel = makePanel()
        var cycleSteps: [Int] = []
        let actions = PanelKeyActions(
            arrow: { _, _ in },
            toggleFilterPanel: {},
            confirm: { _, _ in },
            escape: {},
            cycleCategory: { cycleSteps.append($0) },
            copySelection: {},
            beginRename: {},
            beginTagEdit: {},
            toggleFavorite: {},
            cycleTimeAnchor: {},
            undoDelete: {},
            deleteSelection: {},
            focusSearch: {},
            typeToSearch: { _ in },
            removeLastFilterChip: { false }
        )

        // ⌘[ -> -1
        let leftBracket = makeKeyEvent(keyCode: kVK_ANSI_LeftBracket, modifierFlags: [.command])
        XCTAssertTrue(panel.dispatchKeyboardEvent(leftBracket, actions: actions))
        XCTAssertEqual(cycleSteps.last, -1)

        // ⌘] -> 1
        let rightBracket = makeKeyEvent(keyCode: kVK_ANSI_RightBracket, modifierFlags: [.command])
        XCTAssertTrue(panel.dispatchKeyboardEvent(rightBracket, actions: actions))
        XCTAssertEqual(cycleSteps.last, 1)
    }

    func testCommandActionLetters() {
        let panel = makePanel()
        var actionsTriggered: [String] = []
        let actions = PanelKeyActions(
            arrow: { _, _ in },
            toggleFilterPanel: {},
            confirm: { _, _ in },
            escape: {},
            cycleCategory: { _ in },
            copySelection: { actionsTriggered.append("copy") },
            beginRename: { actionsTriggered.append("rename") },
            beginTagEdit: { actionsTriggered.append("tagEdit") },
            toggleFavorite: { actionsTriggered.append("favorite") },
            cycleTimeAnchor: { actionsTriggered.append("timeAnchor") },
            undoDelete: { actionsTriggered.append("undo") },
            deleteSelection: { actionsTriggered.append("delete") },
            focusSearch: {},
            typeToSearch: { _ in },
            removeLastFilterChip: { false }
        )

        // ⌘C
        XCTAssertTrue(panel.dispatchKeyboardEvent(makeKeyEvent(keyCode: kVK_ANSI_C, modifierFlags: [.command]), actions: actions))
        // ⌘R
        XCTAssertTrue(panel.dispatchKeyboardEvent(makeKeyEvent(keyCode: kVK_ANSI_R, modifierFlags: [.command]), actions: actions))
        // ⌘S
        XCTAssertTrue(panel.dispatchKeyboardEvent(makeKeyEvent(keyCode: kVK_ANSI_S, modifierFlags: [.command]), actions: actions))
        // ⌘T
        XCTAssertTrue(panel.dispatchKeyboardEvent(makeKeyEvent(keyCode: kVK_ANSI_T, modifierFlags: [.command]), actions: actions))
        // ⌘L：打开标签编辑器
        XCTAssertTrue(panel.dispatchKeyboardEvent(makeKeyEvent(keyCode: kVK_ANSI_L, modifierFlags: [.command]), actions: actions))
        // ⌘Z
        XCTAssertTrue(panel.dispatchKeyboardEvent(makeKeyEvent(keyCode: kVK_ANSI_Z, modifierFlags: [.command]), actions: actions))
        // ⌘⌫
        XCTAssertTrue(panel.dispatchKeyboardEvent(makeKeyEvent(keyCode: kVK_Delete, modifierFlags: [.command]), actions: actions))

        XCTAssertEqual(actionsTriggered, ["copy", "rename", "favorite", "timeAnchor", "tagEdit", "undo", "delete"])
    }

    func testTypeToSearchTriggeredForPrintableCharacters() {
        let panel = makePanel()
        var typeToSearchEvent: NSEvent?
        let actions = PanelKeyActions(
            arrow: { _, _ in },
            toggleFilterPanel: {},
            confirm: { _, _ in },
            escape: {},
            cycleCategory: { _ in },
            copySelection: {},
            beginRename: {},
            beginTagEdit: {},
            toggleFavorite: {},
            cycleTimeAnchor: {},
            undoDelete: {},
            deleteSelection: {},
            focusSearch: {},
            typeToSearch: { typeToSearchEvent = $0 },
            removeLastFilterChip: { false }
        )

        // 无修饰符输入字符 'a'
        let event = makeKeyEvent(keyCode: kVK_ANSI_A, characters: "a")
        XCTAssertTrue(panel.dispatchKeyboardEvent(event, actions: actions))
        XCTAssertNotNil(typeToSearchEvent)
        XCTAssertEqual(typeToSearchEvent?.characters, "a")
    }

    // MARK: - specs/012：⌃⏎ 脱敏 / ⌃⇧⏎ 还原 / ⌥⏎ 顺序粘贴 / ⌘P 钉住

    /// ⌃⏎ 走脱敏粘贴，且不能误触发普通粘贴（⌃ 与 ⏎ 的组合必须与 ⏎ 正交）
    func testControlReturnDispatchesScrubConfirm() {
        let panel = makePanel()
        var scrubCalled = false
        var confirmCalled = false
        let actions = PanelKeyActions(
            arrow: { _, _ in },
            toggleFilterPanel: {},
            confirm: { _, _ in confirmCalled = true },
            scrubConfirm: { scrubCalled = true },
            escape: {},
            cycleCategory: { _ in },
            copySelection: {},
            beginRename: {},
            beginTagEdit: {},
            toggleFavorite: {},
            cycleTimeAnchor: {},
            undoDelete: {},
            deleteSelection: {},
            focusSearch: {},
            typeToSearch: { _ in },
            removeLastFilterChip: { false }
        )

        let event = makeKeyEvent(keyCode: kVK_Return, modifierFlags: [.control])
        XCTAssertTrue(panel.dispatchKeyboardEvent(event, actions: actions))
        XCTAssertTrue(scrubCalled)
        XCTAssertFalse(confirmCalled)
    }

    /// ⌃⇧⏎ 走还原，且优先于 ⌃⏎（⇧ 是修饰里的增量维度）
    func testControlShiftReturnDispatchesRestoreScrub() {
        let panel = makePanel()
        var scrubCalled = false
        var restoreCalled = false
        let actions = PanelKeyActions(
            arrow: { _, _ in },
            toggleFilterPanel: {},
            confirm: { _, _ in },
            scrubConfirm: { scrubCalled = true },
            restoreScrubConfirm: { restoreCalled = true },
            escape: {},
            cycleCategory: { _ in },
            copySelection: {},
            beginRename: {},
            beginTagEdit: {},
            toggleFavorite: {},
            cycleTimeAnchor: {},
            undoDelete: {},
            deleteSelection: {},
            focusSearch: {},
            typeToSearch: { _ in },
            removeLastFilterChip: { false }
        )

        let event = makeKeyEvent(keyCode: kVK_Return, modifierFlags: [.control, .shift])
        XCTAssertTrue(panel.dispatchKeyboardEvent(event, actions: actions))
        XCTAssertTrue(restoreCalled)
        XCTAssertFalse(scrubCalled)
    }

    /// ⌥⏎ 在满足多选条件时启动粘贴栈并被消费
    func testOptionReturnStartsPasteStackWhenConsumed() {
        let panel = makePanel()
        var confirmCalled = false
        let actions = PanelKeyActions(
            arrow: { _, _ in },
            toggleFilterPanel: {},
            confirm: { _, _ in confirmCalled = true },
            startPasteStack: { true },
            escape: {},
            cycleCategory: { _ in },
            copySelection: {},
            beginRename: {},
            beginTagEdit: {},
            toggleFavorite: {},
            cycleTimeAnchor: {},
            undoDelete: {},
            deleteSelection: {},
            focusSearch: {},
            typeToSearch: { _ in },
            removeLastFilterChip: { false }
        )

        let event = makeKeyEvent(keyCode: kVK_Return, modifierFlags: [.option])
        XCTAssertTrue(panel.dispatchKeyboardEvent(event, actions: actions))
        XCTAssertFalse(confirmCalled)
    }

    /// 单选态 ⌥⏎ 必须原样回落到普通纯文本粘贴（契约 C1 的兼容要求）
    func testOptionReturnFallsBackToPlainTextPasteWhenNotConsumed() {
        let panel = makePanel()
        var confirmArgs: (keepOpen: Bool, plainTextOnly: Bool)?
        let actions = PanelKeyActions(
            arrow: { _, _ in },
            toggleFilterPanel: {},
            confirm: { keepOpen, plainTextOnly in
                confirmArgs = (keepOpen: keepOpen, plainTextOnly: plainTextOnly)
            },
            startPasteStack: { false },
            escape: {},
            cycleCategory: { _ in },
            copySelection: {},
            beginRename: {},
            beginTagEdit: {},
            toggleFavorite: {},
            cycleTimeAnchor: {},
            undoDelete: {},
            deleteSelection: {},
            focusSearch: {},
            typeToSearch: { _ in },
            removeLastFilterChip: { false }
        )

        let event = makeKeyEvent(keyCode: kVK_Return, modifierFlags: [.option])
        XCTAssertTrue(panel.dispatchKeyboardEvent(event, actions: actions))
        XCTAssertEqual(confirmArgs?.plainTextOnly, true)
        XCTAssertEqual(confirmArgs?.keepOpen, false)
    }

    /// ⌘P 钉在屏幕；且不能被 ⌘ 字母动作或打字即搜索抢走
    func testCommandPDispatchesPinToScreen() {
        let panel = makePanel()
        var pinCalled = false
        var typeToSearchCalled = false
        let actions = PanelKeyActions(
            arrow: { _, _ in },
            toggleFilterPanel: {},
            confirm: { _, _ in },
            pinToScreen: { pinCalled = true },
            escape: {},
            cycleCategory: { _ in },
            copySelection: {},
            beginRename: {},
            beginTagEdit: {},
            toggleFavorite: {},
            cycleTimeAnchor: {},
            undoDelete: {},
            deleteSelection: {},
            focusSearch: {},
            typeToSearch: { _ in typeToSearchCalled = true },
            removeLastFilterChip: { false }
        )

        let event = makeKeyEvent(keyCode: kVK_ANSI_P, characters: "p", modifierFlags: [.command])
        XCTAssertTrue(panel.dispatchKeyboardEvent(event, actions: actions))
        XCTAssertTrue(pinCalled)
        XCTAssertFalse(typeToSearchCalled)
    }
}
