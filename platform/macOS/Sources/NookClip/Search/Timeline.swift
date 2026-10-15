import Foundation

// MARK: - 渐进式动态多级时间线分组
// 今天 / 昨天 / 本周 / 上周 / 按月归档 / 按年归档 · 空组自动隐藏

/// 可分组条目（持久化模型 ClipboardItem 与展示模型 ClipboardRowModel 均符合）
protocol TimelineItem: Identifiable {
    var lastUsedAt: Date { get }
    var title: String { get }
    var summary: String { get }
}

extension ClipboardItem: TimelineItem {}
extension ClipboardRowModel: TimelineItem {}

struct TimeGroup<Item: TimelineItem>: Identifiable {
    let id: String
    let title: String
    let items: [Item]
}
enum Timeline {

    /// 分组规则（周界跟随系统区域设置，可用 calendar 参数注入测试夹具）：
    /// ① 今天 ② 昨天 ③ 本周（与 now 同周，排除今天/昨天）④ 上周（前一自然周）
    /// 组内排序：按 lastUsedAt 降序（收藏只豁免清理，不影响排序）
    /// 分组键 = lastUsedAt（重复复制会刷新 lastUsedAt 并置顶，
    /// 与列表排序/保留期清理/iCloud 合并的 recency 权威字段一致）
    /// 全部层级（含今天/昨天）均相对注入的 now 判定，保证 now 契约完整
    static func group<Item: TimelineItem>(
        _ items: [Item],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [TimeGroup<Item>] {
        var todayItems: [Item] = []
        var yesterdayItems: [Item] = []
        var thisWeekItems: [Item] = []
        var lastWeekItems: [Item] = []
        var monthBuckets: [Int: [Item]] = [:]
        var yearBuckets: [Int: [Item]] = [:]

        let lastWeekRef = calendar.date(byAdding: .weekOfYear, value: -1, to: now) ?? now
        let yesterdayRef = calendar.date(byAdding: .day, value: -1, to: now) ?? now

        for item in items {
            let date = item.lastUsedAt
            if calendar.isDate(date, equalTo: now, toGranularity: .day) {
                todayItems.append(item)
            } else if calendar.isDate(date, equalTo: yesterdayRef, toGranularity: .day) {
                yesterdayItems.append(item)
            } else if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
                thisWeekItems.append(item)
            } else if calendar.isDate(date, equalTo: lastWeekRef, toGranularity: .weekOfYear) {
                lastWeekItems.append(item)
            } else {
                let year = calendar.component(.year, from: date)
                if year == calendar.component(.year, from: now) {
                    let month = calendar.component(.month, from: date)
                    monthBuckets[month, default: []].append(item)
                } else {
                    yearBuckets[year, default: []].append(item)
                }
            }
        }

        var groups: [TimeGroup<Item>] = []
        func make(_ title: String, _ id: String, _ items: [Item]) {
            guard !items.isEmpty else { return } // 渐进式：空组不产生
            groups.append(TimeGroup(id: id, title: title, items: sorted(items)))
        }
        make(L10n.tr("timeline.today"), "today", todayItems)
        make(L10n.tr("timeline.yesterday"), "yesterday", yesterdayItems)
        make(L10n.tr("timeline.this_week"), "this-week", thisWeekItems)
        make(L10n.tr("timeline.last_week"), "last-week", lastWeekItems)
        for month in monthBuckets.keys.sorted(by: >) {
            make(monthTitle(month), "month-\(month)", monthBuckets[month] ?? [])
        }
        for year in yearBuckets.keys.sorted(by: >) {
            make(L10n.tr("timeline.year", String(year)), "year-\(year)", yearBuckets[year] ?? [])
        }
        return groups
    }

    /// 时间分组摘要（全量时间戳分组输出）：id/标题/计数，
    /// 供时间导航锚点条在分页列表之外展示全部时间分组
    struct TimeGroupSummary: Equatable {
        let id: String
        let title: String
        let count: Int
    }

    /// 全量时间戳分组：Rust 聚合的全部命中条目 last_used_at → 时间分组摘要。
    /// 与分页列表无关——分组规则、标题、排序和 `group` 完全一致（复用同一实现），
    /// 解决 pageSize 截断导致锚点条缺失更早分组（上周/月份/年份）的问题。
    static func groupTimestamps(
        _ timestamps: [Date],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [TimeGroupSummary] {
        struct TimestampProbe: TimelineItem, Identifiable {
            let id: String
            let lastUsedAt: Date
            var title: String { "" }
            var summary: String { "" }
        }
        let probes = timestamps.enumerated().map { index, date in
            TimestampProbe(id: "ts-\(index)", lastUsedAt: date)
        }
        return group(probes, now: now, calendar: calendar).map { group in
            TimeGroupSummary(id: group.id, title: group.title, count: group.items.count)
        }
    }

    /// 月归档标题：跟随当前生效语言（zh「8月」/ en「Aug」）
    private static func monthTitle(_ month: Int) -> String {
        let locale = LocalizationManager.shared.locale
        // Formatter 静态缓存（FR-010）：按 locale.identifier 作 key，语言切换自动失效
        let formatter: DateFormatter
        if let cached = monthFormatterCache[locale.identifier] {
            formatter = cached
        } else {
            let f = DateFormatter()
            f.locale = locale
            f.dateFormat = "MMM"
            monthFormatterCache[locale.identifier] = f
            formatter = f
        }
        var components = DateComponents()
        components.year = 2020
        components.month = month
        let date = Calendar.current.date(from: components) ?? Date()
        return formatter.string(from: date)
    }

    private static var monthFormatterCache: [String: DateFormatter] = [:]

    private static func sorted<Item: TimelineItem>(_ items: [Item]) -> [Item] {
        items.sorted { $0.lastUsedAt > $1.lastUsedAt }
    }
}
