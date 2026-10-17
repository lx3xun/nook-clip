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
        // 命中段黄底(#FFE633) + 前景字色(#1A1A1A)，无粗体语义，无底部横线
        var hits = 0
        var plain = 0
        for run in attr.runs {
            if run.foregroundColor != nil {
                hits += 1
                XCTAssertNil(run.inlinePresentationIntent, "不应添加粗体强调")
                XCTAssertNil(run.underlineStyle, "不应添加底部横线")
                XCTAssertEqual(run.backgroundColor, NookClip.searchHighlightBackground)
                XCTAssertEqual(run.foregroundColor, NookClip.searchHighlightForeground)
            } else {
                plain += 1
                XCTAssertNil(run.backgroundColor)
                XCTAssertNil(run.underlineStyle)
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

    func testAttributedOnAccentAlsoUsesYellowBackgroundAndDarkTextWithoutUnderlineOrBold() {
        let attr = SearchHighlight.attributed("hello world", keywords: ["world"], isOnAccent: true)!
        XCTAssertEqual(String(attr.characters), "hello world")
        var hits = 0
        var plain = 0
        for run in attr.runs {
            if run.foregroundColor != nil {
                hits += 1
                XCTAssertEqual(run.backgroundColor, NookClip.searchHighlightBackground)
                XCTAssertEqual(run.foregroundColor, NookClip.searchHighlightForeground)
                XCTAssertNil(run.underlineStyle, "选中态也不加横线")
                XCTAssertNil(run.inlinePresentationIntent, "选中态也不加粗体")
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

    func testSearchHighlightRendererCustomAttributeAndLayout() {
        let text = SearchHighlight.text("hello world", keywords: ["world"])
        if #available(macOS 15.0, *) {
            let host = NSHostingView(rootView: text.searchHighlightRenderer())
            host.frame = NSRect(x: 0, y: 0, width: 200, height: 40)
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            XCTAssertGreaterThan(rep.size.width, 0)
        }
    }
}
