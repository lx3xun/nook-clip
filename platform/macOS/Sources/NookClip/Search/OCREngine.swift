import AppKit
import Foundation
import Vision

final class OCREngine: @unchecked Sendable {
    static let shared = OCREngine()

    private let prewarmLock = NSLock()
    private var isPrewarmed = false

    private init() {}

    /// 后台低优先级预热 Vision 神经网络模型，消除用户首次点击识别时的冷启动耗时。
    func prewarm() {
        prewarmLock.lock()
        if isPrewarmed {
            prewarmLock.unlock()
            return
        }
        isPrewarmed = true
        prewarmLock.unlock()

        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(
                data: nil,
                width: 16,
                height: 16,
                bitsPerComponent: 8,
                bytesPerRow: 64,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let dummyImage = context.makeImage() else {
                return
            }

            let handler = VNImageRequestHandler(cgImage: dummyImage, options: [:])
            _ = self.executeRecognition(using: handler)
        }
    }

    /// 识别本地图片文件中的文字（使用 URL 直接交给系统流式解码，避免中间创建 NSImage 全量位图）
    func recognizeText(from imagePath: String) async -> String? {
        guard FileManager.default.fileExists(atPath: imagePath) else {
            return nil
        }
        let url = URL(fileURLWithPath: imagePath)
        return await Task.detached(priority: .userInitiated) {
            let handler = VNImageRequestHandler(url: url, options: [:])
            return self.executeRecognition(using: handler)
        }.value
    }

    /// 识别二进制图片数据中的文字
    func recognizeText(from data: Data) async -> String? {
        await Task.detached(priority: .userInitiated) {
            let handler = VNImageRequestHandler(data: data, options: [:])
            return self.executeRecognition(using: handler)
        }.value
    }

    /// 识别 NSImage 中的文字
    func recognizeText(from image: NSImage) async -> String? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return await recognizeText(from: cgImage)
    }

    /// 使用 Apple Vision 原生离线识别文字（中文简体/繁体、英文）。
    func recognizeText(from cgImage: CGImage) async -> String? {
        await Task.detached(priority: .userInitiated) {
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            return self.executeRecognition(using: handler)
        }.value
    }

    private func executeRecognition(using handler: VNImageRequestHandler) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.usesLanguageCorrection = true

        do {
            try handler.perform([request])
            guard let observations = request.results else {
                return nil
            }
            let blocks: [OCRTextBlock] = observations.compactMap { observation in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                return OCRTextBlock(text: text, rect: observation.boundingBox)
            }
            let fullText = OCRLayoutFormatter.format(blocks: blocks)
            return fullText.isEmpty ? nil : fullText
        } catch {
            return nil
        }
    }
}

