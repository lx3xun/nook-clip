import XCTest
@testable import NookClip

/// 主界面协调器纯状态测试（US5 步骤一）：搜索代际、选择边界、范围勾选、菜单状态机。
/// 不依赖 GUI；键盘完整时序（Esc/Enter 优先级）由手工验证覆盖（quickstart.md）。
@MainActor
final class MainViewStateTests: XCTestCase {

    private func makeStore() -> InMemoryHistoryStore {
        let store = makeIsolatedStore()
        store.clearHistory(keepFavorites: false)
        store.save(ClipboardItem(type: .text, title: "alpha", summary: "alpha needle"))
        store.save(ClipboardItem(type: .text, title: "beta", summary: "beta other"))
        return store
    }

    private func makeRows(_ summaries: [String]) -> [ClipboardRowModel] {
        ClipboardRowModel.map(summaries.map {
            ClipboardItem(type: .text, title: $0, summary: $0)
        })
    }

    // MARK: - 查询代际与统一数据源

    /// 连续两次搜索变更：只应用最后一个查询；清空筛选恢复全部结果，同键刷新短路。
    func testSearchStaleGenerationDiscarded() async {
        let store = makeStore()
        let coordinator = MainViewListState(store: store)
        var applied = 0
        coordinator.onResultsApplied = { applied += 1 }

        // 两次输入未等待：debounce 被重置，只发起最终查询
        coordinator.setSearchText("alpha", dataVersion: store.dataVersion)
        coordinator.setSearchText("beta", dataVersion: store.dataVersion)

        // 等待任务落定（内存库同步执行，两次 yield 足够）
        for _ in 0..<50 where coordinator.results.isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(coordinator.results.count, 1, "只应用最后一次查询")
        XCTAssertEqual(coordinator.results.first?.summary, "beta other", "旧代际结果被丢弃")
        XCTAssertEqual(applied, 1, "过期结果不触发应用回调")

        // 空关键词 = 「全部」视图的全历史列表查询
        coordinator.clearFilters(dataVersion: store.dataVersion)
        for _ in 0..<50 where coordinator.results.count != 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(coordinator.results.count, 2)
        XCTAssertFalse(coordinator.hasMore)
        XCTAssertFalse(coordinator.failed)
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertEqual(applied, 2)

        // 同键短路：条件与数据版本都未变时不重复查询、不触发应用回调
        coordinator.refresh(dataVersion: store.dataVersion)
        XCTAssertEqual(applied, 2, "同键请求直接复用上次结果")
    }

    /// 分类预筛只作用于行结果；计数集不含预筛（chip facet 不随分类选中塌缩）
    func testCategoryPrefilterKeepsCountResultsUnfiltered() async {
        let store = makeStore()
        guard let firstID = store.items.first?.id else {
            return XCTFail("播种后应有条目")
        }
        store.toggleFavorite(firstID)

        let coordinator = MainViewListState(store: store)
        coordinator.setCategorySelection(8, dataVersion: store.dataVersion)
        for _ in 0..<50 where coordinator.categoryCounts.total == 0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(coordinator.categoryCounts.total, 2, "全量分类计数不含分类预筛")
        XCTAssertEqual(coordinator.categoryCounts.favorite, 1, "全量分类收藏数准确")
    }

    // MARK: - 过滤管线（统一查询链）

    /// 管线契约：软删除条目不产生分类 chip（回收站视图已移除，删除走撤销机制）；
    /// 关键词命中行复核派生分类；chip 计数来自无预筛计数集
    func testPipelineHasNoTrashCategoryAfterDelete() {
        let store = makeStore()
        guard let beta = store.items.first(where: { $0.summary == "beta other" }) else {
            return XCTFail("播种后应有 beta 条目")
        }
        store.delete(beta.id)

        let model = MainViewPipelineModel()
        let queryRows = ClipboardRowModel.map(store.items.filter { $0.summary.contains("needle") })
        let counts = store.rustStore.countCategories(query: "needle")

        let out = model.update(
            queryRows: queryRows, queryVersion: 1,
            counts: counts,
            dataVersion: store.dataVersion,
            searchText: "needle",
            categorySelection: 0
        )
        XCTAssertEqual(out.flatRows.map(\.summary), ["alpha needle"], "关键词命中行")
        XCTAssertFalse(out.categories.contains { $0.id == 9 }, "软删除条目不产生分类 chip")
        XCTAssertEqual(out.categories.first?.count, 1, "needle 关键词下全历史命中只有 alpha 一条")

        // 撤销恢复后：beta 不含 needle，needle 搜索下计数仍为 1；全库计数恢复
        store.restoreFromTrash([beta.id])
        let allCounts = store.rustStore.countCategories(query: "")
        let out2 = model.update(
            queryRows: queryRows, queryVersion: 1,
            counts: allCounts,
            dataVersion: store.dataVersion,
            searchText: "",
            categorySelection: 0
        )
        XCTAssertEqual(out2.categories.first?.count, 2, "撤销恢复后全库计数回升为 2")
    }

    // MARK: - 选择边界

    /// ↑↓ 移动在边界钳制不越界：无选中 → ↑ 落首行；末行 ↓ 保持末行
    func testMoveSelectionClampsAtBounds() {
        let coordinator = MainViewListState(store: makeStore())
        let rows = makeRows(["r0", "r1", "r2", "r3"])

        // 无选中时 ↑：索引按 -1 处理 → 钳制到首行
        coordinator.move(offset: -1, rows: rows)
        XCTAssertEqual(coordinator.selectedID, rows.first?.id, "无选中 ↑ 落首行")

        // 首行再 ↑：保持首行
        coordinator.move(offset: -1, rows: rows)
        XCTAssertEqual(coordinator.selectedID, rows.first?.id, "首行 ↑ 不越界")

        // 跳到末行再 ↓：保持末行
        coordinator.selectedID = rows.last?.id
        coordinator.move(offset: 1, rows: rows)
        XCTAssertEqual(coordinator.selectedID, rows.last?.id, "末行 ↓ 不越界")
        coordinator.move(offset: 10, rows: rows)
        XCTAssertEqual(coordinator.selectedID, rows.last?.id, "大幅越界钳制到末行")
    }

    /// ⇧ 范围选择包含首尾且并入既有勾选（并集语义，锚点不移动）
    func testShiftRangeSelectionIncludesBothEnds() {
        let coordinator = MainViewListState(store: makeStore())
        let rows = makeRows(["r0", "r1", "r2", "r3", "r4"])
        coordinator.selectedID = rows[0].id
        // 既有勾选（范围外）不得丢失
        coordinator.selectionIDs.insert(rows[4].id)

        coordinator.insertRange(to: rows[2].id, rows: rows)

        XCTAssertEqual(coordinator.selectionIDs, Set([rows[0].id, rows[1].id, rows[2].id, rows[4].id]),
                       "范围含首尾（锚点行与目标行），且保留范围外既有勾选")
        XCTAssertEqual(coordinator.selectedID, rows[0].id, "锚点不移动（连续 ⇧ 点击可反复调整范围）")
    }

    /// 过滤联动：选中项不在新结果中回落首行；仍在则保持
    func testSyncWithFilterFallsBackToFirstRow() {
        let coordinator = MainViewListState(store: makeStore())
        let rows = makeRows(["a", "b", "c"])
        let all = makeRows(["x", "y"])

        coordinator.selectedID = rows[1].id
        coordinator.syncWithFilter(rows: all)
        XCTAssertEqual(coordinator.selectedID, all.first?.id, "选中项不在结果中回落首行")

        coordinator.selectedID = all[1].id
        coordinator.syncWithFilter(rows: all)
        XCTAssertEqual(coordinator.selectedID, all[1].id, "选中项仍在结果中保持不变")
    }

    /// 删除后选中补位项（原位置下一条）：置 nil 会在刷新后回落首行，
    /// 深处连续删除时每次跳回顶部
    func testSuccessorIDAfterDelete() {
        let coordinator = MainViewListState(store: makeStore())
        let rows = makeRows(["r0", "r1", "r2", "r3", "r4"])

        // 中间删除：落到原位置的下一条，连续删除不离开原位
        XCTAssertEqual(coordinator.successorID(afterDeleting: [rows[2].id], rows: rows), rows[3].id)

        // 删除末行：落到新的最后一条
        XCTAssertEqual(coordinator.successorID(afterDeleting: [rows[4].id], rows: rows), rows[3].id)

        // 批量删除中间段：最大被删索引的下一条
        XCTAssertEqual(coordinator.successorID(afterDeleting: [rows[1].id, rows[2].id], rows: rows), rows[3].id)

        // 批量删到列表末尾：最小被删索引的上一条
        XCTAssertEqual(coordinator.successorID(afterDeleting: [rows[3].id, rows[4].id], rows: rows), rows[2].id)

        // 删空列表 / 待删 id 不在当前行集（如过滤后）
        XCTAssertNil(coordinator.successorID(afterDeleting: Set(rows.map(\.id)), rows: rows))
        XCTAssertNil(coordinator.successorID(afterDeleting: [UUID()], rows: rows))
    }

    // MARK: - 菜单状态机（Esc 优先级的状态侧）

    /// Esc 语义的状态侧：菜单开合优先于筛选清空——菜单关闭不清筛选，
    /// 筛选清空（resetTimeAnchor）才复位时间锚点并触发滚动钩子
    func testMenuClosePrecedesFilterReset() {
        let filterState = MainViewFilterState()
        var resetHookFired = 0
        filterState.onTimeAnchorReset = { resetHookFired += 1 }

        // 打开分类菜单并锚定时间组
        filterState.toggleCategoryMenu(initialHighlight: 3)
        filterState.timeSelection = "今天"
        XCTAssertTrue(filterState.isAnyMenuOpen, "菜单打开")
        XCTAssertTrue(filterState.categoryMenuOpen)
        XCTAssertEqual(filterState.categoryMenuHighlight, 3)

        // 第一次 Esc（等价）：仅关菜单，筛选保留
        filterState.closeMenus()
        XCTAssertFalse(filterState.isAnyMenuOpen)
        XCTAssertNil(filterState.categoryMenuHighlight)
        XCTAssertEqual(filterState.timeSelection, "今天", "关菜单不清时间定位")
        XCTAssertEqual(resetHookFired, 0, "关菜单不触发滚动复位")

        // 第二次 Esc（等价）：清筛选 → 时间锚点复位 + 滚动钩子
        filterState.resetTimeAnchor()
        XCTAssertNil(filterState.timeSelection)
        XCTAssertEqual(resetHookFired, 1, "清筛选触发滚动复位钩子")
    }

    /// 锚点条连续定位：经过即锚定并触发滚动钩子；重复经过同一组是无操作
    /// （拖动扫过不反复触发）；「全部」= 复位回顶部（无锚点时不再触发复位钩子）
    func testRailScrubAnchorsAndResets() {
        let filterState = MainViewFilterState()
        var scrollHookFired = 0
        var resetHookFired = 0
        var scrolledTo: String?
        filterState.onSelectTimeGroup = { id in
            scrollHookFired += 1
            scrolledTo = id
        }
        filterState.onTimeAnchorReset = { resetHookFired += 1 }

        // 经过「今天」：锚定 + 滚动
        filterState.railScrub(to: "today")
        XCTAssertEqual(filterState.timeSelection, "today")
        XCTAssertEqual(scrollHookFired, 1)
        XCTAssertEqual(scrolledTo, "today")

        // 再按「今天」（拖动停在同一组）：无操作，不重复滚动
        filterState.railScrub(to: "today")
        XCTAssertEqual(filterState.timeSelection, "today")
        XCTAssertEqual(scrollHookFired, 1, "重复锚定同组不触发滚动")

        // 拖到「上周」：锚点切换
        filterState.railScrub(to: "last-week")
        XCTAssertEqual(filterState.timeSelection, "last-week")
        XCTAssertEqual(scrolledTo, "last-week")

        // 「全部」：复位锚点 + 滚回顶部
        filterState.railScrub(to: MainViewFilterState.timeAllOptionID)
        XCTAssertNil(filterState.timeSelection)
        XCTAssertEqual(resetHookFired, 1)

        // 已在「全部」再按「全部」：不再触发复位
        filterState.railScrub(to: MainViewFilterState.timeAllOptionID)
        XCTAssertEqual(resetHookFired, 1, "无锚点时按「全部」不再触发复位")
    }

    // MARK: - Esc 键分层清空状态机（MainView+Keyboard.swift:61-92）

    func testEscapeKeyHierarchicalClearingStateMachine() {
        struct MockMainViewState {
            var categoryMenuOpen: Bool = false
            var selectionIDs: Set<UUID> = []
            var searchText: String = ""
            var categorySelection: Int = 0
            var timeSelection: String? = nil
            var isClosed: Bool = false

            mutating func handleEscape() {
                if categoryMenuOpen {
                    categoryMenuOpen = false
                    return
                }
                if !selectionIDs.isEmpty {
                    selectionIDs.removeAll()
                    return
                }
                if !searchText.isEmpty {
                    searchText = ""
                    return
                }
                if categorySelection != 0 {
                    categorySelection = 0
                    timeSelection = nil
                    return
                }
                if timeSelection != nil {
                    timeSelection = nil
                    return
                }
                isClosed = true
            }
        }

        var state = MockMainViewState(
            categoryMenuOpen: true,
            selectionIDs: [UUID()],
            searchText: "query",
            categorySelection: 2,
            timeSelection: "today"
        )

        // 1. 先关下拉菜单
        state.handleEscape()
        XCTAssertFalse(state.categoryMenuOpen)
        XCTAssertFalse(state.selectionIDs.isEmpty)

        // 2. 清除批量多选
        state.handleEscape()
        XCTAssertTrue(state.selectionIDs.isEmpty)
        XCTAssertEqual(state.searchText, "query")

        // 3. 清空搜索词
        state.handleEscape()
        XCTAssertEqual(state.searchText, "")
        XCTAssertEqual(state.categorySelection, 2)

        // 4. 复位分类至全部 (0) 且清空时间锚点
        state.handleEscape()
        XCTAssertEqual(state.categorySelection, 0)
        XCTAssertNil(state.timeSelection)
        XCTAssertFalse(state.isClosed)

        // 5. 全部清空后触发关闭面板
        state.handleEscape()
        XCTAssertTrue(state.isClosed)
    }

    // MARK: - 时间导航全量分组（pageSize 100 回归）

    /// 分页列表只加载前 100 条时，时间导航锚点条仍须展示全部时间分组，
    /// 且能算出把未加载组拉进前缀所需的行数（扩页定位）
    func testTimeGroupsCoverOlderGroupsBeyondPageWindow() async {
        let store = makeIsolatedStore()
        store.clearHistory(keepFavorites: false)
        // 100 条今天 + 3 条去年：分页只装下今天
        let calendar = Calendar(identifier: .gregorian)
        let lastYear = calendar.date(from: DateComponents(year: 2025, month: 1, day: 15, hour: 9))!
        for i in 0..<100 {
            store.save(ClipboardItem(type: .text, title: "今天\(i)", summary: "今天\(i)"))
        }
        for i in 0..<3 {
            store.save(ClipboardItem(
                type: .text, title: "去年\(i)", summary: "去年\(i)",
                createdAt: lastYear, lastUsedAt: lastYear
            ))
        }

        let coordinator = MainViewListState(store: store)
        coordinator.refresh(dataVersion: store.dataVersion)
        for _ in 0..<50 where coordinator.timeGroups.isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertFalse(coordinator.groups.contains { $0.id == "year-2025" },
                       "前置：分页前缀内没有去年组")
        XCTAssertTrue(coordinator.timeGroups.contains { $0.id == "year-2025" && $0.count == 3 },
                      "全量分组须含分页窗口外的去年组（时间导航未展示全部的回归）")
        XCTAssertEqual(coordinator.rowLimitCoveringGroup("year-2025"), 103,
                       "拉入去年组组头需要覆盖其前所有分组 + 该组首条")
        XCTAssertNil(coordinator.rowLimitCoveringGroup("no-such-group"),
                     "未知分组无扩页行数")
    }
}
