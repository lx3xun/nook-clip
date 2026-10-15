import XCTest
@testable import NookClip

// T029：批量合并粘贴纯函数测试（specs/001-new-ui-cutover/tasks.md）
// 验证连接顺序与分隔符（\n）
final class BatchPasteTests: XCTestCase {

    func testJoinTextsPreservesOrder() {
        let joined = BatchPaste.joinTexts(["第一项", "第二项", "第三项"])
        XCTAssertEqual(joined, "第一项\n第二项\n第三项")
    }

    func testJoinTextsUsesNewlineSeparator() {
        let joined = BatchPaste.joinTexts(["a", "b"])
        XCTAssertEqual(joined.components(separatedBy: "\n"), ["a", "b"])
        XCTAssertFalse(joined.contains("\r"))
        XCTAssertFalse(joined.contains(" "))
    }

    func testJoinTextsEmptyAndSingle() {
        XCTAssertEqual(BatchPaste.joinTexts([]), "")
        XCTAssertEqual(BatchPaste.joinTexts(["only"]), "only")
    }

    func testJoinTextsKeepsInternalNewlinesIntact() {
        let joined = BatchPaste.joinTexts(["line1\nline2", "line3"])
        XCTAssertEqual(joined, "line1\nline2\nline3")
    }
}
