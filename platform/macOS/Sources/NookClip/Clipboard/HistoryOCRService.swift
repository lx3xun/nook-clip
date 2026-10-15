import Foundation
import OSLog

/// OCR 识别与回写执行器：
/// 读取图片载荷 → 手动识别 → 敏感检测掩码（审计 BUG-007）→
/// 单事务回写数据库（含 FTS 索引行替换）。
/// 不持有内存镜像：提交成功后返回掩码文本，由调用方（Store）刷新内存副本并发布 dataVersion。
@MainActor
final class HistoryOCRService {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.lx3xun.nookclip", category: "HistoryOCRService")

    private let rustStore: RustHistoryStore
    private let ocrEngine: OCREngine

    init(rustStore: RustHistoryStore, ocrEngine: OCREngine = .shared) {
        self.rustStore = rustStore
        self.ocrEngine = ocrEngine
    }

    /// 手动主动触发 OCR 识别（前台用户操作）：
    /// 无论识别成功与否，completion 必定回调一次——
    /// 识别到文字回传文本；图片不可读或识别不到文字（纯色图等）回传 nil。
    /// 调用方依赖此回调复位 UI 扫描状态，不得静默丢弃。
    func performManualOCR(for item: ClipboardItem, completion: @escaping @MainActor (_ text: String?, _ id: UUID) -> Void) {
        guard item.type == .image, let path = item.payloadPath else {
            completion(nil, item.id)
            return
        }
        let itemId = item.id
        Task.detached(priority: .userInitiated) {
            let recognized = await self.ocrEngine.recognizeText(from: path)
            await MainActor.run {
                completion(recognized, itemId)
            }
        }
    }


    /// OCR 回写（原 HistoryStore.updateOCRText 的库内直写路径收编至此）：
    /// 敏感检测掩码 → 单事务更新 clips 行与 FTS 索引行。
    /// 返回落库的掩码文本；空文本或事务失败返回 nil（内存保持原状态）。
    @discardableResult
    func updateOCRText(_ text: String, for id: UUID) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // OCR 识别文本先过敏感检测：截图中的 API Key/私钥不得明文落库、
        // 入 FTS 索引或上传 iCloud——命中则仅存掩码文本（可安全同步与检索，
        // 审计 BUG-007）
        let storable = SensitiveDataDetector.detect(text: trimmed)?.maskedText ?? trimmed
        guard rustStore.updateOCR(id: id, ocrText: storable) else {
            return nil
        }
        return storable
    }
}
