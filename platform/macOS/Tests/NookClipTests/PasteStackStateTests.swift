import XCTest
import Carbon.HIToolbox
@testable import NookClip

// specs/012-scrub-stack-pin · T014
// 顺序粘贴栈状态机测试（US2）。
//
// 只测 `PasteStackState` 这一层纯状态：指针推进、正/倒序、录制追加、边界收尾。
// 控制器里监听 ⌘V 的全局监听、胶囊窗 NSWindow 都依赖真实 NSApp 事件循环，
// 放进单测会变成「测 AppKit」而不是测我们的逻辑，故不在此覆盖。
// ClipboardItem 只当快照容器用，不触达剪贴板与数据库。

@MainActor
final class PasteStackStateTests: XCTestCase {

    private func makeItems(_ count: Int) -> [ClipboardItem] {
        (0..<count).map { index in
            ClipboardItem(
                id: UUID(),
                type: .text,
                title: "条目\(index)",
                summary: "内容\(index)"
            )
        }
    }

    // MARK: - 起点

    func testFIFOStartsAtHeadAndLIFOAtTail() {
        XCTAssertEqual(PasteStackOrder.fifo.startIndex(count: 5), 0)
        XCTAssertEqual(PasteStackOrder.lifo.startIndex(count: 5), 4)
        // 空队列不越界
        XCTAssertEqual(PasteStackOrder.fifo.startIndex(count: 0), 0)
        XCTAssertEqual(PasteStackOrder.lifo.startIndex(count: 0), 0)
    }

    func testDirectionMatchesOrder() {
        XCTAssertEqual(PasteStackOrder.fifo.direction, 1)
        XCTAssertEqual(PasteStackOrder.lifo.direction, -1)
    }

    // MARK: - 装载

    func testSetItemsLandsOnOrderSpecificStartIndex() {
        let state = PasteStackState()
        state.setItems(makeItems(4), order: .fifo)
        XCTAssertEqual(state.total, 4)
        XCTAssertEqual(state.currentIndex, 0)
        XCTAssertEqual(state.position, 1)

        let reverse = PasteStackState()
        reverse.setItems(makeItems(4), order: .lifo)
        XCTAssertEqual(reverse.currentIndex, 3)
        XCTAssertEqual(reverse.position, 4)
    }

    func testEmptyStackReportsZeroPosition() {
        let state = PasteStackState()
        XCTAssertEqual(state.total, 0)
        XCTAssertEqual(state.position, 0)
        XCTAssertNil(state.currentItem)
        XCTAssertNil(state.nextItem)
    }

    // MARK: - 推进

    func testMoveAdvancesAndReportsNextItem() {
        let state = PasteStackState()
        state.setItems(makeItems(3), order: .fifo)

        XCTAssertEqual(state.currentItem?.summary, "内容0")
        XCTAssertEqual(state.nextItem?.summary, "内容1")

        state.move(to: 1)
        XCTAssertEqual(state.position, 2)
        XCTAssertEqual(state.currentItem?.summary, "内容1")
        XCTAssertEqual(state.nextItem?.summary, "内容2")

        state.move(to: 2)
        XCTAssertEqual(state.position, 3)
        // 最后一条没有「下一条」
        XCTAssertNil(state.nextItem)
    }

    func testLIFOMovesBackwardsAndNextPreviewPointsUpwards() {
        let state = PasteStackState()
        state.setItems(makeItems(3), order: .lifo)

        XCTAssertEqual(state.currentItem?.summary, "内容2")
        XCTAssertEqual(state.nextItem?.summary, "内容1")

        state.move(to: 1)
        XCTAssertEqual(state.currentItem?.summary, "内容1")
        XCTAssertEqual(state.nextItem?.summary, "内容0")
    }

    /// 越界索引必须被拒绝而不是夹紧：指针不动，胶囊窗也不会显示错条目
    func testMoveIgnoresOutOfRangeIndex() {
        let state = PasteStackState()
        state.setItems(makeItems(3), order: .fifo)
        state.move(to: 1)

        state.move(to: 99)
        XCTAssertEqual(state.currentIndex, 1)

        state.move(to: -5)
        XCTAssertEqual(state.currentIndex, 1)
    }

    // MARK: - 录制

    func testRecordingAppendExtendsQueue() {
        let state = PasteStackState()
        state.reset()
        state.setRecording(true)
        XCTAssertTrue(state.isRecording)
        XCTAssertEqual(state.total, 0)

        let items = makeItems(2)
        state.append(items[0])
        XCTAssertEqual(state.total, 1)
        XCTAssertEqual(state.currentItem?.summary, "内容0")

        state.append(items[1])
        XCTAssertEqual(state.total, 2)
        // 高亮 = 下一条待粘贴，录制途中一条都还没贴 → 仍停在第一条，
        // 不会被新复制进来的内容抢走
        XCTAssertEqual(state.currentItem?.summary, "内容0")
    }

    func testPausedFlagToggles() {
        let state = PasteStackState()
        XCTAssertFalse(state.isPaused)
        state.setPaused(true)
        XCTAssertTrue(state.isPaused)
    }

    // MARK: - 完成与复位

    func testCompletedFlagAndReset() {
        let state = PasteStackState()
        state.setItems(makeItems(2), order: .fifo)
        state.setCompleted(true)
        XCTAssertTrue(state.isCompleted)

        state.reset()
        XCTAssertTrue(state.items.isEmpty)
        XCTAssertEqual(state.currentIndex, 0)
        XCTAssertFalse(state.isCompleted)
        XCTAssertFalse(state.isRecording)
        XCTAssertFalse(state.isPaused)
        // 顺序是用户偏好，reset 不该重置它
        XCTAssertEqual(state.order, .fifo)
    }

    // MARK: - 出栈顺序

    func testOrderIsPreservedAcrossResetAndChanges() {
        let state = PasteStackState()
        state.setOrder(.lifo)
        state.setItems(makeItems(2), order: .lifo)
        XCTAssertEqual(state.currentIndex, 1)

        state.reset()
        // reset 不动 order 是刻意的：reset 只管清队列，方向由控制器决定。
        // 新队列一律从正序开始（`PasteStackController.start(with:)` /
        // `startRecording()` 都显式传 `.fifo`），否则用户上一次顺手点过倒序
        // 徽标，之后每条新队列都会默默反着贴——这正是「顺序粘贴没按复制顺序」
        // 最隐蔽的成因，故在控制器入口强制复位而不是靠这里。
        XCTAssertEqual(state.order, .lifo)
    }

    /// 控制器入口必须能把方向复位（`start` / `startRecording` 调的就是它）
    func testSetOrderResetsDirectionForNewQueue() {
        let state = PasteStackState()
        state.setOrder(.lifo)
        state.setItems(makeItems(3), order: .lifo)
        XCTAssertEqual(state.currentIndex, 2)

        state.setOrder(.fifo)
        state.setItems(makeItems(3), order: state.order)
        XCTAssertEqual(state.currentIndex, 0, "新队列从正序起点开始")
    }

    // MARK: - 已贴记录（列表对勾）

    func testSetItemsClearsPastedMarks() {
        let state = PasteStackState()
        let items = makeItems(3)
        state.setItems(items, order: .fifo)
        state.markPasted(items[0].id)
        XCTAssertTrue(state.hasPasted(items[0]))
        XCTAssertEqual(state.remaining, 2)

        // 换一批队列必须清空上一批的对勾，否则新列表会带着旧记录
        state.setItems(makeItems(2), order: .fifo)
        XCTAssertTrue(state.pastedIDs.isEmpty)
        XCTAssertEqual(state.remaining, 2)
    }

    func testMarkPastedIsIdempotentAndTracksRemaining() {
        let state = PasteStackState()
        let items = makeItems(3)
        state.setItems(items, order: .fifo)

        state.markPasted(items[0].id)
        state.markPasted(items[0].id)
        // 同一条重复标记不该让「已贴数」跳两格
        XCTAssertEqual(state.pastedIDs.count, 1)
        XCTAssertEqual(state.remaining, 2)

        state.markPasted(items[2].id)
        XCTAssertEqual(state.pastedIDs.count, 2)
        XCTAssertEqual(state.remaining, 1)
        // 没贴过的条目依然是 false
        XCTAssertFalse(state.hasPasted(items[1]))
    }

    func testResetClearsPastedMarks() {
        let state = PasteStackState()
        let items = makeItems(2)
        state.setItems(items, order: .fifo)
        state.markPasted(items[0].id)

        state.reset()
        XCTAssertTrue(state.pastedIDs.isEmpty)
        XCTAssertEqual(state.remaining, 0)
    }

    // MARK: - 浮窗尺寸

    func testPillSizeGrowsWithRowCountUntilCap() {
        let one = PasteStackPillPanel.size(rowCount: 1)
        let three = PasteStackPillPanel.size(rowCount: 3)
        let capped = PasteStackPillPanel.size(rowCount: 12)

        XCTAssertEqual(one.width, PasteStackPillPanel.width)
        XCTAssertLessThan(one.height, three.height)
        // 超过可见行数就封顶，剩下的靠列表内部滚动
        XCTAssertEqual(capped.height, PasteStackPillPanel.size(rowCount: PasteStackPillPanel.maxVisibleRows).height)
        // 空队列也要给出能显示「等待复制…」的高度，不能是 0
        XCTAssertGreaterThan(PasteStackPillPanel.size(rowCount: 0).height, 0)
    }

    // MARK: - 高亮行（m02918：高亮 = 下一条待粘贴，贴完自动前移）

    /// 高亮不是「选中」，而是「下一条待粘贴」的进度指示。
    /// 正序指向第一条、倒序指向最后一条——两者都是「按 ⌘V 会先贴哪条」。
    func testHighlightStartsAtFirstRowToPasteInBothOrders() {
        let fifo = PasteStackState()
        fifo.setItems(makeItems(4), order: .fifo)
        XCTAssertEqual(fifo.currentIndex, 0)
        XCTAssertEqual(fifo.currentItem?.summary, "内容0")

        let lifo = PasteStackState()
        lifo.setItems(makeItems(4), order: .lifo)
        XCTAssertEqual(lifo.currentIndex, 3)
        XCTAssertEqual(lifo.currentItem?.summary, "内容3")
    }

    /// 贴完一条高亮自动前移：这才是「标示出哪条是待粘贴的提示」该有的行为。
    func testHighlightAdvancesAfterPaste() {
        let state = PasteStackState()
        let items = makeItems(3)
        state.setItems(items, order: .fifo)

        state.markPasted(items[0].id)
        state.move(to: 1)
        XCTAssertEqual(state.currentItem?.summary, "内容1")

        state.markPasted(items[1].id)
        state.move(to: 2)
        XCTAssertEqual(state.currentItem?.summary, "内容2")
    }

    /// 点某行把高亮挪过去（`jumpToItem` 的模型侧动作），并且不动已贴记录
    func testMoveRelocatesHighlightWithoutTouchingPastedMarks() {
        let state = PasteStackState()
        let items = makeItems(3)
        state.setItems(items, order: .fifo)
        state.markPasted(items[0].id)

        state.move(to: 2)
        XCTAssertEqual(state.currentItem?.summary, "内容2")
        // 已贴记录独立于指针：指针跳走不该把对勾擦掉
        XCTAssertTrue(state.hasPasted(items[0]))
        XCTAssertEqual(state.pastedIDs.count, 1)
    }

    func testMoveIgnoresOutOfBounds() {
        let state = PasteStackState()
        state.setItems(makeItems(2), order: .fifo)
        state.move(to: 1)

        state.move(to: 5)
        XCTAssertEqual(state.currentIndex, 1)
        state.move(to: -1)
        XCTAssertEqual(state.currentIndex, 1)
    }

    /// 录制追加时，只有队列原本已经贴空，新条目才配得上「下一条待粘贴」的高亮；
    /// 否则用户正盯着某条，高亮不该被新来的内容抢走。
    func testAppendOnlyStealsHighlightWhenQueueWasFullyPasted() {
        let state = PasteStackState()
        let items = makeItems(2)
        state.setItems(items, order: .fifo)
        state.setRecording(true)

        // 队列里还有没贴的 → 追加后高亮留在原地
        state.append(makeItems(1)[0])
        XCTAssertEqual(state.currentIndex, 0)

        // 把原有两条都贴掉 → 追加的新条目就是下一条
        state.markPasted(items[0].id)
        state.markPasted(items[1].id)
        state.append(makeItems(1)[0])
        XCTAssertEqual(state.currentIndex, 2)

        state.setItems(makeItems(3), order: .fifo)
        XCTAssertEqual(state.currentIndex, 0)
    }

    /// 跳过已贴的行：贴完第 1 条后高亮落到第 2 条，再贴第 2 条后落到第 3 条
    func testNextUnpastedIndexSkipsPastedRows() {
        let state = PasteStackState()
        let items = makeItems(3)
        state.setItems(items, order: .fifo)

        XCTAssertEqual(state.nextUnpastedIndex(after: 0)?.description, "1")
        state.markPasted(items[0].id)
        XCTAssertEqual(state.nextUnpastedIndex(after: 0), 1)

        state.markPasted(items[1].id)
        XCTAssertEqual(state.nextUnpastedIndex(after: 1), 2)

        state.markPasted(items[2].id)
        XCTAssertNil(state.nextUnpastedIndex(after: 2))
    }

    /// 跳着贴时高亮要绕回头部去找没贴的那条，而不是机械 +1 踩在已贴行上
    func testNextUnpastedIndexWrapsAroundWhenTailIsDone() {
        let state = PasteStackState()
        let items = makeItems(3)
        state.setItems(items, order: .fifo)
        // 先贴第 2、3 条，再贴第 1 条：剩下的未贴项在第 2 位之前没有了吗？
        // 这里贴满后两条后，头部只剩第 0 条没贴 → 从 index 2 往后绕到 0
        state.markPasted(items[1].id)
        state.markPasted(items[2].id)
        XCTAssertEqual(state.nextUnpastedIndex(after: 1), 0)
        XCTAssertEqual(state.nextUnpastedIndex(after: 2), 0)
    }

    /// 倒序时绕回方向相反：从头侧绕到尾侧
    func testNextUnpastedIndexFollowsOrderDirection() {
        let state = PasteStackState()
        let items = makeItems(3)
        state.setItems(items, order: .lifo)
        // 倒序从队尾开始，贴掉第 3 条后应往前找第 2 条
        state.markPasted(items[2].id)
        XCTAssertEqual(state.nextUnpastedIndex(after: 2), 1)
        // 头尾都贴掉只剩中间时，从 index 0 往后绕应该找到 1
        state.markPasted(items[0].id)
        XCTAssertEqual(state.nextUnpastedIndex(after: 0), 1)
    }

    /// 空队列不崩、返回 nil
    func testNextUnpastedIndexOnEmptyQueueIsNil() {
        let state = PasteStackState()
        XCTAssertNil(state.nextUnpastedIndex(after: 0))
        state.setItems([], order: .fifo)
        XCTAssertNil(state.nextUnpastedIndex(after: -5))
    }

    /// 高亮的默认落点 = 第一条没贴的；倒序时从队尾开始找
    func testFirstUnpastedIndexFollowsOrder() {
        let fifo = PasteStackState()
        let items = makeItems(3)
        fifo.setItems(items, order: .fifo)
        XCTAssertEqual(fifo.firstUnpastedIndex(), 0)
        fifo.markPasted(items[0].id)
        XCTAssertEqual(fifo.firstUnpastedIndex(), 1)

        let lifo = PasteStackState()
        lifo.setItems(items, order: .lifo)
        XCTAssertEqual(lifo.firstUnpastedIndex(), 2)
        lifo.markPasted(items[2].id)
        XCTAssertEqual(lifo.firstUnpastedIndex(), 1)

        let empty = PasteStackState()
        XCTAssertNil(empty.firstUnpastedIndex())
    }

    func testResetClearsHighlightAndPastedMarks() {
        let state = PasteStackState()
        let items = makeItems(3)
        state.setItems(items, order: .fifo)
        state.markPasted(items[0].id)
        state.move(to: 2)

        state.reset()
        XCTAssertEqual(state.currentIndex, 0)
        XCTAssertNil(state.currentItem)
        XCTAssertTrue(state.pastedIDs.isEmpty)
    }

    // MARK: 全局 Esc 退出判定（m03319 补：浮窗是 .nonactivatingPanel，从不成为 key window，
    // 只靠窗口内 handleKey 接 Esc 会让底部「Esc 结束」变成空头承诺）

    private func makeKeyEvent(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    func testBareEscapeIsRecognizedGlobally() {
        let event = makeKeyEvent(keyCode: UInt16(kVK_Escape), flags: [])
        XCTAssertTrue(PasteStackController.isEscapeKey(event))
    }

    func testEscapeWithModifiersIsNotTreatedAsExit() {
        XCTAssertFalse(PasteStackController.isEscapeKey(makeKeyEvent(keyCode: UInt16(kVK_Escape), flags: .command)))
        XCTAssertFalse(PasteStackController.isEscapeKey(makeKeyEvent(keyCode: UInt16(kVK_Escape), flags: .option)))
        XCTAssertFalse(PasteStackController.isEscapeKey(makeKeyEvent(keyCode: UInt16(kVK_Escape), flags: .shift)))
    }

    func testOtherKeysAreNotTreatedAsEscape() {
        XCTAssertFalse(PasteStackController.isEscapeKey(makeKeyEvent(keyCode: UInt16(kVK_ANSI_V), flags: [])))
        XCTAssertFalse(PasteStackController.isEscapeKey(makeKeyEvent(keyCode: UInt16(kVK_Return), flags: [])))
    }

    // MARK: - 建队排序（按复制先后，而非列表显示序）

    /// 造一条指定复制时间的条目
    private func makeItem(_ title: String, lastUsedAt seconds: TimeInterval) -> ClipboardItem {
        ClipboardItem(
            id: UUID(),
            type: .text,
            title: title,
            summary: title,
            createdAt: Date(timeIntervalSince1970: seconds),
            lastUsedAt: Date(timeIntervalSince1970: seconds)
        )
    }

    /// 列表是「最新在前」，建队必须翻回来——这是用户反馈「没按复制顺序贴」的根因
    func testQueueOrderIsOldestFirstNotDisplayOrder() {
        // 复制顺序 A → B → C，列表显示顺序是 C、B、A
        let a = makeItem("A", lastUsedAt: 100)
        let b = makeItem("B", lastUsedAt: 200)
        let c = makeItem("C", lastUsedAt: 300)
        let displayOrder = [c, b, a]

        let queue = PasteStackQueue.inCopyOrder(displayOrder)

        XCTAssertEqual(queue.map(\.title), ["A", "B", "C"],
                       "队列必须按复制时间升序，而不是列表显示序")
    }

    /// 同一时间戳不靠 sort 的随机稳定性，必须有确定性兜底
    func testQueueOrderIsDeterministicWhenTimestampsTie() {
        let sameTime: TimeInterval = 500
        let first = ClipboardItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            type: .text, title: "T1", summary: "T1",
            createdAt: Date(timeIntervalSince1970: sameTime),
            lastUsedAt: Date(timeIntervalSince1970: sameTime)
        )
        let second = ClipboardItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            type: .text, title: "T2", summary: "T2",
            createdAt: Date(timeIntervalSince1970: sameTime),
            lastUsedAt: Date(timeIntervalSince1970: sameTime)
        )

        let forward = PasteStackQueue.inCopyOrder([second, first]).map(\.title)
        let backward = PasteStackQueue.inCopyOrder([first, second]).map(\.title)
        XCTAssertEqual(forward, backward, "输入顺序不同也必须得到同一队列")
    }

    /// 只剩 1 条或 0 条时不该崩，也不该被过滤掉
    func testQueueOrderHandlesFewerThanTwoItems() {
        XCTAssertTrue(PasteStackQueue.inCopyOrder([]).isEmpty)
        XCTAssertEqual(PasteStackQueue.inCopyOrder([makeItem("X", lastUsedAt: 1)]).count, 1)
    }

    // MARK: - 飞行动画的落点槽位

    /// 新行落在第几个可视槽位。
    ///
    /// 这是飞行卡片的落点计算里唯一有分支的地方，抽成断言比在真机上肉眼数行更可靠：
    /// 不足一屏时就是它自己的序号；超过一屏时列表会跟到最后一行，
    /// 视觉上永远落在最后一个可见槽位。
    func testArrivalSlotFollowsVisibleWindow() {
        func slot(forCount count: Int) -> Int {
            let lastIndex = count - 1
            return min(max(lastIndex, 0), PasteStackPillPanel.maxVisibleRows - 1)
        }

        XCTAssertEqual(slot(forCount: 1), 0, "第一条落在第一行")
        XCTAssertEqual(slot(forCount: 3), 2, "三条时落在第三行")
        XCTAssertEqual(slot(forCount: 5), 4, "刚好一屏时落在最后一行")
        XCTAssertEqual(slot(forCount: 6), 4, "超过一屏后仍停在最后一个可见槽位")
        XCTAssertEqual(slot(forCount: 40), 4, "再多也不会越界")
    }

    /// 落点槽位永远不能越出可视区，否则 `screenRect(forRow:)` 会返回 nil，
    /// 卡片就失去落点、只能退化到「落到列表区域」。
    func testArrivalSlotNeverExceedsVisibleRows() {
        for count in 0...30 {
            let slot = min(max(count - 1, 0), PasteStackPillPanel.maxVisibleRows - 1)
            XCTAssertGreaterThanOrEqual(slot, 0)
            XCTAssertLessThan(slot, PasteStackPillPanel.maxVisibleRows)
        }
    }

    // MARK: - 剪贴板与高亮的一致性（m04476 回归）

    /// 录制模式的核心不变量：复制进来一条之后，必须能判断出「剪贴板要不要校正」。
    ///
    /// 复现用户报的「复制 1、2、3，粘贴出来 3、2、3」：
    /// 依次复制三条时高亮始终停在第一条（用户还没贴），于是后两次复制都必须
    /// 触发校正，否则下一次 ⌘V 会贴出最新那条而不是高亮那条。
    func testHighlightMismatchDetectedWhileEarlierRowsRemainUnpasted() {
        let state = PasteStackState()
        state.setItems([], order: .fifo)
        state.setRecording(true)

        let items = makeItems(3)
        for (offset, item) in items.enumerated() {
            state.append(item)
            // 一条都没贴过，高亮必须一直停在第一条
            XCTAssertEqual(state.currentIndex, 0, "第 \(offset + 1) 次复制后高亮不该被抢走")
            // 除第一条外，每次复制都应判定为「与高亮不一致」→ 需要校正剪贴板
            XCTAssertEqual(
                state.isHighlighted(item),
                offset == 0,
                "第 \(offset + 1) 次复制后的剪贴板校正判断不对"
            )
        }
    }

    /// 高亮那条贴出去之后，新复制的内容才该接管高亮与剪贴板。
    func testAppendTakesOverHighlightOnceEarlierRowsArePasted() {
        let state = PasteStackState()
        state.setItems([], order: .fifo)
        state.setRecording(true)

        let first = makeItems(1)[0]
        state.append(first)
        XCTAssertTrue(state.isHighlighted(first))

        // 第一条贴出去后高亮无处可去（队列只有它），下一次复制才轮到新条目
        state.markPasted(first.id)
        let second = makeItems(1)[0]
        state.append(second)
        XCTAssertEqual(state.currentIndex, 1, "前一条已贴，高亮应落到新条目")
        XCTAssertTrue(state.isHighlighted(second), "剪贴板已经是它，不需要校正")
    }

    /// 空队列时 `isHighlighted` 必须安全返回 false，不能越界崩溃。
    func testIsHighlightedIsSafeOnEmptyQueue() {
        let state = PasteStackState()
        XCTAssertFalse(state.isHighlighted(makeItems(1)[0]))
    }
}
