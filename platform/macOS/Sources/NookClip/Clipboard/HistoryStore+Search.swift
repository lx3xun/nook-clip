import Foundation

// MARK: - 分页加载与全历史搜索（FTS5）
extension InMemoryHistoryStore {
    /// 翻页终止信号以「原始行是否还有剩余」为准（pageUnique）：SQL LIMIT 作用于
    /// 原始行，行内存在重复内容时去重后条数会小于页大小，旧判据
    /// `items.count >= pageSize` 会提前终止，剩余历史永远无法加载（审计 BUG-018）
    func refreshHasMore() {
        guard !items.isEmpty else {
            hasMoreItems = false
            return
        }
        let nextBatch = rustStore.page(limit: 1, offset: items.count)
        hasMoreItems = !nextBatch.isEmpty
    }

    /// 替换式增长：重查「前 items.count + pageSize 条」整体替换，而非 OFFSET 追加。
    /// 追加方案在中途新增/置顶（markUsed 等）时 offset 会漂移，导致跳条或滚动锚定跳动；
    /// 整体替换保证条目 id 集合与顺序始终与数据库一致（ForEach 按 id diff，不跳动）。
    /// 终止信号来自 pageUnique 的原始行判定；其保守性（最后一块拉满即认为可能还有）
    /// 由「条目数不再增长」兜底：剩余原始行全为重复内容时停止翻页，不会转圈。
    func loadMoreItems() {
        guard hasMoreItems, !loadingMore else { return }
        loadingMore = true
        let previousCount = items.count
        let requested = previousCount + Self.pageSize
        let newItems = rustStore.page(limit: requested, offset: 0)
        if !newItems.isEmpty { items = newItems }
        hasMoreItems = newItems.count > previousCount
        loadingMore = false
    }

    /// 搜索结果（全历史命中前缀 + 分页/失败状态）
    struct HistorySearchOutcome {
        /// 命中条目（last_used_at 倒序前缀；不含回收站）
        var items: [ClipboardItem] = []
        /// 已匹配前缀之外还有更多命中（替换式增长分页）
        var hasMore = false
        /// 查询失败（FTS 不可用或 SQL 错误）——不是空结果，界面须与「无匹配」区分
        var failed = false
    }

    /// 统一列表查询：覆盖所有未删除记录，不受内存首页条数限制。
    /// 空关键词 = 全历史列表（可选分类预筛）分页；有关键词时走 FTS5 trigram
    /// （≥3 Unicode 标量）+ 字面量 LIKE 回退（短词）；
    /// 自然时间区间与分类预筛在结果限制前应用；多个关键词保持 AND。
    /// nonisolated：FFI 查询在 RustHistoryStore 的串行队列执行（见 searchAsync），
    /// 主 actor 仅做发起与结果应用，过期结果由调用方代际守卫丢弃。
    nonisolated func searchHistory(queryText: String, categoryID: Int, limit: Int) async -> HistorySearchOutcome {
        let cleanQuery = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await rustStore.searchAsync(query: cleanQuery, categoryID: categoryID, limit: limit, offset: 0)
        return HistorySearchOutcome(items: result.items, hasMore: result.items.count >= limit, failed: result.failed)
    }

    /// 全历史分类统计：在 Rust 聚合出真实的 9 大分类条数，不拉取明细条目
    nonisolated func countCategories(queryText: String) async -> CategoryCounts {
        let cleanQuery = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        return await rustStore.countCategoriesAsync(query: cleanQuery)
    }

    /// 全量时间戳聚合：当前筛选（关键词 + 分类）下全部命中条目的 last_used_at，
    /// 供时间导航锚点条做全历史时间分组——不受分页 pageSize 截断
    nonisolated func timeGroupTimestamps(queryText: String, categoryID: Int) async -> [Date] {
        let cleanQuery = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        return await rustStore.timeGroupTimestampsAsync(query: cleanQuery, categoryID: categoryID)
    }
}
