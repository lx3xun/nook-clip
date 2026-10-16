import AppKit
import Darwin
import Foundation
import Vision

/// OCR 按需识别与自动回收的阶段状态（驱动预览区实时步骤日志展示）
public enum OCRProgressStage: Int, CaseIterable, Comparable, Sendable {
    /// 正在加载 Apple Vision 离线 OCR 引擎与中英文语言模型
    case loadingEngine = 0
    /// 正在执行多语言神经网络文字检测与版面分析
    case recognizingText = 1
    /// 正在重排文字坐标并执行敏感信息安全校验
    case formattingLayout = 2
    /// 识别完成，正在释放 Vision 神经网络缓存并回收内存
    case reclaimingMemory = 3

    public static func < (lhs: OCRProgressStage, rhs: OCRProgressStage) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var localizationKey: String {
        switch self {
        case .loadingEngine: return "preview.ocr.stage.loading_engine"
        case .recognizingText: return "preview.ocr.stage.recognizing"
        case .formattingLayout: return "preview.ocr.stage.formatting"
        case .reclaimingMemory: return "preview.ocr.stage.reclaiming"
        }
    }

    var localizedTitle: String {
        L10n.tr(localizationKey)
    }

    fileprivate var wireToken: String {
        switch self {
        case .loadingEngine: return "STAGE:loadingEngine"
        case .recognizingText: return "STAGE:recognizingText"
        case .formattingLayout: return "STAGE:formattingLayout"
        case .reclaimingMemory: return "STAGE:reclaimingMemory"
        }
    }

    fileprivate static func fromWireLine(_ line: String) -> OCRProgressStage? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        for stage in Self.allCases where stage.wireToken == trimmed {
            return stage
        }
        return nil
    }
}

final class OCREngine: @unchecked Sendable {
    static let shared = OCREngine()

    private let prewarmLock = NSLock()
    private var isPrewarmed = false

    private init() {}

    /// 保留幂等空操作入口（兼容旧调用与单测）：
    /// 现改为按需在隔离工作子进程中加载 Vision 模型，并在识别结束后立即退出子进程，
    /// 使 ~35MB Espresso/Metal/ANE 神经网络缓存彻底归还系统，主进程零常驻开销。
    func prewarm() {
        prewarmLock.lock()
        isPrewarmed = true
        prewarmLock.unlock()
    }

    /// 回收当前进程分配器空闲缓存页
    static func reclaimProcessMemory() {
        malloc_zone_pressure_relief(nil, 0)
    }

    /// 子进程 Worker 入口（由 `NookClipMain` 在收到 `--ocr-worker-image <path>` 时直接调用并退出）：
    /// 在独立进程空间内加载 Apple Vision、输出阶段日志到 stderr、输出识别文本到 stdout，
    /// 进程退出即由内核 100% 回收 Vision / Espresso / Metal 占用的全部物理内存页。
    static func runSubprocessWorker(imagePath: String) -> Int32 {
        func emitStage(_ stage: OCRProgressStage) {
            if let data = (stage.wireToken + "\n").data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
        }

        emitStage(.loadingEngine)
        guard FileManager.default.fileExists(atPath: imagePath) else {
            emitStage(.reclaimingMemory)
            return 0
        }

        let text: String? = autoreleasepool {
            let url = URL(fileURLWithPath: imagePath)
            let handler = VNImageRequestHandler(url: url, options: [:])
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.usesLanguageCorrection = true

            emitStage(.recognizingText)
            do {
                try handler.perform([request])
                emitStage(.formattingLayout)
                guard let observations = request.results else {
                    return nil
                }
                let blocks: [OCRTextBlock] = observations.compactMap { observation in
                    guard let candidate = observation.topCandidates(1).first?.string else { return nil }
                    return OCRTextBlock(text: candidate, rect: observation.boundingBox)
                }
                let fullText = OCRLayoutFormatter.format(blocks: blocks)
                return fullText.isEmpty ? nil : fullText
            } catch {
                return nil
            }
        }

        emitStage(.reclaimingMemory)
        if let text, let data = text.data(using: .utf8) {
            FileHandle.standardOutput.write(data)
        }
        return 0
    }

    /// 识别本地图片文件中的文字（支持实时阶段回调与子进程自动内存回收）
    func recognizeText(
        from imagePath: String,
        onStageChange: (@Sendable @MainActor (OCRProgressStage) -> Void)? = nil
    ) async -> String? {
        guard FileManager.default.fileExists(atPath: imagePath) else {
            return nil
        }
        if let executableURL = Self.workerExecutableURL() {
            return await recognizeViaSubprocess(
                executableURL: executableURL,
                imagePath: imagePath,
                onStageChange: onStageChange
            )
        }
        let url = URL(fileURLWithPath: imagePath)
        return await Task.detached(priority: .userInitiated) {
            await onStageChange?(.loadingEngine)
            let result: String? = autoreleasepool {
                let handler = VNImageRequestHandler(url: url, options: [:])
                return self.executeRecognition(using: handler, onStageChange: onStageChange)
            }
            await onStageChange?(.reclaimingMemory)
            Self.reclaimProcessMemory()
            return result
        }.value
    }

    /// 识别二进制图片数据中的文字
    func recognizeText(
        from data: Data,
        onStageChange: (@Sendable @MainActor (OCRProgressStage) -> Void)? = nil
    ) async -> String? {
        await Task.detached(priority: .userInitiated) {
            await onStageChange?(.loadingEngine)
            let result: String? = autoreleasepool {
                let handler = VNImageRequestHandler(data: data, options: [:])
                return self.executeRecognition(using: handler, onStageChange: onStageChange)
            }
            await onStageChange?(.reclaimingMemory)
            Self.reclaimProcessMemory()
            return result
        }.value
    }

    /// 识别 NSImage 中的文字
    func recognizeText(
        from image: NSImage,
        onStageChange: (@Sendable @MainActor (OCRProgressStage) -> Void)? = nil
    ) async -> String? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return await recognizeText(from: cgImage, onStageChange: onStageChange)
    }

    /// 使用 Apple Vision 原生离线识别文字（中文简体/繁体、英文）。
    func recognizeText(
        from cgImage: CGImage,
        onStageChange: (@Sendable @MainActor (OCRProgressStage) -> Void)? = nil
    ) async -> String? {
        await Task.detached(priority: .userInitiated) {
            await onStageChange?(.loadingEngine)
            let result: String? = autoreleasepool {
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                return self.executeRecognition(using: handler, onStageChange: onStageChange)
            }
            await onStageChange?(.reclaimingMemory)
            Self.reclaimProcessMemory()
            return result
        }.value
    }

    /// 判断当前主执行文件是否为 NookClip 自身（排除 swiftpm-testing-helper / xctest 等测试宿主）
    private static func workerExecutableURL() -> URL? {
        guard NSClassFromString("XCTestCase") == nil,
              let execURL = Bundle.main.executableURL,
              execURL.lastPathComponent == "NookClip",
              FileManager.default.isExecutableFile(atPath: execURL.path) else {
            return nil
        }
        return execURL
    }

    /// 通过短生命周期子进程执行 Vision OCR，识别完毕子进程立即退出，主进程零残留
    private func recognizeViaSubprocess(
        executableURL: URL,
        imagePath: String,
        onStageChange: (@Sendable @MainActor (OCRProgressStage) -> Void)?
    ) async -> String? {
        await onStageChange?(.loadingEngine)
        return await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = ["--ocr-worker-image", imagePath]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                for line in chunk.components(separatedBy: .newlines) {
                    if let stage = OCRProgressStage.fromWireLine(line) {
                        Task { @MainActor in
                            onStageChange?(stage)
                        }
                    }
                }
            }

            do {
                try process.run()
            } catch {
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                let url = URL(fileURLWithPath: imagePath)
                let fallback: String? = autoreleasepool {
                    let handler = VNImageRequestHandler(url: url, options: [:])
                    return self.executeRecognition(using: handler, onStageChange: onStageChange)
                }
                await onStageChange?(.reclaimingMemory)
                Self.reclaimProcessMemory()
                return fallback
            }

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            stderrPipe.fileHandleForReading.readabilityHandler = nil

            await onStageChange?(.reclaimingMemory)
            Self.reclaimProcessMemory()

            guard process.terminationStatus == 0 else { return nil }
            let output = String(data: stdoutData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return output.isEmpty ? nil : output
        }.value
    }

    private func executeRecognition(
        using handler: VNImageRequestHandler,
        onStageChange: (@Sendable @MainActor (OCRProgressStage) -> Void)? = nil
    ) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.usesLanguageCorrection = true

        if let onStageChange {
            Task { @MainActor in onStageChange(.recognizingText) }
        }
        do {
            try handler.perform([request])
            if let onStageChange {
                Task { @MainActor in onStageChange(.formattingLayout) }
            }
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

