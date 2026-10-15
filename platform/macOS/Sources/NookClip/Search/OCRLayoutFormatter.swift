import Foundation

struct OCRTextBlock: Equatable {
    let text: String
    let rect: CGRect
}

enum OCRLayoutFormatter {
    /// 根据文字块坐标重排版
    static func format(blocks: [OCRTextBlock]) -> String {
        guard !blocks.isEmpty else { return "" }

        // 按 Y 轴降序排列（Vision 坐标系原点在左下角，Y 越大越靠上）
        let sortedByY = blocks.sorted { $0.rect.midY > $1.rect.midY }

        // 动态聚类归行
        var lines: [[OCRTextBlock]] = []
        for block in sortedByY {
            let threshold = block.rect.height * 0.5
            if let lastIndex = lines.indices.last,
               let lineMidY = lines[lastIndex].first?.rect.midY,
               abs(lineMidY - block.rect.midY) < threshold {
                lines[lastIndex].append(block)
            } else {
                lines.append([block])
            }
        }

        // 行内从左到右排序并按间距追加空格
        // 行内从左到右排序并按间距追加空格
        struct RenderedLine {
            let text: String
            let minY: CGFloat
            let maxY: CGFloat
            let avgHeight: CGFloat
        }

        var renderedLines: [RenderedLine] = []
        for line in lines {
            let sortedLine = line.sorted { $0.rect.minX < $1.rect.minX }
            var lineString = ""
            var lastMaxX: CGFloat? = nil
            for item in sortedLine {
                let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if let prevMaxX = lastMaxX {
                    let spacing = item.rect.minX - prevMaxX
                    if spacing > item.rect.height * 0.2 {
                        lineString += " "
                    }
                }
                lineString += trimmed
                lastMaxX = item.rect.maxX
            }

            if !lineString.isEmpty {
                let minY = sortedLine.map(\.rect.minY).min() ?? 0
                let maxY = sortedLine.map(\.rect.maxY).max() ?? 0
                let avgHeight = sortedLine.map(\.rect.height).reduce(0, +) / CGFloat(sortedLine.count)
                renderedLines.append(RenderedLine(text: lineString, minY: minY, maxY: maxY, avgHeight: avgHeight))
            }
        }

        guard !renderedLines.isEmpty else { return "" }

        // 多行组装：当相邻两行垂直间距明显大于正常行高（> 1.5 倍）时，保留空行分段
        var output = ""
        var prevLine: RenderedLine? = nil
        for line in renderedLines {
            if let prev = prevLine {
                let verticalGap = prev.minY - line.maxY
                if verticalGap > prev.avgHeight * 1.5 {
                    output += "\n\n"
                } else {
                    output += "\n"
                }
            }
            output += line.text
            prevLine = line
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
