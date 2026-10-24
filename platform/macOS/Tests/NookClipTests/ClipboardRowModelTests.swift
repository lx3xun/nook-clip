import XCTest
@testable import NookClip

// T006：ClipboardRowModel 派生规则测试（specs/001-new-ui-cutover/data-model.md §2）

final class ClipboardRowModelTests: XCTestCase {

    private func makeItem(
        type: ClipboardItemType = .text,
        title: String = "标题",
        summary: String = "摘要内容",
        isSensitive: Bool = false,
        isFavorite: Bool = false,
        copyCount: Int = 1,
        payloadPath: String? = nil,
        sourceAppName: String? = nil,
        metadata: ClipboardMetadata = ClipboardMetadata()
    ) -> ClipboardItem {
        ClipboardItem(
            type: type,
            title: title,
            summary: summary,
            copyCount: copyCount,
            isFavorite: isFavorite,
            payloadPath: payloadPath,
            sourceAppName: sourceAppName,
            isSensitive: isSensitive,
            metadata: metadata
        )
    }
    func testImageKindAndFormatBadge() {
        let model = ClipboardRowModel(item: makeItem(type: .image, payloadPath: "/tmp/shot.png"))
        XCTAssertEqual(model.kind, .image)
        XCTAssertEqual(model.badge, .imageFormat("PNG"))
        XCTAssertFalse(model.badge?.isAccent ?? true)
    }

    func testImageBadgeFollowsPayloadExtension() {
        let model = ClipboardRowModel(item: makeItem(type: .image, payloadPath: "/tmp/shot.tiff"))
        XCTAssertEqual(model.kind, .image)
        XCTAssertEqual(model.badge, .imageFormat("TIFF"), "格式徽标取载荷扩展名，不限 PNG")
    }

    func testImageWithoutPayloadPathHasNoBadge() {
        let model = ClipboardRowModel(item: makeItem(type: .image, payloadPath: nil))
        XCTAssertEqual(model.kind, .image)
        XCTAssertNil(model.badge)
    }

    func testFileKindAndMDBadge() {
        let model = ClipboardRowModel(item: makeItem(type: .file, payloadPath: "/tmp/notes.md"))
        XCTAssertEqual(model.kind, .file)
        XCTAssertEqual(model.badge, .md)
    }

    // MARK: - 文件类图片展示层重分类（specs/001 data-model.md §2）

    func testSingleImageFileReclassifiedAsImageKind() {
        let model = ClipboardRowModel(item: makeItem(type: .file, payloadPath: "/tmp/photo.jpg"))
        XCTAssertEqual(model.kind, .image, "单一图片扩展名路径的文件条目归入图片分类")
        XCTAssertEqual(model.badge, .imageFormat("JPG"), "重分类图片的格式徽标取原文件扩展名")
    }

    func testSinglePNGFileReclassifiedWithBadge() {
        let model = ClipboardRowModel(item: makeItem(type: .file, payloadPath: "/tmp/shot.png"))
        XCTAssertEqual(model.kind, .image)
        XCTAssertEqual(model.badge, .imageFormat("PNG"))
    }

    func testNonImageFileStaysFileKind() {
        XCTAssertEqual(ClipboardRowModel(item: makeItem(type: .file, payloadPath: "/tmp/report.pdf")).kind, .file)
    }

    func testMultiFileImagePathsStayFileKind() {
        let joined = "/tmp/a.png\n/tmp/b.png"
        XCTAssertEqual(ClipboardRowModel(item: makeItem(type: .file, payloadPath: joined)).kind, .file,
                       "多文件（换行拼接）不重分类：缩略图与预览卡片按单路径加载")
    }

    func testSensitiveImageFileStaysSensitiveKind() {
        let model = ClipboardRowModel(item: makeItem(type: .file, isSensitive: true, payloadPath: "/tmp/a.png"))
        XCTAssertEqual(model.kind, .sensitive)
    }

    func testImageCategoryMatchesAndPrefilterIncludeReclassifiedFile() {
        let row = ClipboardRowModel(item: makeItem(type: .file, payloadPath: "/tmp/photo.jpg"))
        XCTAssertTrue(SidebarCategories.matchesCategory(2, row), "图片分类匹配重分类行")
    }

    func testURLKind() {
        XCTAssertEqual(ClipboardRowModel(item: makeItem(type: .url)).kind, .url)
    }

    func testJSONDetection() {
        let model = ClipboardRowModel(item: makeItem(summary: "{\"key\": \"value\"}"))
        XCTAssertEqual(model.kind, .json)
        XCTAssertEqual(model.badge, .json)
        XCTAssertTrue(model.badge?.isAccent ?? false)
        XCTAssertTrue(model.titleMono)
        XCTAssertTrue(model.summaryMono)
    }

    func testColorDetection() {
        let model = ClipboardRowModel(item: makeItem(summary: "#3B82F6"))
        XCTAssertEqual(model.kind, .color)
        XCTAssertEqual(model.colorHex, "#3B82F6")
        XCTAssertEqual(model.rgbValue, "59, 130, 246")
        XCTAssertNotNil(model.swatchColor)
        XCTAssertTrue(model.titleMono)
    }

    func testCodeDetection() {
        let model = ClipboardRowModel(item: makeItem(summary: "import SwiftUI\nfunc foo() -> Int { return 1 }"))
        XCTAssertEqual(model.kind, .code)
        XCTAssertTrue(model.titleMono)
        XCTAssertTrue(model.summaryMono)
    }

    func testPlainTextKind() {
        let model = ClipboardRowModel(item: makeItem(summary: "只是一段普通文本"))
        XCTAssertEqual(model.kind, .text)
        XCTAssertFalse(model.titleMono)
    }

    // MARK: 字段直传

    func testFieldPassthrough() {
        let model = ClipboardRowModel(item: makeItem(isFavorite: true, copyCount: 5, sourceAppName: "Safari"))
        XCTAssertTrue(model.isFavorite)
        XCTAssertEqual(model.copyCount, 5)
        XCTAssertEqual(model.source.name, "Safari")
    }

    func testUnknownSourceFallsBack() {
        let model = ClipboardRowModel(item: makeItem(sourceAppName: "SomeRandomApp"))
        XCTAssertEqual(model.source.name, "SomeRandomApp")
        XCTAssertNotEqual(model.source.symbol, "safari")
    }

    // MARK: 纯函数性（同输入同输出）

    func testPureFunctionSameInputSameOutput() {
        let item = makeItem(summary: "{\"a\": 1}")
        let a = ClipboardRowModel(item: item)
        let b = ClipboardRowModel(item: item)
        XCTAssertEqual(a, b)
    }

    // MARK: 侧边栏分类

    func testCategoriesHideEmptyTypeBuckets() {
        let items = [
            ClipboardRowModel(item: makeItem(summary: "文本 A")),
            ClipboardRowModel(item: makeItem(type: .url)),
        ]
        let cats = SidebarCategories.categories(for: items)
        let names = cats.map(\.name)
        XCTAssertTrue(names.contains("全部"))
        XCTAssertTrue(names.contains("文本"))
        XCTAssertTrue(names.contains("链接"))
        XCTAssertFalse(names.contains("图片"))   // 计数 0 自动隐藏
        XCTAssertFalse(names.contains("代码"))
        XCTAssertFalse(names.contains("私密"))
        XCTAssertTrue(names.contains("收藏"))     // 常驻
        XCTAssertFalse(names.contains("置顶"))    // 置顶功能已移除
    }


    func testEffectiveCategoryFallsBackToAll() {
        let items = [ClipboardRowModel(item: makeItem(summary: "x"))]  // 无图片
        XCTAssertEqual(SidebarCategories.effectiveCategoryID(2, in: items), 0)
    }

    func testMatchesCategory() {
        let model = ClipboardRowModel(item: makeItem(summary: "{\"a\":1}"))
        XCTAssertTrue(SidebarCategories.matchesCategory(5, model))   // 代码含 json
        XCTAssertFalse(SidebarCategories.matchesCategory(1, model))  // 非纯文本
    }

    func testSidebarCategoryFormattedCount() {
        XCTAssertEqual(SidebarCategory.formatCount(0), "0")
        XCTAssertEqual(SidebarCategory.formatCount(98), "98")
        XCTAssertEqual(SidebarCategory.formatCount(999), "999")
        XCTAssertEqual(SidebarCategory.formatCount(1000), "1k")
        XCTAssertEqual(SidebarCategory.formatCount(1004), "1k")
        XCTAssertEqual(SidebarCategory.formatCount(1094), "1.1k")
        XCTAssertEqual(SidebarCategory.formatCount(1200), "1.2k")
        XCTAssertEqual(SidebarCategory.formatCount(1999), "2k")
        XCTAssertEqual(SidebarCategory.formatCount(9999), "10k")
        XCTAssertEqual(SidebarCategory.formatCount(10000), "10k")
        XCTAssertEqual(SidebarCategory.formatCount(10500), "10.5k")
        XCTAssertEqual(SidebarCategory.formatCount(99900), "99.9k")
        XCTAssertEqual(SidebarCategory.formatCount(100000), "100k")
        XCTAssertEqual(SidebarCategory.formatCount(120000), "120k")

        let catUnder1k = SidebarCategory(id: 1, name: "文本", symbol: "doc.text", count: 279)
        XCTAssertEqual(catUnder1k.formattedCount, "279")
        let catOver1k = SidebarCategory(id: 0, name: "全部", symbol: "square.grid.2x2", count: 1094)
        XCTAssertEqual(catOver1k.formattedCount, "1.1k")
    }

    // MARK: - 图片路径透传（列表缩略图数据源）

    func testPayloadPathPassthrough() {
        XCTAssertEqual(ClipboardRowModel(item: makeItem(type: .image, payloadPath: "/tmp/shot.png")).payloadPath, "/tmp/shot.png")
        XCTAssertNil(ClipboardRowModel(item: makeItem(summary: "普通文本")).payloadPath)
    }

    // MARK: - 列表行分类展示信息重规划（语言徽标 / displaySummary / urlParts）

    func testCodeLanguageBadgeFromMetadata() {
        let model = ClipboardRowModel(item: makeItem(
            summary: "import SwiftUI\nfunc foo() {}",
            metadata: ClipboardMetadata(language: "swift")
        ))
        XCTAssertEqual(model.kind, .code)
        XCTAssertEqual(model.badge, .language("swift"))
        XCTAssertEqual(model.badge?.label, "Swift")
        XCTAssertFalse(model.badge?.isAccent ?? true)
    }

    func testCodeWithoutMetadataLanguageFallsBackToDetection() {
        // metadata.language 为 nil 时回退 CodeDetector 识别的语言
        let model = ClipboardRowModel(item: makeItem(summary: "import SwiftUI\nfunc foo() -> Int { return 1 }"))
        XCTAssertEqual(model.kind, .code)
        guard case .language = model.badge else {
            return XCTFail("expected language badge, got \(String(describing: model.badge))")
        }
    }

    func testDisplaySummaryStripsImageHash() {
        let model = ClipboardRowModel(item: makeItem(type: .image, summary: "1024 × 768 像素 · 340 KB #ab12cd34"))
        XCTAssertEqual(model.displaySummary, "1024 × 768 像素 · 340 KB")
    }

    func testDisplaySummaryPassthroughForText() {
        let model = ClipboardRowModel(item: makeItem(summary: "普通文本摘要"))
        XCTAssertEqual(model.displaySummary, "普通文本摘要")
    }

    func testURLPartsParsing() {
        let model = ClipboardRowModel(item: makeItem(type: .url, summary: "https://github.com/a/b?x=1"))
        let parts = model.urlParts
        XCTAssertEqual(parts?.schemePrefix, "https://")
        XCTAssertEqual(parts?.host, "github.com")
        XCTAssertEqual(parts?.remainder, "/a/b?x=1")
        // 三段拼接即完整 URL（副行展示全部内容）
        XCTAssertEqual((parts?.schemePrefix ?? "") + (parts?.host ?? "") + (parts?.remainder ?? ""), "https://github.com/a/b?x=1")
    }

    func testURLPartsNilForNonURL() {
        let model = ClipboardRowModel(item: makeItem(summary: "不是链接的普通文本"))
        XCTAssertNil(model.urlParts)
    }

    // MARK: 副行上下文与复制次数脱钩

    func testRowSubtitleContextualDetailDoesNotShowCopyCount() {
        let multiCopyItem = makeItem(type: .text, title: "", summary: "Hello World", copyCount: 10)
        let rowModel = ClipboardRowModel(item: multiCopyItem)
        let subtitleView = RowSubtitleView(item: rowModel)
        XCTAssertNil(subtitleView.contextualDetail, "列表行副行不应展示 ×10 复制次数")
    }

    func testRowSubtitleContextualDetailRetainsMeaningfulContext() {
        let urlItem = makeItem(type: .url, title: "", summary: "https://github.com/rust-lang/rust", copyCount: 5)
        let rowModel = ClipboardRowModel(item: urlItem)
        let subtitleView = RowSubtitleView(item: rowModel)
        XCTAssertEqual(subtitleView.contextualDetail, "github.com", "URL 条目仍应提取域名作为副行上下文")
    }

    // MARK: 相对时间展示（今天只显示时间 / 本周显示周几 / 昨天保留）

    private func makeCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "zh_CN")
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        cal.firstWeekday = 2 // 周一为一周起点
        return cal
    }

    func testRelativeTimeTodayShowsOnlyClock() {
        let cal = makeCalendar()
        // 2026-10-23（周五）15:20，条目在当天 09:05
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 15, minute: 20))!
        let date = cal.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 9, minute: 5))!
        let text = RelativeTime.string(from: date, now: now, calendar: cal)
        XCTAssertEqual(text, "09:05", "今天应只显示时间，不带「今天」前缀")
    }

    func testRelativeTimeYesterdayKeepsYesterdayLabel() {
        let cal = makeCalendar()
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 15, minute: 20))!
        let date = cal.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 9, minute: 5))!
        let text = RelativeTime.string(from: date, now: now, calendar: cal)
        XCTAssertTrue(text.hasPrefix("昨天"), "昨天应保留「昨天」文案，实际：\(text)")
        XCTAssertTrue(text.contains("09:05"))
    }

    func testRelativeTimeEarlierThisWeekShowsWeekday() {
        let cal = makeCalendar()
        // now = 2026-10-23 周五；10-21 周三 属本周且早于昨天 → 显示周几
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 15, minute: 20))!
        let date = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 9, minute: 5))!
        let text = RelativeTime.string(from: date, now: now, calendar: cal)
        XCTAssertTrue(text.hasPrefix("周三"), "本周较早日期应显示具体周几，实际：\(text)")
        XCTAssertTrue(text.contains("09:05"))
    }

    func testRelativeTimePreviousWeekFallsBackToMonthDay() {
        let cal = makeCalendar()
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 15, minute: 20))!
        let date = cal.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 9, minute: 5))!
        let text = RelativeTime.string(from: date, now: now, calendar: cal)
        XCTAssertTrue(text.contains("10月12日"), "上周日期仍应按「月日 + 时间」展示，实际：\(text)")
    }

    // MARK: 点击时间戳切换的完整时间文本

    func testDetailedStringSameYearOmitsYear() {
        let cal = makeCalendar()
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 15, minute: 20))!
        let date = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 9, minute: 5))!
        let text = RelativeTime.detailedString(from: date, now: now, calendar: cal)
        XCTAssertEqual(text, "10月21日 周三 09:05", "当年应展示「月日 周几 时间」，不带年份")
    }

    func testDetailedStringOtherYearIncludesYear() {
        let cal = makeCalendar()
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 15, minute: 20))!
        // 2024-10-21 是周一
        let date = cal.date(from: DateComponents(year: 2024, month: 10, day: 21, hour: 9, minute: 5))!
        let text = RelativeTime.detailedString(from: date, now: now, calendar: cal)
        XCTAssertEqual(text, "2024年10月21日 周一 09:05", "跨年时应在最前面补上年份")
    }

    // MARK: 英文用户的时间展示（本地化，不得输出中文「年月日」）

    private func makeEnglishCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "en_US")
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        cal.firstWeekday = 1 // 美国习惯：周日为一周起点
        return cal
    }

    func testEnglishDetailedStringUsesEnglishFormat() {
        let cal = makeEnglishCalendar()
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 15, minute: 20))!
        let date = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 9, minute: 5))!
        let text = RelativeTime.detailedString(from: date, now: now, calendar: cal)
        XCTAssertEqual(text, "Wed, Oct 21 09:05", "英文当年应为「Wed, Oct 21 09:05」")
    }

    func testEnglishDetailedStringOtherYearIncludesYear() {
        let cal = makeEnglishCalendar()
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 15, minute: 20))!
        let date = cal.date(from: DateComponents(year: 2024, month: 10, day: 21, hour: 9, minute: 5))!
        let text = RelativeTime.detailedString(from: date, now: now, calendar: cal)
        XCTAssertEqual(text, "Mon, Oct 21, 2024 09:05", "英文跨年应为「Mon, Oct 21, 2024 09:05」")
    }

    func testEnglishEarlierThisWeekShowsEnglishWeekday() {
        let cal = makeEnglishCalendar()
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 15, minute: 20))!
        let date = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 9, minute: 5))!
        let text = RelativeTime.string(from: date, now: now, calendar: cal)
        XCTAssertTrue(text.uppercased().hasPrefix("WED"), "英文本周日期应显示 Wed，实际：\(text)")
        XCTAssertTrue(text.contains("09:05"))
    }

    /// 英文更早日期（非本周、同一年）应为缩写月份而非「月/日」数字格式
    func testEnglishOlderDateUsesAbbreviatedMonth() {
        let cal = makeEnglishCalendar()
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 15, minute: 20))!
        let date = cal.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 9, minute: 5))!
        let text = RelativeTime.string(from: date, now: now, calendar: cal)
        XCTAssertEqual(text, "Oct 12 09:05", "英文更早日期应为「Oct 12 09:05」而非「10/12」")

        let crossYear = cal.date(from: DateComponents(year: 2024, month: 10, day: 21, hour: 9, minute: 5))!
        let crossText = RelativeTime.string(from: crossYear, now: now, calendar: cal)
        XCTAssertEqual(crossText, "Oct 21, 2024", "英文跨年日期应为「Oct 21, 2024」")
    }

    /// 繁体中文组合模板曾把周几粘在日期后（「10月21日週三」），应补空格
    func testTraditionalChineseWeekdayHasSpaceBeforeIt() {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "zh_TW")
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 15, minute: 20))!
        let date = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 9, minute: 5))!
        let text = RelativeTime.detailedString(from: date, now: now, calendar: cal)
        XCTAssertTrue(text.contains("10月21日 週三"), "繁中应为「10月21日 週三」带空格，实际：\(text)")
    }

    /// 回归：App 内切换语言后，时间展示必须跟随 App 语言而非系统语言。
    /// 曾出现「系统中文 + App 英文」时仍输出「周三 / 10月21日」的中英混排。
    func testAppLanguageEnglishOverridesSystemLocaleForTimestamps() {
        let original = LocalizationManager.shared.selectedLanguage
        defer { LocalizationManager.shared.selectedLanguage = original }

        LocalizationManager.shared.selectedLanguage = .en
        let cal = RelativeTime.displayCalendar
        XCTAssertEqual(cal.locale?.identifier, "en", "展示日历应跟随 App 语言（en）而非系统语言")

        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 15, minute: 20))!
        let thisWeek = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 9, minute: 5))!
        let compact = RelativeTime.string(from: thisWeek, now: now, calendar: cal)
        let detailed = RelativeTime.detailedString(from: thisWeek, now: now, calendar: cal)
        for text in [compact, detailed] {
            XCTAssertFalse(text.contains("周") || text.contains("月") || text.contains("日"),
                           "App 英文下不得出现中文日期单位，实际：\(text)")
        }
        XCTAssertTrue(detailed.uppercased().contains("WED"), "App 英文下应出现英文周几，实际：\(detailed)")
    }
}
