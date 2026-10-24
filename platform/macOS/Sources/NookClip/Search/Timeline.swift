import Foundation

// MARK: - 渐进式动态多级时间线分组
// 今天 / 昨天 / 本周（7 天内）· 之后按月归档 / 按年归档 · 空组自动隐藏

/// 时间分档阈值——与 Rust 端 `TimeGroupLevel::SPAN_JUSTIFIED_DAYS` 必须同值。
/// 只在一处定义，分组与测试都引用它，避免两处数字漂移。
enum TimeGroupSpan {
    /// 仍然用「今天/昨天/本周」这套相对标签解释的最大自然日差（含）
    static let justifiedDays = 7
}

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
    public static func localizedTitle(for bucket: TimeBucketKey) -> String {
        switch bucket {
        case .today:
            return L10n.tr("timeline.today")
        case .yesterday:
            return L10n.tr("timeline.yesterday")
        case .thisWeek:
            return L10n.tr("timeline.this_week")
        case .lastWeek:
            // 已退役档位：分组逻辑不再产出它（距今 > 7 天直接进月档）。
            // 仅防御性保留：若旧快照/历史数据仍带该键，退回该档曾用的文案。
            return L10n.tr("timeline.last_week")
        case .month(let year, let month, let lastDay):
            return monthTitle(Int(month), year: Int(year), lastDay: Int(lastDay))
        case .year(let year):
            return L10n.tr("timeline.year", String(year))
        }
    }

    /// 分组规则（分档按「自然日差」，与 Rust 端 `bucket_of` 完全一致）：
    /// ① 今天 ② 昨天 ③ 近档（距今 2–7 天）④ 月档（同年更早）⑤ 年档（跨年）
    ///
    /// 「上周」档已退役：若保留，菜单会变成「今天 / 昨天 / 本周 / 上周 / 本月」——
    /// `上周` 是唯一按周切的档位（夹在按天与按月之间），而 `本月` 又包含 `上周`，
    /// 两个标签语义互相嵌套。去掉后只剩两种粒度：7 天内按天，7 天外按月。
    /// 也正因为不按周界切，本实现不读 `firstWeekday`。请勿改回 `weekOfYear`。
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
        var monthBuckets: [Int: [Item]] = [:]
        var yearBuckets: [Int: [Item]] = [:]

        // 自然日差基准：今天 00:00。分档只看「差几个自然日」，
        // 不依赖 firstWeekday / 周界（与 Rust 端 bucket_of 同源）
        let todayStart = calendar.startOfDay(for: now)
        let spanWindowStart = calendar.date(
            byAdding: .day, value: -TimeGroupSpan.justifiedDays, to: todayStart
        ) ?? todayStart

        let currentYear = calendar.component(.year, from: now)

        for item in items {
            let date = item.lastUsedAt
            if date >= todayStart || calendar.isDate(date, equalTo: now, toGranularity: .day) {
                todayItems.append(item)
            } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: todayStart),
                      calendar.isDate(date, inSameDayAs: yesterday) {
                yesterdayItems.append(item)
            } else if date >= spanWindowStart {
                // 距今 2–7 天：仍用「本周」标签（"7 天内"对用户即"本周"）
                thisWeekItems.append(item)
            } else {
                let year = calendar.component(.year, from: date)
                if year == currentYear {
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
        for month in monthBuckets.keys.sorted(by: >) {
            // 当月桶只覆盖到「今天 - 近档窗口」，标题要带上这段范围
            let lastDay = monthBucketLastDay(month: month, today: todayStart, calendar: calendar)
            make(
                monthTitle(month, year: currentYear, lastDay: lastDay, calendar: calendar),
                "month-\(month)",
                monthBuckets[month] ?? []
            )
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
    /// 解决 pageSize 截断导致锚点条缺失更早分组（月份/年份）的问题。
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

    /// 当月桶实际覆盖到的最后一天——与 Rust `month_bucket_last_day` 同算法：
    /// 历史月份返回该月天数；当月返回「今天 - (窗口+1)」的日号，月初为 0（该桶不产生）。
    static func monthBucketLastDay(month: Int, today: Date, calendar: Calendar) -> Int {
        let currentYear = calendar.component(.year, from: today)
        let currentMonth = calendar.component(.month, from: today)
        guard month == currentMonth else {
            return daysIn(month: month, year: currentYear, calendar: calendar)
        }
        guard let cutoff = calendar.date(
            byAdding: .day, value: -(TimeGroupSpan.justifiedDays + 1), to: today
        ), calendar.component(.month, from: cutoff) == month,
           calendar.component(.year, from: cutoff) == currentYear else { return 0 }
        return calendar.component(.day, from: cutoff)
    }

    /// 月归档标题：跟随当前生效语言（zh「8月」/ en「Aug」）。
    ///
    /// `lastDay` 是该桶实际覆盖到的最后一天。当月桶只装「近档窗口之外」的条目
    /// （今天是 10/23、窗口 7 天 → 本月桶是 10/1–10/15），所以标签必须带上范围，
    /// 否则「10月 · 15」会被读成「10 月一共只有 15 条」，而它只覆盖到 15 日。
    /// 完整的月份（历史月份，`lastDay == 该月总天数`）不带范围，仍显示「9月」。
    static func monthTitle(
        _ month: Int,
        year: Int? = nil,
        lastDay: Int,
        calendar: Calendar = .current
    ) -> String {
        let name = monthName(month)
        let effectiveYear = year ?? calendar.component(.year, from: Date())
        let totalDays = daysIn(month: month, year: effectiveYear, calendar: calendar)

        // 历史月份（lastDay == 该月天数）或无效范围 → 覆盖整月，不带范围
        guard lastDay > 0, lastDay < totalDays else { return name }

        if lastDay == 1 {
            return L10n.tr("timeline.month_range_same_day", name, lastDay)
        }
        return L10n.tr("timeline.month_range", name, 1, lastDay)
    }

    private static func daysIn(month: Int, year: Int, calendar: Calendar = .current) -> Int {
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let range = calendar.range(of: .day, in: .month, for: date) else { return 31 }
        return range.count
    }

    /// 月份名（zh「8月」/ en「Aug」），不含范围
    private static func monthName(_ month: Int) -> String {
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
