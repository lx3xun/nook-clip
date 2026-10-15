import XCTest
@testable import NookClip

final class OCRLayoutFormatterTests: XCTestCase {
    // MARK: - Slice 1: 同行多块归行与横向排序

    func testSameLineBlocksAreMergedInHorizontalOrder() {
        // 同一行上的两个词，传入顺序被打乱（先右后左）
        // midY 均为 0.8，高度均为 0.05
        let blockRight = OCRTextBlock(
            text: "World",
            rect: CGRect(x: 0.5, y: 0.775, width: 0.3, height: 0.05)
        )
        let blockLeft = OCRTextBlock(
            text: "Hello",
            rect: CGRect(x: 0.1, y: 0.775, width: 0.3, height: 0.05)
        )

        let result = OCRLayoutFormatter.format(blocks: [blockRight, blockLeft])

        // 应该归入同一行并从左往右排序，不应分成两行 "World\nHello"
        XCTAssertEqual(result, "Hello World")
    }

    // MARK: - Slice 2: 紧贴块不加空格，有间隙块加空格

    func testAdjacentBlocksWithoutGapDoNotAddSpace() {
        // 紧贴的中文字符块（无明显水平间隙）
        let block1 = OCRTextBlock(
            text: "中",
            rect: CGRect(x: 0.1, y: 0.8, width: 0.05, height: 0.05)
        )
        let block2 = OCRTextBlock(
            text: "文",
            rect: CGRect(x: 0.151, y: 0.8, width: 0.05, height: 0.05)
        )

        let result = OCRLayoutFormatter.format(blocks: [block1, block2])
        XCTAssertEqual(result, "中文")
    }

    // MARK: - Slice 3: 多行内容按 Y 轴自顶向下换行重排

    func testMultipleLinesAreSortedTopToBottomRegardlessOfInputOrder() {
        let topBlock = OCRTextBlock(
            text: "Top Line",
            rect: CGRect(x: 0.1, y: 0.85, width: 0.3, height: 0.05)
        )
        let middleBlock = OCRTextBlock(
            text: "Middle Line",
            rect: CGRect(x: 0.1, y: 0.78, width: 0.3, height: 0.05)
        )
        let bottomBlock = OCRTextBlock(
            text: "Bottom Line",
            rect: CGRect(x: 0.1, y: 0.71, width: 0.3, height: 0.05)
        )

        // 以乱序传入：底 -> 顶 -> 中
        let result = OCRLayoutFormatter.format(blocks: [bottomBlock, topBlock, middleBlock])
        XCTAssertEqual(result, "Top Line\nMiddle Line\nBottom Line")
    }

    func testEmptyBlocksAreIgnored() {
        let emptyBlock = OCRTextBlock(
            text: "   ",
            rect: CGRect(x: 0.1, y: 0.85, width: 0.1, height: 0.05)
        )
        let validBlock = OCRTextBlock(
            text: "Valid",
            rect: CGRect(x: 0.2, y: 0.85, width: 0.2, height: 0.05)
        )

        let result = OCRLayoutFormatter.format(blocks: [emptyBlock, validBlock])
        XCTAssertEqual(result, "Valid")
    }

    func testParagraphBreakInsertsBlankLineWhenSpacingIsLarge() {
        let paragraph1 = OCRTextBlock(
            text: "Paragraph 1",
            rect: CGRect(x: 0.1, y: 0.85, width: 0.4, height: 0.05)
        )
        // 正常行距下一行通常紧随其后（如 y = 0.78）
        // 此时段落 2 在 y = 0.55，间隔达 0.25（为行高的 5 倍），属于明显的段落空行
        let paragraph2 = OCRTextBlock(
            text: "Paragraph 2",
            rect: CGRect(x: 0.1, y: 0.55, width: 0.4, height: 0.05)
        )

        let result = OCRLayoutFormatter.format(blocks: [paragraph1, paragraph2])
        XCTAssertEqual(result, "Paragraph 1\n\nParagraph 2")
    }
}
