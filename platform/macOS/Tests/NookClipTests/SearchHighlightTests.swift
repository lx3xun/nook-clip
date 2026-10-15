import XCTest
import SwiftUI
@testable import NookClip

/// 搜索命中高亮（SearchHighlight）：区间计算与 AttributedString 产出
final class SearchHighlightTests: XCTestCase {
    // MARK: matchRanges

    func testMatchRangesSingleKeywordAllOccurrences() {
        let ranges = SearchHighlight.matchRanges(in: "abcABCab", keywords: ["ab"])
        XCTAssertEqual(ranges.map { String("abcABCab"[$0]) }, ["ab", "AB", "ab"])
    }

    func testMatchRangesCaseInsensitive() {
        let ranges = SearchHighlight.matchRanges(in: "Hello hello HELLO", keywords: ["hello"])
        XCTAssertEqual(ranges.count, 3)
    }

    func testMatchRangesMultipleKeywordsMergedOverlaps() {
        // "abc" 与 "bcd" 在 "abcd" 中重叠，合并为一个区间
        let text = "abcd"
        let ranges = SearchHighlight.matchRanges(in: text, keywords: ["abc", "bcd"])
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(String(text[ranges[0]]), "abcd")
    }

    func testMatchRangesAdjacentMergedContiguous() {
        // 相邻命中合并为一个连续区间（连续 accent 渲染）
        let text = "abcd"
        let ranges = SearchHighlight.matchRanges(in: text, keywords: ["ab", "cd"])
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(String(text[ranges[0]]), "abcd")
    }

    func testMatchRangesEmptyKeywordIgnored() {
        XCTAssertTrue(SearchHighlight.matchRanges(in: "abc", keywords: ["", "z"]).isEmpty)
    }

    func testMatchRangesNoHit() {
        XCTAssertTrue(SearchHighlight.matchRanges(in: "abc", keywords: ["xyz"]).isEmpty)
    }

    func testMatchRangesEmptyText() {
        XCTAssertTrue(SearchHighlight.matchRanges(in: "", keywords: ["a"]).isEmpty)
    }

    // MARK: attributed

    func testAttributedNilForNilOrEmptyKeywords() {
        XCTAssertNil(SearchHighlight.attributed("abc", keywords: nil))
        XCTAssertNil(SearchHighlight.attributed("abc", keywords: []))
        XCTAssertNil(SearchHighlight.attributed("abc", keywords: [""]))
    }

    func testAttributedNilForNoHit() {
        XCTAssertNil(SearchHighlight.attributed("abc", keywords: ["xyz"]))
    }

    func testAttributedContentPreservedAndHitsMarked() {
        let attr = SearchHighlight.attributed("hello world", keywords: ["world"])!
        XCTAssertEqual(String(attr.characters), "hello world")
        // 命中段系统蓝前景 + 加粗语义，未命中段无额外属性（继承外层 modifier）
        var hits = 0
        var plain = 0
        for run in attr.runs {
            if run.foregroundColor != nil {
                hits += 1
                XCTAssertEqual(run.inlinePresentationIntent, .stronglyEmphasized)
                XCTAssertNil(run.backgroundColor)
            } else {
                plain += 1
                XCTAssertNil(run.backgroundColor)
                XCTAssertNil(run.inlinePresentationIntent)
            }
        }
        XCTAssertEqual(hits, 1)
        XCTAssertEqual(plain, 1)
        // 命中 run 的文本恰为关键词
        let hitRun = attr.runs.first { $0.foregroundColor != nil }!
        XCTAssertEqual(String(attr[hitRun.range].characters), "world")
    }

    func testAttributedMultipleHits() {
        let attr = SearchHighlight.attributed("ab ab ab", keywords: ["ab"])!
        XCTAssertEqual(attr.runs.filter { $0.foregroundColor != nil }.count, 3)
    }

    func testAttributedOnAccentUsesFluorescentYellowWithUnderlineAndNoBackground() {
        let attr = SearchHighlight.attributed("hello world", keywords: ["world"], isOnAccent: true)!
        XCTAssertEqual(String(attr.characters), "hello world")
        var hits = 0
        var plain = 0
        for run in attr.runs {
            if run.underlineStyle != nil {
                hits += 1
                XCTAssertEqual(run.foregroundColor, NookClip.searchHighlightOnSolidAccent)
                XCTAssertNil(run.backgroundColor)
                XCTAssertEqual(run.underlineStyle, Text.LineStyle(pattern: .solid, color: NookClip.searchHighlightOnSolidAccent))
                XCTAssertEqual(run.inlinePresentationIntent, .stronglyEmphasized)
            } else {
                plain += 1
                XCTAssertNil(run.backgroundColor)
                XCTAssertNil(run.underlineStyle)
                XCTAssertNil(run.inlinePresentationIntent)
            }
        }
        XCTAssertEqual(hits, 1)
        XCTAssertEqual(plain, 1)
    }

    func testSearchHighlightOnSolidAccentFallbackLogic() {
        // 默认非黄/橙强调色下，高亮色为荧光亮黄
        _ = NookClip.searchHighlightOnSolidAccent
        _ = NookClip.isWarmAccentColor
    }

    func testTextHelperFallsBackToPlain() {
        // 无命中：Text 仍可构造（无崩溃即可，字符串内容不丢）
        _ = SearchHighlight.text("abc", keywords: nil)
        _ = SearchHighlight.text("abc", keywords: ["xyz"])
        _ = SearchHighlight.text("abc", keywords: ["a"])
    }
}
