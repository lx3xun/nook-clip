import AppKit
import Carbon.HIToolbox
import XCTest
@testable import NookClip

/// ⌘D 行内对比的键位分发测试（feature #5）。
///
/// 键位归 `DraggablePanel.dispatchKeyboardEvent` 一处判定，这里逐个钉住：
/// 对比态要能接管 ⌘D / ⌥↑⌥↓ / ⌘C / ⏎，未接管时必须回落常规语义，
/// 否则列表态会丢键、或者对比态按 ⏎ 反而触发批量合并粘贴。
@MainActor
final class DiffKeyboardDispatchTests: XCTestCase {

    private func makePanel() -> DraggablePanel {
        DraggablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
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

    /// 只关心 diff 动作的基线动作表；其余动作填空实现（都能靠默认值省略）
    private func makeActions(
        toggleDiff: @escaping () -> Void = {},
        moveDiffHunk: @escaping (Bool) -> Bool = { _ in false },
        copyMergedDiff: @escaping () -> Bool = { false },
        pasteMergedDiff: @escaping () -> Bool = { false },
        confirm: @escaping (Bool, Bool) -> Void = { _, _ in },
        copySelection: @escaping () -> Void = {},
        arrow: @escaping (Int, Bool) -> Void = { _, _ in }
    ) -> PanelKeyActions {
        PanelKeyActions(
            arrow: arrow,
            toggleFilterPanel: {},
            confirm: confirm,
            escape: {},
            cycleCategory: { _ in },
            copySelection: copySelection,
            beginRename: {},
            beginTagEdit: {},
            toggleFavorite: {},
            cycleTimeAnchor: {},
            undoDelete: {},
            deleteSelection: {},
            focusSearch: {},
            toggleDiff: toggleDiff,
            moveDiffHunk: moveDiffHunk,
            copyMergedDiff: copyMergedDiff,
            pasteMergedDiff: pasteMergedDiff,
            typeToSearch: { _ in },
            removeLastFilterChip: { false }
        )
    }

    // MARK: - ⌘D

    func testCommandDDispatchesToggleDiff() {
        let panel = makePanel()
        var called = false
        let actions = makeActions(toggleDiff: { called = true })
        let event = makeKeyEvent(keyCode: kVK_ANSI_D, characters: "d", modifierFlags: [.command])
        XCTAssertTrue(panel.dispatchKeyboardEvent(event, actions: actions))
        XCTAssertTrue(called)
    }

    /// ⇧⌘D / ⌥⌘D 不该被当成对比快捷键
    func testCommandDWithExtraModifiersDoesNotToggleDiff() {
        let panel = makePanel()
        var called = false
        let actions = makeActions(toggleDiff: { called = true })
        let event = makeKeyEvent(
            keyCode: kVK_ANSI_D,
            characters: "D",
            modifierFlags: [.command, .shift]
        )
        _ = panel.dispatchKeyboardEvent(event, actions: actions)
        XCTAssertFalse(called)
    }

    // MARK: - ⌥↑ / ⌥↓

    func testOptionUpDispatchesMoveDiffHunkBackward() {
        let panel = makePanel()
        var forwards: [Bool] = []
        let actions = makeActions(moveDiffHunk: { forward in
            forwards.append(forward)
            return true
        })
        let event = makeKeyEvent(keyCode: kVK_UpArrow, modifierFlags: [.option])
        XCTAssertTrue(panel.dispatchKeyboardEvent(event, actions: actions))
        XCTAssertEqual(forwards, [false])
    }

    func testOptionDownDispatchesMoveDiffHunkForward() {
        let panel = makePanel()
        var forwards: [Bool] = []
        let actions = makeActions(moveDiffHunk: { forward in
            forwards.append(forward)
            return true
        })
        let event = makeKeyEvent(keyCode: kVK_DownArrow, modifierFlags: [.option])
        XCTAssertTrue(panel.dispatchKeyboardEvent(event, actions: actions))
        XCTAssertEqual(forwards, [true])
    }

    /// 不在对比态时 ⌥↓ 必须回落成列表下移，否则用户会以为按键坏了
    func testOptionDownFallsBackToArrowWhenDiffNotActive() {
        let panel = makePanel()
        var arrows: [Int] = []
        let actions = makeActions(
            moveDiffHunk: { _ in false },
            arrow: { step, _ in arrows.append(step) }
        )
        let event = makeKeyEvent(keyCode: kVK_DownArrow, modifierFlags: [.option])
        XCTAssertTrue(panel.dispatchKeyboardEvent(event, actions: actions))
        XCTAssertEqual(arrows, [1])
    }

    /// 无修饰 ↓ 绝不能被对比态抢走：列表常规移动是高频操作
    func testPlainDownDoesNotReachMoveDiffHunk() {
        let panel = makePanel()
        var diffCalls = 0
        var arrows: [Int] = []
        let actions = makeActions(
            moveDiffHunk: { _ in
                diffCalls += 1
                return true
            },
            arrow: { step, _ in arrows.append(step) }
        )
        let event = makeKeyEvent(keyCode: kVK_DownArrow)
        XCTAssertTrue(panel.dispatchKeyboardEvent(event, actions: actions))
        XCTAssertEqual(diffCalls, 0)
        XCTAssertEqual(arrows, [1])
    }

    // MARK: - ⌘C

    func testCommandCCopiesMergedWhenDiffActive() {
        let panel = makePanel()
        var merged = false
        var copiedSelection = false
        let actions = makeActions(
            copyMergedDiff: {
                merged = true
                return true
            },
            copySelection: { copiedSelection = true }
        )
        let event = makeKeyEvent(keyCode: kVK_ANSI_C, characters: "c", modifierFlags: [.command])
        XCTAssertTrue(panel.dispatchKeyboardEvent(event, actions: actions))
        XCTAssertTrue(merged)
        XCTAssertFalse(copiedSelection, "对比态已消费 ⌘C，不得再走常规复制选中")
    }

    func testCommandCFallsBackToCopySelectionWhenDiffNotActive() {
        let panel = makePanel()
        var copiedSelection = false
        let actions = makeActions(
            copyMergedDiff: { false },
            copySelection: { copiedSelection = true }
        )
        let event = makeKeyEvent(keyCode: kVK_ANSI_C, characters: "c", modifierFlags: [.command])
        XCTAssertTrue(panel.dispatchKeyboardEvent(event, actions: actions))
        XCTAssertTrue(copiedSelection)
    }

    // MARK: - ⏎

    func testReturnPastesMergedWhenDiffActive() {
        let panel = makePanel()
        var merged = false
        var confirmCalled = false
        let actions = makeActions(
            pasteMergedDiff: {
                merged = true
                return true
            },
            confirm: { _, _ in confirmCalled = true }
        )
        let event = makeKeyEvent(keyCode: kVK_Return)
        XCTAssertTrue(panel.dispatchKeyboardEvent(event, actions: actions))
        XCTAssertTrue(merged)
        XCTAssertFalse(confirmCalled, "⏎ 被对比态接管后不得再触发常规粘贴/批量合并")
    }

    /// 未进对比态时 ⏎ 必须仍旧是常规粘贴（这是全应用最高频的一个键）
    func testReturnFallsBackToConfirmWhenDiffNotActive() {
        let panel = makePanel()
        var confirmArgs: (keepOpen: Bool, plainTextOnly: Bool)?
        let actions = makeActions(
            pasteMergedDiff: { false },
            confirm: { keepOpen, plainTextOnly in
                confirmArgs = (keepOpen: keepOpen, plainTextOnly: plainTextOnly)
            }
        )
        let event = makeKeyEvent(keyCode: kVK_Return)
        XCTAssertTrue(panel.dispatchKeyboardEvent(event, actions: actions))
        XCTAssertEqual(confirmArgs?.keepOpen, false)
        XCTAssertEqual(confirmArgs?.plainTextOnly, false)
    }

    /// ⌃⏎ 脱敏粘贴不能被对比态的 ⏎ 抢走
    func testControlReturnDoesNotReachPasteMerged() {
        let panel = makePanel()
        var mergedCalls = 0
        let actions = makeActions(pasteMergedDiff: {
            mergedCalls += 1
            return true
        })
        let event = makeKeyEvent(keyCode: kVK_Return, modifierFlags: [.control])
        _ = panel.dispatchKeyboardEvent(event, actions: actions)
        XCTAssertEqual(mergedCalls, 0)
    }
}
