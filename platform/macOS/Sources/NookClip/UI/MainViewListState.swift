import SwiftUI

/// 通用列表选区与键盘导航状态机（与具体业务模型解耦，仅依赖 `Identifiable`）：
/// 封装单选 (`selectedID`)、批量多选 (`selectionIDs`)、↑↓ 步进、⇧ 范围扩展、
/// 点击修饰符消歧以及「结果刷新后选中项若不在当前列表则自愈回落首行」的不变量。
/// 剪贴板及未来的笔记/待办列表均可直接组合复用。
struct ListSelectionState<Row: Identifiable> where Row.ID: Hashable {
    var selectedID: Row.ID?
    var selectionIDs: Set<Row.ID> = []

    var isBatchMode: Bool { !selectionIDs.isEmpty }

    func selectedRow(in rows: [Row]) -> Row? {
        guard let selectedID else { return nil }
        return rows.first { $0.id == selectedID }
    }

    /// 核心不变量自愈：确保 `selectedID` 恒在 `rows` 中，否则回落首行
    mutating func syncWithFilter(rows: [Row]) {
        guard let current = selectedID else {
            selectedID = rows.first?.id
            return
        }
        if !rows.contains(where: { $0.id == current }) {
            selectedID = rows.first?.id
        }
    }

    mutating func move(offset: Int, rows: [Row]) {
        guard !rows.isEmpty else { return }
        let index = selectedID.flatMap { id in rows.firstIndex(where: { $0.id == id }) } ?? -1
        let next = min(max(index + offset, 0), rows.count - 1)
        selectedID = rows[next].id
    }

    mutating func extend(offset: Int, rows: [Row]) {
        guard !rows.isEmpty else { return }
        let index = selectedID.flatMap { id in rows.firstIndex(where: { $0.id == id }) } ?? 0
        let next = min(max(index + offset, 0), rows.count - 1)
        let target = rows[next].id
        if selectionIDs.isEmpty, let anchor = selectedID {
            selectionIDs.insert(anchor)
        }
        selectedID = target
        selectionIDs.insert(target)
    }

    mutating func insertRange(to targetID: Row.ID, rows: [Row]) {
        guard let to = rows.firstIndex(where: { $0.id == targetID }) else { return }
        let from = selectedID.flatMap { id in rows.firstIndex(where: { $0.id == id }) } ?? to
        let range = min(from, to)...max(from, to)
        for idx in range {
            selectionIDs.insert(rows[idx].id)
        }
    }

    mutating func handleTap(_ item: Row, rows: [Row], shiftHeld: Bool, commandHeld: Bool) {
        if shiftHeld, !commandHeld {
            insertRange(to: item.id, rows: rows)
        } else if isBatchMode || commandHeld {
            if selectionIDs.contains(item.id) {
                selectionIDs.remove(item.id)
            } else {
                selectionIDs.insert(item.id)
            }
            selectedID = item.id
        } else {
            selectedID = item.id
        }
    }

    func successorID(afterDeleting ids: Set<Row.ID>, rows: [Row]) -> Row.ID? {
        let indices = ids.compactMap { id in rows.firstIndex(where: { $0.id == id }) }
        guard let maxIndex = indices.max() else { return nil }
        if maxIndex + 1 < rows.count { return rows[maxIndex + 1].id }
        if let minIndex = indices.min(), minIndex > 0 { return rows[minIndex - 1].id }
        return nil
    }

    mutating func clearBatch() {
        selectionIDs.removeAll()
    }
}

@MainActor
final class RowMapCache {
    private(set) var version = 0
    private var cachedItems: [ClipboardItem] = []
    private var cachedRows: [ClipboardRowModel] = []
    private var cachedLanguage: String?

    func rows(for items: [ClipboardItem], language: String) -> [ClipboardRowModel] {
        if items == cachedItems, language == cachedLanguage { return cachedRows }
        let rows = ClipboardRowModel.map(items)
        cachedItems = items
        cachedRows = rows
        cachedLanguage = language
        version &+= 1
        return rows
    }
}

@MainActor
final class MainViewPipelineModel {
    struct Output {
        var categories: [SidebarCategory] = []
        var effectiveCategory = 0
        var filtered: [ClipboardRowModel] = []
        var groups: [TimeGroup<ClipboardRowModel>] = []
        var flatRows: [ClipboardRowModel] = []
    }

    private struct Input: Equatable {
        var queryVersion: Int
        var dataVersion: Int
        var searchText: String
        var category: Int
        var language: String
        var counts: CategoryCounts
    }

    private var lastInput: Input?
    private var output = Output()

    func update(
        queryRows: [ClipboardRowModel],
        queryVersion: Int,
        counts: CategoryCounts,
        dataVersion: Int,
        searchText: String,
        categorySelection: Int
    ) -> Output {
        let input = Input(
            queryVersion: queryVersion,
            dataVersion: dataVersion,
            searchText: searchText,
            category: categorySelection,
            language: LocalizationManager.shared.effectiveLanguageCode,
            counts: counts
        )
        if input == lastInput { return output }

        let categories = SidebarCategories.categories(from: counts)
        let effective = categories.first(where: { $0.id == categorySelection })?.id ?? 0
        let filtered = queryRows.filter { SidebarCategories.matchesCategory(effective, $0) }
        let grouped = Timeline.group(filtered)

        output = Output(
            categories: categories,
            effectiveCategory: effective,
            filtered: filtered,
            groups: grouped,
            flatRows: grouped.flatMap(\.items)
        )
        lastInput = input
        return output
    }
}

/// 统一列表状态深模块（MainViewListState）：
/// 集中封装查询分发、代际守卫、分类管线缓存与选择状态机。
/// 保证「选中项恒在当前结果中（否则自愈回落首行）」这一核心不变量在模块内部闭环，
/// 消除视图层的跨对象胶水接线。
@MainActor
@Observable
final class MainViewListState {
    init(store: InMemoryHistoryStore) {
        self.store = store
    }

    var queryText: String { searchText }
    var hasSearchText: Bool { !searchText.isEmpty }
    var activeSearchKeywords: [String]? {
        guard hasSearchText else { return nil }
        let keywords = tokenizeSearchKeywords(query: searchText).filter { !$0.isEmpty }
        return keywords.isEmpty ? nil : keywords
    }
    private let store: InMemoryHistoryStore
    let rowCache = RowMapCache()
    private let pipeline = MainViewPipelineModel()
    var onResultsApplied: (() -> Void)?

    private(set) var searchText = ""
    private(set) var categorySelection = 0

    private(set) var results: [ClipboardItem] = []
    private(set) var categoryCounts = CategoryCounts(total: 0, favorite: 0, text: 0, image: 0, file: 0, url: 0, code: 0, color: 0, sensitive: 0)
    private(set) var hasMore = false
    private(set) var failed = false
    private var generation = 0
    private var task: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var dataVersion = 0
    private var lastRowsKey: (text: String, category: Int, limit: Int, dataVersion: Int)?
    private var lastCountsKey: (text: String, dataVersion: Int)?
    private var lastPipelineInput: (text: String, category: Int, dataVersion: Int)?
    private var lastRailKey: (text: String, category: Int, dataVersion: Int)?
    private var railTimestamps: [Date] = []

    // MARK: - 过滤管线输出
    private(set) var categories: [SidebarCategory] = []
    private(set) var effectiveCategory = 0
    private(set) var groups: [TimeGroup<ClipboardRowModel>] = []
    /// 全量时间分组摘要（时间导航锚点条数据源）：来自 Rust 全量时间戳聚合，
    /// 不受分页前缀截断——锚点条始终展示当前筛选下的全部时间分组
    private(set) var timeGroups: [Timeline.TimeGroupSummary] = []
    private(set) var flatRows: [ClipboardRowModel] = []

    // MARK: - 应用检索与选中状态
    var matchedApps: [InstalledApp] = []
    var selectedAppID: String? {
        didSet {
            if selectedAppID != nil {
                selection.selectedID = nil
                selection.selectionIDs.removeAll()
            }
        }
    }
    func updateMatchedApps(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // 仅在「全部」分类（categorySelection == 0）下搜索时匹配本地已安装应用；
        // 切换到具体剪贴板分类（文本/图片/链接等）时只展示对应类型的剪贴板记录
        if trimmed.isEmpty || categorySelection != 0 {
            matchedApps = []
            selectedAppID = nil
        } else {
            matchedApps = AppSearchService.shared.search(query: trimmed, limit: 3)
            if let first = matchedApps.first {
                selectedAppID = first.id
                selectedID = nil
            } else {
                selectedAppID = nil
            }
        }
    }

    func handleAppNavigation(offset: Int) -> Bool {
        guard !matchedApps.isEmpty else { return false }

        if let currentAppID = selectedAppID,
           let currentIndex = matchedApps.firstIndex(where: { $0.id == currentAppID }) {
            let nextIndex = currentIndex + offset
            if nextIndex >= 0 && nextIndex < matchedApps.count {
                selectedAppID = matchedApps[nextIndex].id
                return true
            } else if nextIndex >= matchedApps.count {
                if !flatRows.isEmpty {
                    selectedID = flatRows.first?.id
                }
                return true
            } else {
                return true
            }
        }

        if offset < 0 {
            let clipIndex = selectedID.flatMap { id in flatRows.firstIndex(where: { $0.id == id }) } ?? 0
            if clipIndex == 0 {
                selectedID = nil
                selectedAppID = matchedApps.last?.id
                return true
            }
        }
        return false
    }

    func clearApps() {
        matchedApps = []
        selectedAppID = nil
    }

    // MARK: - 选择状态（委托给通用 ListSelectionState）
    var selection = ListSelectionState<ClipboardRowModel>()

    var selectedID: UUID? {
        get { selection.selectedID }
        set {
            selection.selectedID = newValue
            if newValue != nil {
                selectedAppID = nil
            }
        }
    }

    var selectionIDs: Set<UUID> {
        get { selection.selectionIDs }
        set { selection.selectionIDs = newValue }
    }

    var isBatchMode: Bool { selection.isBatchMode }
    var isRunning: Bool { task != nil }

    var selectedRow: ClipboardRowModel? {
        selection.selectedRow(in: flatRows)
    }

    // MARK: - 查询驱动与管线计算

    func setSearchText(_ text: String, dataVersion: Int) {
        guard text != searchText else { return }
        searchText = text
        updateMatchedApps(query: text)
        scheduleQuery(dataVersion: dataVersion)
    }

    @discardableResult
    func setCategorySelection(_ categoryID: Int, dataVersion: Int) -> Bool {
        guard categoryID != categorySelection else { return false }
        categorySelection = categoryID
        selection.selectedID = nil
        updateMatchedApps(query: searchText)
        scheduleQuery(dataVersion: dataVersion, debounce: false)
        return true
    }

    func clearFilters(dataVersion: Int) {
        debounceTask?.cancel()
        searchText = ""
        categorySelection = 0
        clearApps()
        selection.selectionIDs.removeAll()
        scheduleQuery(dataVersion: dataVersion, debounce: false)
    }

    func refresh(dataVersion: Int, limit: Int? = nil) {
        self.dataVersion = dataVersion
        run(limit: limit)
    }

    private func scheduleQuery(dataVersion: Int, debounce: Bool = true) {
        self.dataVersion = dataVersion
        debounceTask?.cancel()
        guard debounce else {
            run()
            return
        }
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self.debounceTask = nil
            self.run()
        }
    }

    private func run(limit: Int? = nil) {
        let queryText = searchText
        let categoryID = categorySelection
        let dataVersion = self.dataVersion
        let effectiveLimit = limit ?? InMemoryHistoryStore.pageSize
        let rowsKey = (text: queryText, category: categoryID, limit: effectiveLimit, dataVersion: dataVersion)
        let countsKey = (text: queryText, dataVersion: dataVersion)
        let railKey = (text: queryText, category: categoryID, dataVersion: dataVersion)

        let rowsNeeded = lastRowsKey.map { $0 != rowsKey } ?? true
        let countsNeeded = lastCountsKey.map { $0 != countsKey } ?? true
        let railNeeded = lastRailKey.map { $0 != railKey } ?? true
        guard rowsNeeded || countsNeeded || railNeeded else { return }

        generation += 1
        let currentGeneration = generation
        task?.cancel()
        task = Task { @MainActor in
            var newResults = results
            var newHasMore = hasMore
            var newFailed = failed
            if rowsNeeded {
                let outcome = await store.searchHistory(queryText: queryText, categoryID: categoryID, limit: effectiveLimit)
                guard !Task.isCancelled, currentGeneration == generation else { return }
                newResults = outcome.items
                newHasMore = outcome.hasMore
                newFailed = outcome.failed
            }

            var newCounts = categoryCounts
            if countsNeeded {
                newCounts = await store.countCategories(queryText: queryText)
                guard !Task.isCancelled, currentGeneration == generation else { return }
            }
            if railNeeded {
                let timestamps = await store.timeGroupTimestamps(queryText: queryText, categoryID: categoryID)
                guard !Task.isCancelled, currentGeneration == generation else { return }
                railTimestamps = timestamps
                lastRailKey = railKey
            }
            self.failed = newFailed
            self.results = newResults
            self.hasMore = newHasMore
            self.categoryCounts = newCounts
            self.lastRowsKey = rowsKey
            self.lastCountsKey = countsKey
            self.task = nil

            applyPipeline(searchText: queryText, categorySelection: categoryID, dataVersion: dataVersion)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// 应用过滤管线并自愈选中态
    private func applyPipeline(searchText: String, categorySelection: Int, dataVersion: Int) {
        lastPipelineInput = (text: searchText, category: categorySelection, dataVersion: dataVersion)
        let out = pipeline.update(
            queryRows: rowCache.rows(for: results, language: LocalizationManager.shared.effectiveLanguageCode),
            queryVersion: rowCache.version,
            counts: categoryCounts,
            dataVersion: dataVersion,
            searchText: searchText,
            categorySelection: categorySelection
        )
        self.categories = out.categories
        self.effectiveCategory = out.effectiveCategory
        self.groups = out.groups
        // 全量时间分组跟随语言重算（标题本地化在 Timeline 内完成）
        self.timeGroups = Timeline.groupTimestamps(railTimestamps)
        self.flatRows = out.flatRows
        if self.categorySelection != out.effectiveCategory {
            self.categorySelection = out.effectiveCategory
            selection.selectedID = nil
        }

        // 核心不变量：选中项必须属于当前可见 flatRows
        syncSelectionWithFilter()
        onResultsApplied?()
    }

    /// 运行时语言切换后重算管线输出（分类名在管线内本地化；
    /// 计数/过滤结果不变，仅刷新名称与选中态）
    func refreshLocalizedOutput() {
        let last = lastPipelineInput ?? (text: "", category: 0, dataVersion: 0)
        applyPipeline(searchText: last.text, categorySelection: last.category, dataVersion: last.dataVersion)
    }


    /// 把未加载的时间分组拉进结果前缀所需的最小行数：
    /// 目标组之前所有分组的条数之和 + 目标组自身条数
    ///（时间戳计数 ≥ 去重后行数，宁可多拉不遗漏）。未知分组返回 nil。
    func rowLimitCoveringGroup(_ groupID: String) -> Int? {
        guard let index = timeGroups.firstIndex(where: { $0.id == groupID }) else { return nil }
        return timeGroups[...index].reduce(0) { $0 + $1.count }
    }
    func syncSelectionWithFilter() {
        syncWithFilter(rows: flatRows)
    }

    func syncWithFilter(rows: [ClipboardRowModel]) {
        guard selectedAppID == nil else { return }
        let activeRows = rows.isEmpty ? flatRows : rows
        selection.syncWithFilter(rows: activeRows)
    }

    // MARK: - 选择导航操作（支持无参调用，也兼容传递 rows）

    func move(offset: Int) {
        move(offset: offset, rows: flatRows)
    }

    func move(offset: Int, rows: [ClipboardRowModel]) {
        selectedAppID = nil
        let activeRows = rows.isEmpty ? flatRows : rows
        selection.move(offset: offset, rows: activeRows)
    }

    func extend(offset: Int) {
        extend(offset: offset, rows: flatRows)
    }

    func extend(offset: Int, rows: [ClipboardRowModel]) {
        selectedAppID = nil
        let activeRows = rows.isEmpty ? flatRows : rows
        selection.extend(offset: offset, rows: activeRows)
    }

    func insertRange(to targetID: UUID) {
        insertRange(to: targetID, rows: flatRows)
    }

    func insertRange(to targetID: UUID, rows: [ClipboardRowModel]) {
        let activeRows = rows.isEmpty ? flatRows : rows
        selection.insertRange(to: targetID, rows: activeRows)
    }

    func handleTap(_ item: ClipboardRowModel, shiftHeld: Bool, commandHeld: Bool) {
        handleTap(item, rows: flatRows, shiftHeld: shiftHeld, commandHeld: commandHeld)
    }

    func handleTap(_ item: ClipboardRowModel, rows: [ClipboardRowModel], shiftHeld: Bool, commandHeld: Bool) {
        selectedAppID = nil
        let activeRows = rows.isEmpty ? flatRows : rows
        selection.handleTap(item, rows: activeRows, shiftHeld: shiftHeld, commandHeld: commandHeld)
    }

    func successorID(afterDeleting ids: Set<UUID>) -> UUID? {
        successorID(afterDeleting: ids, rows: flatRows)
    }

    func successorID(afterDeleting ids: Set<UUID>, rows: [ClipboardRowModel]) -> UUID? {
        let activeRows = rows.isEmpty ? flatRows : rows
        return selection.successorID(afterDeleting: ids, rows: activeRows)
    }

    func clearBatch() {
        selection.clearBatch()
    }
}
