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

}
