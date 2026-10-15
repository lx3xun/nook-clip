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

    func testThisWeekAndLastWeek() {
        // 基准周三 2026-09-23（gregorian 周界=周日起，本周=9-20~9-26）：
        // 9-21（周一）= 本周（非今昨）；9-17（周四）= 上周
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 12))!
        let items = [
            makeItem(title: "本周项", daysAgo: 2, now: now),
            makeItem(title: "上周项", daysAgo: 6, now: now),
        ]
        let groups = Timeline.group(items, now: now, calendar: calendar)
        let titles = groups.map(\.title)
        XCTAssertTrue(titles.contains("本周"))
        XCTAssertTrue(titles.contains("上周"))
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

    // MARK: 统一搜索解析（SearchQueryParser：纯文本与短语）

    func testParseNaturalWordsAsKeywords() {
        let result = SearchQueryParser.parse("今天")
        XCTAssertEqual(result.keywords, ["今天"])
    }

    func testParseMultipleKeywords() {
        let result = SearchQueryParser.parse("上周 json")
        XCTAssertEqual(result.keywords, ["上周", "json"])
    }

    func testParseQuotedPhrases() {
        let result = SearchQueryParser.parse("\"order payment\" refund")
        XCTAssertEqual(result.keywords, ["order payment", "refund"])
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

        XCTAssertEqual(summaries.map(\.title), ["今天", "9月", "2025年"], "全量分组不缺失更早的组")
        XCTAssertEqual(summaries.map(\.count), [2, 1, 1], "各组计数来自全部命中时间戳")
        XCTAssertEqual(summaries.map(\.id), ["today", "month-9", "year-2025"])
    }

    /// 空时间戳 → 无分组（锚点条整体隐藏）
    func testGroupTimestampsEmptyInputYieldsNoGroups() {
        XCTAssertTrue(Timeline.groupTimestamps([], now: refNow, calendar: calendar).isEmpty)
    }
}
