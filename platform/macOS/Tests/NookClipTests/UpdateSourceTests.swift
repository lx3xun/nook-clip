import XCTest
@testable import NookClip

/// 自动更新（Sparkle）更新源选择的纯逻辑回归：
/// 持久化 rawValue 往返、feed URL 与双仓库发布约定一致
final class UpdateSourceTests: XCTestCase {

    func testRawValueRoundTrip() {
        for source in UpdateSource.allCases {
            XCTAssertEqual(UpdateSource(rawValue: source.rawValue), source)
        }
        XCTAssertEqual(UpdateSource.allCases.count, 3)
    }

    func testFeedURLsMatchReleaseConventions() {
        // 固定 tag `appcast` 承载清单；两仓库下载路径格式均经实测确认
        XCTAssertEqual(
            UpdateSource.githubFeedURL.absoluteString,
            "https://github.com/lx3xun/nook-clip/releases/download/appcast/appcast.xml"
        )
        XCTAssertEqual(
            UpdateSource.giteeFeedURL.absoluteString,
            "https://gitee.com/lx3xun/nook-clip/releases/download/appcast/appcast.xml"
        )
    }

    func testExplicitSourcesMapToTheirOwnFeed() {
        XCTAssertEqual(UpdateSource.github.feedURL, UpdateSource.githubFeedURL)
        XCTAssertEqual(UpdateSource.gitee.feedURL, UpdateSource.giteeFeedURL)
    }

    func testAutoSourcePrefersGitHubByDefault() {
        // 探测完成前的兜底行为：auto 走 GitHub（UpdateService.resolvedAutoSource 初值）
        XCTAssertEqual(UpdateSource.auto.feedURL, UpdateSource.githubFeedURL)
    }

    func testInvalidPersistedValueIsRejected() {
        XCTAssertNil(UpdateSource(rawValue: "npm"))
        XCTAssertNil(UpdateSource(rawValue: ""))
    }

    @MainActor
    func testUpdateServiceEffectiveFeedURL() {
        let service = UpdateService.shared
        XCTAssertEqual(service.effectiveFeedURL(for: .github), UpdateSource.githubFeedURL)
        XCTAssertEqual(service.effectiveFeedURL(for: .gitee), UpdateSource.giteeFeedURL)
        XCTAssertEqual(service.effectiveFeedURL(for: .auto), service.resolvedAutoSource.feedURL)
    }

    @MainActor
    func testFeedURLStringReflectsUserDefaultsPreference() {
        let service = UpdateService.shared
        let oldSource = UserDefaults.standard.string(forKey: UserDefaultsKey.updateSource.rawValue)
        defer {
            if let oldSource {
                UserDefaults.standard.set(oldSource, forKey: UserDefaultsKey.updateSource.rawValue)
            } else {
                UserDefaults.standard.removeObject(forKey: UserDefaultsKey.updateSource.rawValue)
            }
        }

        // 设置为 gitee
        UserDefaults.standard.set("gitee", forKey: UserDefaultsKey.updateSource.rawValue)
        let giteeFeed = service.feedURLString(for: service.updater)
        XCTAssertEqual(giteeFeed, UpdateSource.giteeFeedURL.absoluteString)

        // 设置为 github
        UserDefaults.standard.set("github", forKey: UserDefaultsKey.updateSource.rawValue)
        let githubFeed = service.feedURLString(for: service.updater)
        XCTAssertEqual(githubFeed, UpdateSource.githubFeedURL.absoluteString)
    }
}
