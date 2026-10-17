import Foundation

struct OCRTextBlock: Equatable {
    let text: String
    let rect: CGRect
}

enum OCRLayoutFormatter {
    /// 根据文字块坐标重排版（单轨化委托给 Rust 核心 algorithms::ocr_layout）
    static func format(blocks: [OCRTextBlock]) -> String {
        guard !blocks.isEmpty else { return "" }
        let ffiBlocks = blocks.map {
            OcrTextBlock(
                text: $0.text,
                x: Double($0.rect.origin.x),
                y: Double($0.rect.origin.y),
                width: Double($0.rect.size.width),
                height: Double($0.rect.size.height)
            )
        }
        return formatOcrLayoutBlocks(blocks: ffiBlocks)
    }
}
