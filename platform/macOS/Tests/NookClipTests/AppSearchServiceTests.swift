import XCTest
@testable import NookClip

final class AppSearchServiceTests: XCTestCase {
    // MARK: - 拼音转换测试

    func testPinyinHelperTransformChinese() {
        let (full, initials) = PinyinHelper.transform(text: "微信")
        XCTAssertEqual(full, "weixin")
        XCTAssertEqual(initials, "wx")
    }

    func testPinyinHelperTransformMultiWordChinese() {
        let (full, initials) = PinyinHelper.transform(text: "系统设置")
        XCTAssertEqual(full, "xitongshezhi")
        XCTAssertEqual(initials, "xtsz")
    }

    func testPinyinHelperTransformEnglish() {
        let (full, initials) = PinyinHelper.transform(text: "Safari")
        XCTAssertEqual(full, "safari")
        XCTAssertEqual(initials, "s")
    }

    func testPinyinHelperTransformEmpty() {
        let (full, initials) = PinyinHelper.transform(text: "   ")
        XCTAssertEqual(full, "")
        XCTAssertEqual(initials, "")
    }

    // MARK: - 匹配得分测试

    func testAppMatchScoreExactMatchRanksHighest() {
        let wechat = InstalledApp(
            id: "com.tencent.xinWeChat",
            name: "微信",
            bundleIdentifier: "com.tencent.xinWeChat",
            path: "/Applications/WeChat.app",
            url: URL(fileURLWithPath: "/Applications/WeChat.app"),
            englishName: "WeChat"
        )

        let exactScore = AppMatchScore.score(app: wechat, query: "微信")
        let initialsScore = AppMatchScore.score(app: wechat, query: "wx")
        let pinyinScore = AppMatchScore.score(app: wechat, query: "wei")
        let englishScore = AppMatchScore.score(app: wechat, query: "wechat")
        let mismatchScore = AppMatchScore.score(app: wechat, query: "qq")

        XCTAssertGreaterThan(exactScore, initialsScore)
        XCTAssertGreaterThan(initialsScore, 0)
        XCTAssertGreaterThan(pinyinScore, 0)
        XCTAssertGreaterThan(englishScore, 0)
        XCTAssertEqual(mismatchScore, 0)
    }

    func testAppMatchScoreInitialsMatching() {
        let calc = InstalledApp(
            id: "com.apple.calculator",
            name: "计算器",
            bundleIdentifier: "com.apple.calculator",
            path: "/System/Applications/Calculator.app",
            url: URL(fileURLWithPath: "/System/Applications/Calculator.app"),
            englishName: "Calculator"
        )

        let initialsScore = AppMatchScore.score(app: calc, query: "jsq")
        let englishPrefixScore = AppMatchScore.score(app: calc, query: "calc")

        XCTAssertGreaterThan(initialsScore, 0)
        XCTAssertGreaterThan(englishPrefixScore, 0)
    }

    // MARK: - AppSearchService 搜索与打开测试

    struct MockAppSearchProvider: AppSearchProvider {
        let apps: [InstalledApp]
        var onOpen: (@Sendable (InstalledApp) -> Bool)? = nil

        func loadApplications() -> [InstalledApp] {
            apps
        }

        func openApp(_ app: InstalledApp) -> Bool {
            onOpen?(app) ?? true
        }
    }

    @MainActor
    func testAppSearchServiceSearchAndRanking() {
        let mockApps = [
            InstalledApp(
                id: "com.tencent.xinWeChat",
                name: "微信",
                path: "/Applications/WeChat.app",
                url: URL(fileURLWithPath: "/Applications/WeChat.app"),
                englishName: "WeChat"
            ),
            InstalledApp(
                id: "com.apple.calculator",
                name: "计算器",
                path: "/System/Applications/Calculator.app",
                url: URL(fileURLWithPath: "/System/Applications/Calculator.app"),
                englishName: "Calculator"
            ),
            InstalledApp(
                id: "com.apple.Safari",
                name: "Safari",
                path: "/Applications/Safari.app",
                url: URL(fileURLWithPath: "/Applications/Safari.app"),
                englishName: "Safari"
            )
        ]

        let service = AppSearchService(provider: MockAppSearchProvider(apps: mockApps))

        // 搜 wx 命中微信
        let wxResults = service.search(query: "wx")
        XCTAssertEqual(wxResults.count, 1)
        XCTAssertEqual(wxResults.first?.name, "微信")

        // 搜 wechat 命中微信
        let wechatResults = service.search(query: "wechat")
        XCTAssertEqual(wechatResults.first?.name, "微信")

        // 搜 safari 命中 Safari
        let safariResults = service.search(query: "safari")
        XCTAssertEqual(safariResults.first?.name, "Safari")

        // 空串返回空
        let emptyResults = service.search(query: "  ")
        XCTAssertTrue(emptyResults.isEmpty)
    }

    @MainActor
    func testAppSearchServiceOpenApp() {
        final class OpenedAppBox: @unchecked Sendable {
            var app: InstalledApp?
        }
        let box = OpenedAppBox()
        let targetApp = InstalledApp(
            id: "com.apple.Safari",
            name: "Safari",
            path: "/Applications/Safari.app",
            url: URL(fileURLWithPath: "/Applications/Safari.app"),
            englishName: "Safari"
        )

        let mockProvider = MockAppSearchProvider(apps: [targetApp]) { app in
            box.app = app
            return true
        }

        let service = AppSearchService(provider: mockProvider)
        let success = service.openApp(targetApp)

        XCTAssertTrue(success)
        XCTAssertEqual(box.app?.id, targetApp.id)
    }
}
