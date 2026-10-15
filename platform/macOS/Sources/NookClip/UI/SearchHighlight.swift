import SwiftUI

// MARK: - 搜索命中高亮（纯函数）
//
// 匹配语义与过滤链一致（localizedCaseInsensitiveContains 的区间版），
// 保证「高亮的片段」=「让该条目命中的片段」；命中段用系统强调蓝（NookClip.accent）
// 搭配加粗语义（Raycast / Spotlight 风格，无底色块避免与深浅背景或选中行产生脏色混叠）。
// 无关键词或无命中返回 nil / 原 Text，调用方零成本回退纯文本渲染。

enum SearchHighlight {
    /// text 中所有关键词的命中区间（升序、跨关键词合并重叠）。
    /// 单关键词内自左向右不重叠扫描；与 `localizedCaseInsensitiveContains` 同源比较。
    static func matchRanges(in text: String, keywords: [String]) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        for keyword in keywords {
            guard !keyword.isEmpty else { continue }
            var cursor = text.startIndex
            while cursor < text.endIndex,
                  let range = text.range(
                    of: keyword,
                    options: [.caseInsensitive],
                    range: cursor..<text.endIndex,
                    locale: .current
                  ) {
                found.append(range)
                // 正常命中非空（keyword 非空）；防御性推进避免零长度死循环
                cursor = range.upperBound > cursor ? range.upperBound : text.index(after: range.lowerBound)
            }
        }
        guard found.count > 1 else { return found }
        found.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for range in found {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                if range.upperBound > last.upperBound {
                    merged[merged.count - 1] = last.lowerBound..<range.upperBound
                }
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// 高亮文本：命中段前景色 + 加粗强调。
    /// - 默认（!isOnAccent）：系统蓝前景色（NookClip.accent），无背景色，继承外层文本修饰；
    /// - 实色选中高亮（isOnAccent）：经典系统强调色实色行底（整行底色为 NookClip.accent）中，
    ///   命中段切换为高对比荧光亮黄（NookClip.searchHighlightOnSolidAccent，若系统强调色本身为黄/橙则防撞色切换为深炭黑）+
    ///   同色细下划线 + 加粗强调，无背景色块，避免融色并获得高穿透力检索识别。
    static func attributed(
        _ text: String,
        keywords: [String]?,
        isOnAccent: Bool = false
    ) -> AttributedString? {
        guard let keywords, !keywords.isEmpty else { return nil }
        let ranges = matchRanges(in: text, keywords: keywords)
        guard !ranges.isEmpty else { return nil }
        var result = AttributedString()
        var cursor = text.startIndex
        for range in ranges {
            if cursor < range.lowerBound {
                result.append(AttributedString(String(text[cursor..<range.lowerBound])))
            }
            var hit = AttributedString(String(text[range]))
            if isOnAccent {
                let highlightColor = NookClip.searchHighlightOnSolidAccent
                hit.foregroundColor = highlightColor
                hit.underlineStyle = Text.LineStyle(pattern: .solid, color: highlightColor)
            } else {
                hit.foregroundColor = NookClip.accent
            }
            hit.inlinePresentationIntent = .stronglyEmphasized
            result.append(hit)
            cursor = range.upperBound
        }
        if cursor < text.endIndex {
            result.append(AttributedString(String(text[cursor..<text.endIndex])))
        }
        return result
    }

    /// 渲染入口：命中时返回带高亮的 Text，否则原文本 Text（字体/行数等仍由调用方 modifier 控制）
    static func text(
        _ content: String,
        keywords: [String]?,
        isOnAccent: Bool = false
    ) -> Text {
        if let highlighted = attributed(content, keywords: keywords, isOnAccent: isOnAccent) {
            return Text(highlighted)
        }
        return Text(verbatim: content)
    }
}
