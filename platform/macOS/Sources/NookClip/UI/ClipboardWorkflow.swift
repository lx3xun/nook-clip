import AppKit
import Foundation

/// 粘贴用户流程：单条粘贴与批量合并粘贴。
/// 职责：条目获取、文件载荷有效性检查、剪贴板写入（经 ClipboardWriter）、
/// 单条成功后 markUsed、敏感批量粘贴标记。面板关闭等宿主动作经 closePanel 回调，
/// 由 View 决定（keepOpen 意图）。
@MainActor
final class ClipboardWorkflow {
    private let store: InMemoryHistoryStore
    private let clipboardWriter: any ClipboardWriter

    init(store: InMemoryHistoryStore, clipboardWriter: any ClipboardWriter) {
        self.store = store
        self.clipboardWriter = clipboardWriter
    }

    // MARK: - 单条粘贴

    enum SinglePasteOutcome: Equatable {
        case pasted
        /// 文件条目引用失效（原文件被移动/删除或卷未挂载）：不关面板、不计使用次数
        case staleFile(message: String)
        /// 条目不存在（已被删除等）
        case itemMissing
    }

    /// 单条粘贴。写入成功路径：关面板（可选）→ markUsed → 写入剪贴板；
    /// 敏感项自毁逻辑在 ClipboardWriter.copyOnly 内（30 秒自动清空剪贴板）。
    func pasteSingle(
        id: UUID,
        targetApplication: NSRunningApplication?,
        plainTextOnly: Bool,
        closePanel: (() -> Void)? = nil
    ) -> SinglePasteOutcome {
        guard let item = store.item(withID: id) else { return .itemMissing }
        // 文件条目先校验：失效引用不关面板、不计使用次数，明确提示后保留现场
        if let message = clipboardWriter.staleFileMessage(for: item) {
            return .staleFile(message: message)
        }
        if let closePanel {
            closePanel()
        } else {
            NotificationCenter.default.post(name: .quickPopoverPreserveWindow, object: nil)
        }
        store.markUsed(id)
        _ = clipboardWriter.paste(item, targetApplication: targetApplication, plainTextOnly: plainTextOnly)
        return .pasted
    }

    /// 单条仅拷贝（⌘C / 右键菜单「拷贝」）。写入剪贴板但不执行前台粘贴动作，写入后关面板
    func copySingle(
        id: UUID,
        plainTextOnly: Bool = false,
        closePanel: (() -> Void)? = nil
    ) -> SinglePasteOutcome {
        guard let item = store.item(withID: id) else { return .itemMissing }
        if let message = clipboardWriter.staleFileMessage(for: item) {
            return .staleFile(message: message)
        }
        closePanel?()
        store.markUsed(id)
        _ = clipboardWriter.copyOnly(item, plainTextOnly: plainTextOnly)
        return .pasted
    }

    // MARK: - 批量合并粘贴

    struct BatchEntry {
        let id: UUID
        /// 条目已删除/解密失败时的文本回退
        let summary: String
        let isSensitive: Bool
    }

    /// 批量合并粘贴：按列表显示顺序以 \n 连接（BatchPaste.joinTexts）。
    /// 合并文本含敏感明文时透传标记：剪贴板写入遮蔽标记并调度 30s 自毁，
    /// 与单条敏感粘贴同等保护（审计 BUG-052）。
    /// 注意：批量合并粘贴不调用 markUsed，保持被合并条目的原始记录时间与列表顺序。
    @discardableResult
    func pasteBatch(
        entries: [BatchEntry],
        targetApplication: NSRunningApplication?,
        closePanel: (() -> Void)? = nil
    ) -> Bool {
        guard !entries.isEmpty else { return false }
        guard let valid = resolveBatchEntries(entries) else { return false }
        let combined = BatchPaste.joinTexts(valid.map(\.text))
        let containsSensitive = valid.contains { $0.isSensitive }
        if let closePanel {
            closePanel()
        } else {
            NotificationCenter.default.post(name: .quickPopoverPreserveWindow, object: nil)
        }
        _ = clipboardWriter.pasteText(combined, targetApplication: targetApplication, containsSensitive: containsSensitive)
        return true
    }

    /// 批量合并拷贝（⌘C）：按列表顺序以 \n 连接写入系统剪贴板，不粘贴。
    /// 注意：批量合并拷贝不调用 markUsed，保持被合并条目的原始记录时间与列表顺序。
    @discardableResult
    func copyBatch(
        entries: [BatchEntry],
        closePanel: (() -> Void)? = nil
    ) -> Bool {
        guard !entries.isEmpty else { return false }
        guard let valid = resolveBatchEntries(entries) else { return false }
        let combined = BatchPaste.joinTexts(valid.map(\.text))
        let containsSensitive = valid.contains { $0.isSensitive }
        closePanel?()
        _ = clipboardWriter.copyText(combined, containsSensitive: containsSensitive)
        return true
    }

    /// 批量条目文本解析（pasteBatch/copyBatch 共用）：
    /// - 全文契约：非敏感条目的 revealPlainContent 恒为 nil，须取 item.summary
    ///   （item(withID:) 已按需取回全文；entry.summary 是行模型的截断前缀）
    /// - 条目已删除时回退 entry.summary；
    /// - 敏感条目解密失败时【跳过该条】（不写入、不粘贴、不计使用次数），
    ///   对齐单条路径 PasteService.copyOnly 的拒绝策略——绝不能把掩码写进剪贴板
    /// - 全部条目被跳过时返回 nil（调用方不动作）
    private func resolveBatchEntries(_ entries: [BatchEntry]) -> [(id: UUID, text: String, isSensitive: Bool)]? {
        var resolved: [(id: UUID, text: String, isSensitive: Bool)] = []
        resolved.reserveCapacity(entries.count)
        for entry in entries {
            guard let item = store.item(withID: entry.id) else {
                resolved.append((entry.id, entry.summary, entry.isSensitive))
                continue
            }
            if item.isSensitive {
                guard let plain = item.revealPlainContent() else { continue }
                resolved.append((entry.id, plain, true))
            } else if item.type == .image {
                let text = (item.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                    ?? item.fallbackDisplayTitle
                resolved.append((entry.id, text, false))
            } else {
                resolved.append((entry.id, item.summary, false))
            }
        }
        return resolved.isEmpty ? nil : resolved
    }
}
