import SwiftUI

// 搜索命中段黄底（#FFE633）+ 深色文字（#1A1A1A），无粗体，无底部横线。
// 在支持 TextRenderer 的系统上（macOS 15+）绘制圆角黄底；同时在 AttributedString 上保持背景色与前景色，
// 兼容降级并保证测试断言与无缝回退。

/// 用于在 Text.Layout.Run 标记搜索命中片段的自定义属性
struct SearchHighlightAttribute: TextAttribute {}

/// 搜索关键词圆角黄底渲染器（macOS 15+）
/// 视觉对齐 site/prototype.css 中 mark.nook-highlight（#FFE633 黄底，2px 圆角，带内边距与外边距）。
/// 采用双阶段（Two-Pass）渲染：
/// 1. 为高亮词计算左右内边距（padding）与外边距（margin），同步后移后续文本片段，彻底消除字形遮挡；
/// 2. 底层绘制圆角黄色背景块，上层绘制文字 runs。
@available(macOS 15.0, *)
struct SearchHighlightRenderer: TextRenderer {
    var cornerRadius: CGFloat = 2.0
    var padding: CGFloat = 2.0 // 内边距：文字与黄底边缘的留白
    var margin: CGFloat = 1.0  // 外边距：黄底边缘与两侧相邻文字的间距

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            var xOffset: CGFloat = 0
            var backgroundRects: [CGRect] = []
            var runOffsets: [CGFloat] = []

            for run in line {
                let isHit = run[SearchHighlightAttribute.self] != nil
                if isHit {
                    // 左外边距 + 左内边距：为黄底左侧留白
                    xOffset += margin + padding
                    let bounds = run.typographicBounds.rect
                    // 黄底矩形覆盖文字及左右内边距
                    let bgRect = CGRect(
                        x: bounds.minX + xOffset - padding,
                        y: bounds.minY,
                        width: bounds.width + padding * 2,
                        height: bounds.height
                    )
                    backgroundRects.append(bgRect)
                    runOffsets.append(xOffset)
                    // 右内边距 + 右外边距：为黄底右侧留白并推移后续文字
                    xOffset += padding + margin
                } else {
                    runOffsets.append(xOffset)
                }
            }

            // 第一阶段：在底层绘制全部圆角黄色背景块
            for bg in backgroundRects {
                context.fill(
                    Path(roundedRect: bg, cornerRadius: cornerRadius),
                    with: .color(NookClip.searchHighlightBackground)
                )
            }

            // 第二阶段：在上层绘制所有文字 runs（带偏移位移），确保文字绝不被背景色遮挡
            for (run, offset) in zip(line, runOffsets) {
                if offset != 0 {
                    var runContext = context
                    runContext.translateBy(x: offset, y: 0)
                    runContext.draw(run)
                } else {
                    context.draw(run)
                }
            }
        }
    }
}

extension View {
    /// 为包含搜索高亮 Text 的视图应用圆角黄底渲染器
    @ViewBuilder
    func searchHighlightRenderer() -> some View {
        if #available(macOS 15.0, *) {
            self.textRenderer(SearchHighlightRenderer())
        } else {
            self
        }
    }
}

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

    /// 高亮文本：命中段黄底（#FFE633）+ 深色文字（#1A1A1A），无粗体，无下划线。
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
            hit.backgroundColor = NookClip.searchHighlightBackground
            hit.foregroundColor = NookClip.searchHighlightForeground
            result.append(hit)
            cursor = range.upperBound
        }
        if cursor < text.endIndex {
            result.append(AttributedString(String(text[cursor..<text.endIndex])))
        }
        return result
    }

    /// 渲染入口：命中时返回带高亮标记的 Text，支持通过 .searchHighlightRenderer() 渲染圆角黄底
    static func text(
        _ content: String,
        keywords: [String]?,
        isOnAccent: Bool = false
    ) -> Text {
        guard let keywords, !keywords.isEmpty else { return Text(verbatim: content) }
        let ranges = matchRanges(in: content, keywords: keywords)
        guard !ranges.isEmpty else { return Text(verbatim: content) }
        var segments: [Text] = []
        var cursor = content.startIndex
        for range in ranges {
            if cursor < range.lowerBound {
                segments.append(Text(verbatim: String(content[cursor..<range.lowerBound])))
            }
            let hit = Text(verbatim: String(content[range]))
                .foregroundColor(NookClip.searchHighlightForeground)
                .customAttribute(SearchHighlightAttribute())
            segments.append(hit)
            cursor = range.upperBound
        }
        if cursor < content.endIndex {
            segments.append(Text(verbatim: String(content[cursor..<content.endIndex])))
        }
        return segments.reduce(Text(verbatim: "")) { acc, seg in
            Text("\(acc)\(seg)")
        }
    }
}
