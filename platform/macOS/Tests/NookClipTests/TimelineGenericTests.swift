import XCTest
@testable import NookClip

// T007：Timeline 分组与 NaturalTimeFilter 解析测试（specs/001-new-ui-cutover/research.md D9）

final class TimelineGenericTests: XCTestCase {

    private let calendar = Calendar(identifier: .gregorian)

    private func makeItem(
        title: String = "条目",
        daysAgo: Int,
        hoursAgo: Int = 0,
        isFavorite: Bool = false,
        now: Date
    ) -> ClipboardItem {
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
            .addingTimeInterval(-Double(hoursAgo) * 3600)
        return ClipboardItem(
            type: .text, title: title, summary: title,
            createdAt: date, lastUsedAt: date, isFavorite: isFavorite
        )
    }

    private func item(at date: Date, title: String) -> ClipboardItem {
        ClipboardItem(type: .text, title: title, summary: title, createdAt: date, lastUsedAt: date)
    }

    private var refNow: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 12))!
    }

    // MARK: 分组边界

    func testTodayYesterdayGroups() {
        let items = [
            makeItem(title: "今天项", daysAgo: 0, hoursAgo: 1, now: refNow),
            makeItem(title: "昨天项", daysAgo: 1, now: refNow),
        ]
        let groups = Timeline.group(items, now: refNow, calendar: calendar)
        XCTAssertEqual(groups.map(\.title), ["今天", "昨天"])
        XCTAssertEqual(groups.first?.items.first?.title, "今天项")
    }

    /// 分档按「自然日差」而非周界：2–7 天前都进「本周」档
    func testSpanWindowFoldsIntoThisWeek() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 12))!
        let items = [
            makeItem(title: "两天前", daysAgo: 2, now: now),
            makeItem(title: "六天前", daysAgo: 6, now: now),
        ]
        let groups = Timeline.group(items, now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.title), ["本周"])
        XCTAssertEqual(groups.first?.items.count, 2, "2 天前与 6 天前同属「本周」档")
    }

    func testJustifiedDaysBoundary() {
        // 阈值本身必须被钉住：第 7 天仍是「本周」，第 8 天进月档
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 12))!
        let atEdge = makeItem(title: "七天前", daysAgo: TimeGroupSpan.justifiedDays, now: now)
        let beyond = makeItem(title: "八天前", daysAgo: TimeGroupSpan.justifiedDays + 1, now: now)

        let edgeGroups = Timeline.group([atEdge], now: now, calendar: calendar)
        XCTAssertEqual(edgeGroups.map(\.title), ["本周"])

        let beyondGroups = Timeline.group([beyond], now: now, calendar: calendar)
        XCTAssertEqual(beyondGroups.map(\.title), ["9月 1–15日"], "第 8 天应直接进当月档（带范围）")
    }

    /// 回归：「上周」档已退役，分组中不得再出现该标题
    func testLastWeekBucketIsRetired() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 12))!
        let items = [
            makeItem(title: "今天项", daysAgo: 0, now: now),
            makeItem(title: "昨天项", daysAgo: 1, now: now),
            makeItem(title: "上周项", daysAgo: 9, now: now),
        ]
        let titles = Timeline.group(items, now: now, calendar: calendar).map(\.title)
        XCTAssertFalse(titles.contains("上周"), "实际分组：\(titles)")
        // 近档之后立即进入月档，粒度断层消失
        XCTAssertEqual(titles, ["今天", "昨天", "9月 1–15日"])
    }

    // MARK: 月份桶的范围标签（消除「10月」看起来包含整月的歧义）

    /// 当月桶只覆盖到「今天 - 近档窗口」，标题必须带范围：
    /// 今天 2026-10-23 → 本月桶是 10/1–10/15，显示「10月 1–15日」
    func testCurrentMonthBucketTitleCarriesRange() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 12))!
        let item = item(at: cal.date(from: DateComponents(year: 2026, month: 10, day: 5))!, title: "月初项")

        let groups = Timeline.group([item], now: now, calendar: cal)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(
            groups[0].title, "10月 1–15日",
            "当月桶只装 10/1–10/15，标题必须写明范围，否则会被读成整月"
        )
    }

    /// 历史月份覆盖整月，不加范围（仍显示「9月」）
    func testHistoricalMonthBucketTitleHasNoRange() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 12))!
        let item = item(at: cal.date(from: DateComponents(year: 2026, month: 9, day: 10))!, title: "九月项")

        let groups = Timeline.group([item], now: now, calendar: cal)
        XCTAssertEqual(groups.map(\.title), ["9月"], "历史月份是完整的，不该带范围")
    }

    /// 月初（今天 = 10/3）：近档覆盖 9/27–10/3，整个 10 月都还没进月档 → 本月桶为空
    func testEarlyInMonthYieldsNoCurrentMonthBucket() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 12))!
        // 10/1 距今 2 天 → 近档
        let octItem = item(at: cal.date(from: DateComponents(year: 2026, month: 10, day: 1))!, title: "一号项")
        let groups = Timeline.group([octItem], now: now, calendar: cal)
        XCTAssertEqual(groups.map(\.title), ["本周"], "月初时 10 月条目全在近档，不该出现月份桶")
    }

    /// 桶边界如实反映覆盖范围：本月桶最大日期必须正好在近档窗口之外
    func testCurrentMonthBucketRangeDoesNotOverlapNearTiers() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 12))!
        let lastDay = Timeline.monthBucketLastDay(month: 10, today: now, calendar: cal)
        XCTAssertEqual(lastDay, 15)

        // 15 日当天的条目进月档，16 日（近档起点）不进——两者不得重叠也不得遗漏
        let inside = item(at: cal.date(from: DateComponents(year: 2026, month: 10, day: 15))!, title: "15日")
        let outside = item(at: cal.date(from: DateComponents(year: 2026, month: 10, day: 16))!, title: "16日")
        let insideTitle = Timeline.group([inside], now: now, calendar: cal).map(\.title)
        let outsideTitle = Timeline.group([outside], now: now, calendar: cal).map(\.title)
        XCTAssertEqual(insideTitle, ["10月 1–15日"])
        XCTAssertEqual(outsideTitle, ["本周"])
    }

    /// 跨语言契约：Swift `TimeGroupSpan.justifiedDays` 必须等于 Rust
    /// `TimeGroupLevel::SPAN_JUSTIFIED_DAYS`。两处各写一个数字极易漂移，
    /// 漂移后锚点计数（Rust/SQL）与列表分组（Swift）会静默错位。
    func testThresholdMatchesRustContract() {
        XCTAssertEqual(TimeGroupSpan.justifiedDays, 7, "改动须同步 crates/nookclip-core/src/model.rs")
    }

    /// 不论星期几，第 8 天都必须离开近档——分档只看自然日差，不看周界
    func testBucketBoundaryIsWeekdayIndependent() {
        for weekdayOffset in 0..<7 {
            let now = calendar.date(
                byAdding: .day, value: weekdayOffset,
                to: calendar.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 12))!
            )!
            let day7 = makeItem(title: "七天前", daysAgo: TimeGroupSpan.justifiedDays, now: now)
            let day8 = makeItem(title: "八天前", daysAgo: TimeGroupSpan.justifiedDays + 1, now: now)

            XCTAssertEqual(
                Timeline.group([day7], now: now, calendar: calendar).map(\.title), ["本周"],
                "第 7 天应仍在近档（基准：\(now)）"
            )
            let m = calendar.component(.month, from: day8.lastUsedAt)
            let expectedLastDay = Timeline.monthBucketLastDay(month: m, today: now, calendar: calendar)
            XCTAssertEqual(
                Timeline.group([day8], now: now, calendar: calendar).map(\.title),
                ["\(m)月 1–\(expectedLastDay)日"],
                "第 8 天应进当月档（基准：\(now)）"
            )
        }
    }


    func testMonthAndYearArchive() {
        let may = calendar.date(from: DateComponents(year: 2026, month: 5, day: 10))!
        let lastYear = calendar.date(from: DateComponents(year: 2025, month: 3, day: 10))!
        let mayItem = item(at: may, title: "五月项")
        let lastYearItem = item(at: lastYear, title: "去年项")

        let groups = Timeline.group([mayItem, lastYearItem], now: refNow, calendar: calendar)
        XCTAssertEqual(groups.map(\.title), ["5月", "2025年"])
    }

    func testEmptyGroupsHidden() {
        let items = [makeItem(title: "唯一", daysAgo: 0, now: refNow)]
        let groups = Timeline.group(items, now: refNow, calendar: calendar)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.title, "今天")
    }

    func testFavoriteDoesNotAffectGroupOrder() {
        // 收藏只豁免清理，不改变组内排序（避免大量收藏把最新条目压到下方）
        let favorite = makeItem(title: "较早的收藏", daysAgo: 0, hoursAgo: 3, isFavorite: true, now: refNow)
        let normal = makeItem(title: "较新的普通", daysAgo: 0, hoursAgo: 1, now: refNow)
        let groups = Timeline.group([favorite, normal], now: refNow, calendar: calendar)
        XCTAssertEqual(groups.first?.items.map(\.title), ["较新的普通", "较早的收藏"])
    }

    func testRowModelAlsoGroupable() {
        // ClipboardRowModel 同样可分组（侧边栏时间区数据源）
        let model = ClipboardRowModel(item: item(at: refNow, title: "t"))
        let groups = Timeline.group([model], now: refNow, calendar: calendar)
        XCTAssertEqual(groups.first?.items.count, 1)
    }

    func testRecopiedItemLandsInCurrentDayGroup() {
        // 回归：昨天捕获的条目今天重复复制 → lastUsedAt 刷新为 now，
        // 必须归入「今天」组（原缺陷：按 createdAt 分组挂在「昨天」组）
        let yesterday = calendar.date(byAdding: .day, value: -1, to: refNow)!
        let recopied = ClipboardItem(
            type: .text, title: "重复制项", summary: "重复制项",
            createdAt: yesterday, lastUsedAt: refNow
        )
        let groups = Timeline.group([recopied], now: refNow, calendar: calendar)
        XCTAssertEqual(groups.map(\.title), ["今天"])
        XCTAssertEqual(groups.first?.items.first?.title, "重复制项")
    }

    // MARK: 统一搜索解析（tokenizeSearchKeywords：纯文本与短语）

    func testParseNaturalWordsAsKeywords() {
        let result = tokenizeSearchKeywords(query: "今天")
        XCTAssertEqual(result, ["今天"])
    }

    func testParseMultipleKeywords() {
        let result = tokenizeSearchKeywords(query: "上周 json")
        XCTAssertEqual(result, ["上周", "json"])
    }

    func testParseQuotedPhrases() {
        let result = tokenizeSearchKeywords(query: "\"order payment\" refund")
        XCTAssertEqual(result, ["order payment", "refund"])
    }
    // MARK: RelativeTime 格式化

    func testRelativeTimeJustNow() {
        let now = Date()
        let output = RelativeTime.string(from: now.addingTimeInterval(-30), now: now)
        // T051：相对语义断言——<60s 输入走同一「刚刚」分支（输出一致且非空），
        // 跨过 60s 边界则进入不同分支；不绑定具体本地化文案
        XCTAssertEqual(output, RelativeTime.string(from: now.addingTimeInterval(-59), now: now))
        XCTAssertFalse(output.isEmpty)
        XCTAssertNotEqual(output, RelativeTime.string(from: now.addingTimeInterval(-61), now: now))
    }

    func testRelativeTimeMinutes() {
        let now = Date()
        let output = RelativeTime.string(from: now.addingTimeInterval(-5 * 60), now: now)
        // T051：相对语义断言——1–59 分钟输入属同一格式分支（数字归一化后一致）
        // 且包含分钟数字；不绑定「N 分钟前」的具体文案措辞
        let normalize: (String) -> String = { $0.replacingOccurrences(of: "\\d", with: "#", options: .regularExpression) }
        XCTAssertEqual(normalize(output), normalize(RelativeTime.string(from: now.addingTimeInterval(-9 * 60), now: now)))
        XCTAssertTrue(output.contains("5"), "分钟数应出现在输出中")
        XCTAssertNotEqual(normalize(output), normalize(RelativeTime.string(from: now.addingTimeInterval(-30), now: now)))
    }

    // MARK: 全量时间戳分组（时间导航锚点条数据源）

    /// 分页列表只加载前 N 条时，锚点条仍须从全量时间戳得到完整分组：
    /// 时间戳跨今天 / 本月早些 / 去年 → 三个组齐全，空组不出现
    func testGroupTimestampsYieldsAllGroupsBeyondPageWindow() {
        let now = refNow
        let timestamps: [Date] = [
            now.addingTimeInterval(-3600),                       // 今天
            now.addingTimeInterval(-7200),                       // 今天
            calendar.date(byAdding: .day, value: -20, to: now)!, // 本月早些（9月）
            calendar.date(byAdding: .year, value: -1, to: now)!, // 去年
        ]

        let summaries = Timeline.groupTimestamps(timestamps, now: now, calendar: calendar)

        XCTAssertEqual(summaries.map(\.title), ["今天", "9月 1–20日", "2025年"], "全量分组不缺失更早的组")
        XCTAssertEqual(summaries.map(\.count), [2, 1, 1], "各组计数来自全部命中时间戳")
        XCTAssertEqual(summaries.map(\.id), ["today", "month-9", "year-2025"])
    }

    /// 空时间戳 → 无分组（锚点条整体隐藏）
    func testGroupTimestampsEmptyInputYieldsNoGroups() {
        XCTAssertTrue(Timeline.groupTimestamps([], now: refNow, calendar: calendar).isEmpty)
    }
}
