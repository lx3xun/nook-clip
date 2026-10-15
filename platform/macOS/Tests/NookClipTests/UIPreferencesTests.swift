import XCTest
@testable import NookClip

final class UIPreferencesTests: XCTestCase {

    func testRowSelectionStyleEnum() {
        XCTAssertEqual(RowSelectionStyle.solidAccent.rawValue, "solidAccent")
        XCTAssertEqual(RowSelectionStyle.subtleAccent.rawValue, "subtleAccent")
        XCTAssertEqual(RowSelectionStyle.allCases.count, 2)
        XCTAssertEqual(RowSelectionStyle(rawValue: "unknown"), nil)
    }


    func testTimelineJumpModeEnum() {
        XCTAssertEqual(TimelineJumpMode.indexRail.rawValue, "indexRail")
        XCTAssertEqual(TimelineJumpMode.groupHeaderMenu.rawValue, "groupHeaderMenu")
        XCTAssertEqual(TimelineJumpMode.allCases.count, 2)
        XCTAssertEqual(TimelineJumpMode(rawValue: "unknown"), nil)
    }

    func testUserDefaultsKeysConsistency() {
        XCTAssertEqual(UserDefaultsKey.rowSelectionStyle.rawValue, "rowSelectionStyle")
        XCTAssertEqual(UserDefaultsKey.timelineJumpMode.rawValue, "timelineJumpMode")
    }

    func testDesignTokensConstants() {
        XCTAssertEqual(NookClip.widthListCol, 310)
        XCTAssertEqual(NookClip.heightRowList, 50)
        XCTAssertEqual(NookClip.heightFooter, 22)
        XCTAssertEqual(NookClip.heightSearch, 42, "顶栏搜索框高度调整为 42pt")
        XCTAssertEqual(NookClip.heightToolbar, 42, "预览顶栏工具栏高度基准与搜索栏平齐为 42pt")
        XCTAssertEqual(NookClip.searchTopInset, 0, "搜索栏顶顶贴边，顶部留白归零")
        XCTAssertEqual(NookClip.heightCategoryBar, 24)
        XCTAssertEqual(NookClip.hitWidthTimeRail, 24)
        XCTAssertEqual(NookClip.rowTrailingMargin, 16)
    }
}
