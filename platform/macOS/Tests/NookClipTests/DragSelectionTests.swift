import XCTest
@testable import NookClip

/// 鼠标拖拽多选：行命中几何 + 整段选区状态机
@MainActor
final class DragSelectionTests: XCTestCase {

    // MARK: 行命中（DragSelectionGeometry）

    /// 三行等高、纵向首尾相接的列表：每行 54pt，行间距 0
    private let stackedFrames: [String: CGRect] = [
        "A": CGRect(x: 0, y: 0, width: 310, height: 54),
        "B": CGRect(x: 0, y: 54, width: 310, height: 54),
        "C": CGRect(x: 0, y: 108, width: 310, height: 54)
    ]

    func testRowKeyHitsRowContainingPointer() {
        XCTAssertEqual(DragSelectionGeometry.rowKey(atY: 10, frames: stackedFrames), "A")
        XCTAssertEqual(DragSelectionGeometry.rowKey(atY: 54, frames: stackedFrames), "B")
        XCTAssertEqual(DragSelectionGeometry.rowKey(atY: 80, frames: stackedFrames), "B")
        XCTAssertEqual(DragSelectionGeometry.rowKey(atY: 161, frames: stackedFrames), "C")
    }

    /// 指针拖出列表底边之外（自动滚动前后坐标尚未刷新）仍要命中末行，
    /// 否则「拖到最底部」会选不到最后一条
    func testRowKeyClampsWhenPointerIsOutsideList() {
        XCTAssertEqual(DragSelectionGeometry.rowKey(atY: -200, frames: stackedFrames), "A")
        XCTAssertEqual(DragSelectionGeometry.rowKey(atY: 9999, frames: stackedFrames), "C")
    }

    /// 行间存在缝隙（分组间距）时，落在缝隙里命中更近的一侧
    func testRowKeyHandlesGapsBetweenRows() {
        let frames: [String: CGRect] = [
            "A": CGRect(x: 0, y: 0, width: 310, height: 54),
            "B": CGRect(x: 0, y: 74, width: 310, height: 54) // 中间 20pt 缝隙
        ]
        XCTAssertEqual(DragSelectionGeometry.rowKey(atY: 56, frames: frames), "A")
        XCTAssertEqual(DragSelectionGeometry.rowKey(atY: 72, frames: frames), "B")
    }

    /// 空列表不崩溃、返回 nil（拖拽因此不会被接管）
    func testRowKeyReturnsNilForEmptyFrames() {
        XCTAssertNil(DragSelectionGeometry.rowKey(atY: 100, frames: [:]))
    }

    // MARK: 整段选区（ListSelectionState.selectRange）

    private struct Row: Identifiable, Equatable {
        let id: String
    }

    private let rows = [Row(id: "1"), Row(id: "2"), Row(id: "3"), Row(id: "4"), Row(id: "5")]

    /// 向下拖：从锚点选到终点，选区同时把终点设为当前行
    func testSelectRangeForwardCoversContiguousSpan() {
        var selection = ListSelectionState<Row>()
        selection.syncWithFilter(rows: rows)
        selection.selectRange(from: "2", to: "4", rows: rows)
        XCTAssertEqual(selection.selectionIDs, ["2", "3", "4"])
        XCTAssertEqual(selection.selectedID, "4")
    }

    /// 向上拖：同样整段选中，不要求锚点在终点之前
    func testSelectRangeBackwardCoversSameSpan() {
        var selection = ListSelectionState<Row>()
        selection.syncWithFilter(rows: rows)
        selection.selectRange(from: "4", to: "2", rows: rows)
        XCTAssertEqual(selection.selectionIDs, ["2", "3", "4"])
        XCTAssertEqual(selection.selectedID, "2")
    }

    /// 往回拖必须能收窄选区：范围内只剩两行时不能残留上一次拖出的更大范围
    func testSelectRangeShrinksWhenDraggingBackward() {
        var selection = ListSelectionState<Row>()
        selection.syncWithFilter(rows: rows)
        selection.selectRange(from: "1", to: "5", rows: rows)
        XCTAssertEqual(selection.selectionIDs.count, 5)

        selection.selectRange(from: "1", to: "2", rows: rows)
        XCTAssertEqual(selection.selectionIDs, ["1", "2"])
    }

    /// ⇧ 拖拽：在既有勾选上追加，不清掉之前选好的条目
    func testSelectRangeWithBaselineAppendsToExistingSelection() {
        var selection = ListSelectionState<Row>()
        selection.syncWithFilter(rows: rows)
        selection.handleTap(rows[0], rows: rows, shiftHeld: false, commandHeld: true) // 勾选 1
        let baseline = selection.selectionIDs
        XCTAssertEqual(baseline, ["1"])

        selection.selectRange(from: "3", to: "4", rows: rows, addingTo: baseline)
        XCTAssertEqual(selection.selectionIDs, ["1", "3", "4"])
    }

    /// 锚点或终点不在当前结果里（拖拽中途列表被刷新）时保持原选区不变，不崩
    func testSelectRangeIgnoresUnknownIDs() {
        var selection = ListSelectionState<Row>()
        selection.syncWithFilter(rows: rows)
        selection.selectRange(from: "2", to: "4", rows: rows)
        let before = selection.selectionIDs

        selection.selectRange(from: "missing", to: "4", rows: rows)
        XCTAssertEqual(selection.selectionIDs, before)

        selection.selectRange(from: "2", to: "missing", rows: rows)
        XCTAssertEqual(selection.selectionIDs, before)
    }

    // MARK: 与 MainViewListState 的接线

    /// 拖拽选出的整段必须与 ⇧↑↓ 扩展出的整段一致（同一套 flatRows 顺序）
    func testMainViewListStateSelectRangeMatchesKeyboardExtension() async {
        let store = makeIsolatedStore()
        store.clearHistory(keepFavorites: false)
        for index in 0..<5 {
            store.save(ClipboardItem(type: .text, title: "row-\(index)", summary: "row-\(index) summary"))
        }
        let listState = MainViewListState(store: store)
        listState.refresh(dataVersion: store.dataVersion)
        for _ in 0..<50 where listState.flatRows.count != 5 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(listState.flatRows.count, 5)

        let ids = listState.flatRows.map(\.id)
        listState.selectRange(from: ids[1], to: ids[3])
        let dragged = listState.selectionIDs
        XCTAssertEqual(dragged, Set(ids[1...3]))

        // 键盘路径：选中首项后连续 ⇧↓ 三次得到同一区间
        listState.selectedID = ids[1]
        listState.clearBatch()
        listState.extend(offset: 1, rows: listState.flatRows)
        listState.extend(offset: 1, rows: listState.flatRows)
        XCTAssertEqual(listState.selectionIDs, dragged)
    }

    /// 拖拽参数：阈值与屏蔽窗口取保守值，避免与单击/双击抢手势
    func testDragSelectionConstantsAreConservative() {
        XCTAssertGreaterThan(DragSelection.minimumDistance, 0)
        XCTAssertLessThanOrEqual(DragSelection.minimumDistance, 5)
        XCTAssertGreaterThan(DragSelection.tapSuppressWindow, 0)
        XCTAssertGreaterThan(DragSelection.autoScrollEdgeMargin, 0)
        XCTAssertGreaterThan(DragSelection.autoScrollIntervalMs, 0)
    }

    /// 新文案三语齐备（贡献规范：用户可见文案必须同步 en / zh-Hans / zh-Hant）
    func testDragMultiSelectHintIsLocalizedInAllLanguages() {
        for language in ["zh-Hans", "zh-Hant", "en"] {
            guard let path = Bundle.module.path(forResource: language, ofType: "lproj"),
                  let bundle = Bundle(path: path) else {
                XCTFail("缺少语言包: \(language)")
                continue
            }
            let text = bundle.localizedString(forKey: "hints.drag_multi", value: nil, table: nil)
            XCTAssertNotEqual(text, "hints.drag_multi", "\(language) 缺少拖动多选文案")
            XCTAssertFalse(text.isEmpty, "\(language) 拖动多选文案为空")
        }
    }
}
