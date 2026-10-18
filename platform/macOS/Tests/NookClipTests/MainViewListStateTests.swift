import XCTest
@testable import NookClip

@MainActor
final class MainViewListStateTests: XCTestCase {

    private func makeStore() -> InMemoryHistoryStore {
        let store = makeIsolatedStore()
        store.clearHistory(keepFavorites: false)
        store.save(ClipboardItem(type: .text, title: "alpha", summary: "alpha needle"))
        store.save(ClipboardItem(type: .text, title: "beta", summary: "beta other"))
        return store
    }

    func testListStateQueryAndSelectionSelfHealing() async {
        let store = makeStore()
        let listState = MainViewListState(store: store)

        // 初始无选中无结果
        XCTAssertNil(listState.selectedID)
        XCTAssertTrue(listState.flatRows.isEmpty)

        // 查询 "alpha"
        listState.setSearchText("alpha", dataVersion: store.dataVersion)

        for _ in 0..<50 where listState.flatRows.isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(listState.flatRows.count, 1)
        XCTAssertEqual(listState.flatRows.first?.summary, "alpha needle")
        // 核心不变量：选中态自动闭环落入可见首行，无需外部视图胶水接线
        XCTAssertEqual(listState.selectedID, listState.flatRows.first.map(\.id))
        XCTAssertEqual(listState.selectedRow?.summary, "alpha needle")

        // 切换查询为 "beta"：选中态自动从 alpha 修正为 beta
        listState.setSearchText("beta", dataVersion: store.dataVersion)

        for _ in 0..<50 where listState.flatRows.first?.summary != "beta other" {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(listState.flatRows.count, 1)
        XCTAssertEqual(listState.selectedID, listState.flatRows.first.map(\.id))
        XCTAssertEqual(listState.selectedRow?.summary, "beta other")
    }
    func testCategoryTransitionKeepsSelectionUntilResultsArriveThenSelfHeals() async {
        let store = makeStore()
        guard let beta = store.items.first(where: { $0.summary == "beta other" }) else {
            return XCTFail("expected beta clipboard record")
        }
        store.toggleFavorite(beta.id)
        let state = MainViewListState(store: store)
        state.refresh(dataVersion: store.dataVersion)
        for _ in 0..<50 where state.flatRows.count != 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard let alpha = state.flatRows.first(where: { $0.summary == "alpha needle" }) else {
            return XCTFail("expected alpha result")
        }
        state.selectedID = alpha.id

        XCTAssertTrue(state.setCategorySelection(8, dataVersion: store.dataVersion))
        XCTAssertEqual(
            state.selectedRow?.summary, "alpha needle",
            "切换分类到结果返回前保留原选中，预览区不闪空态"
        )
        for _ in 0..<50 where state.flatRows.count != 1 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(state.flatRows.map(\.summary), ["beta other"])
        XCTAssertEqual(state.selectedID, beta.id)
        XCTAssertEqual(state.selectedID, state.flatRows.first?.id)
    }

    func testFilterResetCancelsPendingSearchAndRestoresAllRows() async {
        let store = makeStore()
        let state = MainViewListState(store: store)
        state.setSearchText("alpha", dataVersion: store.dataVersion)
        state.clearFilters(dataVersion: store.dataVersion)
        for _ in 0..<50 where state.flatRows.count != 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(state.searchText, "")
        XCTAssertEqual(state.categorySelection, 0)
        XCTAssertEqual(Set(state.flatRows.map(\.summary)), Set(["alpha needle", "beta other"]))
        XCTAssertEqual(state.selectedID, state.flatRows.first?.id)
    }

    func testListStateNavigationClamping() async {
        let store = makeStore()
        let listState = MainViewListState(store: store)

        listState.refresh(dataVersion: store.dataVersion)
        for _ in 0..<50 where listState.flatRows.count != 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(listState.flatRows.count, 2)
        let firstID = listState.flatRows[0].id
        let secondID = listState.flatRows[1].id
        XCTAssertEqual(listState.selectedID, firstID)

        // 向下移动：落入第二行
        listState.move(offset: 1)
        XCTAssertEqual(listState.selectedID, secondID)

        // 再次向下移动：边界钳制，保持第二行
        listState.move(offset: 1)
        XCTAssertEqual(listState.selectedID, secondID)

        // 向上移动：回到第一行
        listState.move(offset: -1)
        XCTAssertEqual(listState.selectedID, firstID)

        // 再次向上：钳制在首行
        listState.move(offset: -1)
        XCTAssertEqual(listState.selectedID, firstID)
    }

    func testListStateBatchSelectionAndClear() async {
        let store = makeStore()
        let listState = MainViewListState(store: store)

        listState.refresh(dataVersion: store.dataVersion)
        for _ in 0..<50 where listState.flatRows.count != 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let firstID = listState.flatRows[0].id
        let secondID = listState.flatRows[1].id

        XCTAssertFalse(listState.isBatchMode)

        // Shift + 向下扩展：进入批量模式，同时包含原锚点与目标项
        listState.extend(offset: 1)
        XCTAssertTrue(listState.isBatchMode)
        XCTAssertEqual(listState.selectedID, secondID)
        XCTAssertEqual(listState.selectionIDs, Set([firstID, secondID]))

        // 清除批量状态
        listState.clearBatch()
        XCTAssertFalse(listState.isBatchMode)
        XCTAssertTrue(listState.selectionIDs.isEmpty)
        XCTAssertEqual(listState.selectedID, secondID)
    }

    func testListStateSuccessorIDAfterDelete() async {
        let store = makeStore()
        let listState = MainViewListState(store: store)

        listState.refresh(dataVersion: store.dataVersion)
        for _ in 0..<50 where listState.flatRows.count != 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let firstID = listState.flatRows[0].id
        let secondID = listState.flatRows[1].id

        // 删除首项后，补位项为第二项（直接由深模块计算，不需要外部传入 rows:）
        let successor = listState.successorID(afterDeleting: [firstID])
        XCTAssertEqual(successor, secondID)

        // 删除末项后，补位项回退到上一项
        let successor2 = listState.successorID(afterDeleting: [secondID])
        XCTAssertEqual(successor2, firstID)
    }

    /// 运行时语言切换后，管线必须重算分类显示名（否则筛选条停留在旧语言）
    func testPipelineRelocalizesCategoriesOnLanguageChange() {
        let original = LocalizationManager.shared.selectedLanguage
        LocalizationManager.shared.selectedLanguage = .en
        defer { LocalizationManager.shared.selectedLanguage = original }

        let pipeline = MainViewPipelineModel()
        let zeroCounts = CategoryCounts(total: 0, favorite: 0, text: 0, image: 0, file: 0, url: 0, code: 0, color: 0, sensitive: 0)
        func run() -> [String] {
            pipeline.update(
                queryRows: [], queryVersion: 1, counts: zeroCounts,
                dataVersion: 1, searchText: "", categorySelection: 0
            ).categories.map(\.name)
        }

        XCTAssertEqual(run(), ["All", "Favorites"])
        LocalizationManager.shared.selectedLanguage = .zhHans
        XCTAssertEqual(run(), ["全部", "收藏"])
        // 同语言重复调用命中缓存，输出不变
        XCTAssertEqual(run(), ["全部", "收藏"])
    }

    /// 通用选区状态机 ListSelectionState 可独立于 ClipboardRowModel 驱动任意 Identifiable 行模型（如未来笔记/待办）
    func testGenericListSelectionStateIndependentOfClipboardModel() {
        struct DummyTodoRow: Identifiable, Equatable {
            let id: String
            let text: String
        }
        let rows = [
            DummyTodoRow(id: "todo-1", text: "Buy milk"),
            DummyTodoRow(id: "todo-2", text: "Write spec"),
            DummyTodoRow(id: "todo-3", text: "Ship release")
        ]
        var selection = ListSelectionState<DummyTodoRow>()
        selection.syncWithFilter(rows: rows)
        XCTAssertEqual(selection.selectedID, "todo-1")
        XCTAssertEqual(selection.selectedRow(in: rows)?.text, "Buy milk")

        selection.move(offset: 1, rows: rows)
        XCTAssertEqual(selection.selectedID, "todo-2")

        selection.extend(offset: 1, rows: rows)
        XCTAssertTrue(selection.isBatchMode)
        XCTAssertEqual(selection.selectionIDs, ["todo-2", "todo-3"])
        XCTAssertEqual(selection.successorID(afterDeleting: ["todo-2"], rows: rows), "todo-3")
    }
}
