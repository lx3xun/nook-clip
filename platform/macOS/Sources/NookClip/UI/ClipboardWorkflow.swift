import AppKit
import Foundation

/// 粘贴用户流程：单条粘贴与批量合并粘贴。
/// 职责：条目获取、文件载荷有效性检查、终端安全护栏、剪贴板写入（经 ClipboardWriter）、
/// 单条成功后 markUsed、敏感批量粘贴标记。面板关闭等宿主动作经 closePanel 回调，
/// 由 View 决定（keepOpen 意图）。
@MainActor
final class ClipboardWorkflow {
    private let store: InMemoryHistoryStore
    private let clipboardWriter: any ClipboardWriter
    /// 终端护栏的确认弹窗出口（测试可注入，避免跑真模态框）
    private let confirmTerminalPaste: (TerminalPasteAssessment) -> TerminalPasteConfirmChoice
    /// 终端护栏总开关的读取口（测试可注入；默认读用户偏好，缺省开启）
    private let isTerminalGuardEnabled: () -> Bool
    /// 是否同时保护编辑器与 AI 工具内置终端（测试可注入；默认读用户偏好，缺省开启）
    private let isIdeTerminalGuardEnabled: () -> Bool
    /// 从目标应用取 Bundle ID 的读取口。`NSRunningApplication` 无法在测试里构造，
    /// 单测只能靠这条缝把「目标是 Terminal」这件事喂进来。
    private let bundleIdProvider: (NSRunningApplication?) -> String?
    /// 从目标应用取本地化名称的读取口（未登记 Bundle ID 的终端靠名称关键词兜底）。
    private let appNameProvider: (NSRunningApplication?) -> String?

    init(
        store: InMemoryHistoryStore,
        clipboardWriter: any ClipboardWriter,
        confirmTerminalPaste: ((TerminalPasteAssessment) -> TerminalPasteConfirmChoice)? = nil,
        isTerminalGuardEnabled: @escaping () -> Bool = { TerminalPasteGuard.isEnabled },
        isIdeTerminalGuardEnabled: @escaping () -> Bool = { TerminalPasteGuard.isIdeEnabled },
        bundleIdProvider: @escaping (NSRunningApplication?) -> String? = { $0?.bundleIdentifier },
        appNameProvider: @escaping (NSRunningApplication?) -> String? = { $0?.localizedName }
    ) {
        self.store = store
        self.clipboardWriter = clipboardWriter
        // 默认实现在 init 里绑定：init 是 @MainActor，而默认参数表达式不在主 actor 上下文，
        // 直接写成默认值会触发「跨 actor 同步调用」编译错误
        self.confirmTerminalPaste = confirmTerminalPaste ?? { TerminalPasteConfirm.present($0) }
        self.isTerminalGuardEnabled = isTerminalGuardEnabled
        self.isIdeTerminalGuardEnabled = isIdeTerminalGuardEnabled
        self.bundleIdProvider = bundleIdProvider
        self.appNameProvider = appNameProvider
    }

    // MARK: - 单条粘贴

    enum SinglePasteOutcome: Equatable {
        case pasted
        /// 文件条目引用失效（原文件被移动/删除或卷未挂载）：不关面板、不计使用次数
        case staleFile(message: String)
        /// 条目不存在（已被删除等）
        case itemMissing
        /// 已按「安全粘贴」写入（终端护栏静默档去掉了末尾回车）：面板已关，附一句轻提示
        case pastedWithNote(message: String)
        /// 用户在终端确认弹窗里取消：面板保持打开，什么都没做
        case cancelled
    }

    /// 单条粘贴。写入成功路径：关面板（可选）→ markUsed → 写入剪贴板；
    /// 敏感项自毁逻辑在 ClipboardWriter.copyOnly 内（30 秒自动清空剪贴板）。
    ///
    /// 目标应用是终端时先过一遍护栏（`TerminalPasteGuard`）：
    /// 单行带末尾回车 → 静默削掉再粘；多行或高危 → 先弹窗确认。
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

        // 终端护栏：只有文本/链接条目可能是一条命令，图片与文件不参与判定
        switch terminalDecision(for: item, targetApplication: targetApplication) {
        case .passthrough:
            break
        case .silentStrip(let assessment):
            closeOrPreserve(closePanel)
            store.markUsed(id)
            _ = clipboardWriter.pasteText(
                assessment.pasteText,
                targetApplication: targetApplication,
                containsSensitive: item.isSensitive
            )
            return .pastedWithNote(message: L10n.tr("terminal.toast.stripped"))
        case .confirm(let assessment):
            switch confirmTerminalPaste(assessment) {
            case .cancel:
                return .cancelled
            case .safe:
                closeOrPreserve(closePanel)
                store.markUsed(id)
                _ = clipboardWriter.pasteText(
                    assessment.pasteText,
                    targetApplication: targetApplication,
                    containsSensitive: item.isSensitive
                )
                return .pastedWithNote(message: L10n.tr("terminal.toast.safe_paste"))
            case .raw:
                // 用户明确选择原样粘贴：走完原有完整路径（保留富文本等载荷）
                break
            }
        }

        closeOrPreserve(closePanel)
        store.markUsed(id)
        _ = clipboardWriter.paste(item, targetApplication: targetApplication, plainTextOnly: plainTextOnly)
        return .pasted
    }

    /// 关面板；未提供 closePanel 时按既有约定发「保持窗口」通知。
    private func closeOrPreserve(_ closePanel: (() -> Void)?) {
        if let closePanel {
            closePanel()
        } else {
            NotificationCenter.default.post(name: .quickPopoverPreserveWindow, object: nil)
        }
    }

    /// 取条目明文并交给护栏判定。非文本条目、开关关闭、拿不到目标应用一律放行。
    private func terminalDecision(
        for item: ClipboardItem,
        targetApplication: NSRunningApplication?
    ) -> TerminalPasteDecision {
        guard isTerminalGuardEnabled() else { return .passthrough }
        guard item.type == .text || item.type == .url else { return .passthrough }
        let bundleId = bundleIdProvider(targetApplication)
        let appName = appNameProvider(targetApplication)
        guard (bundleId != nil && !(bundleId?.isEmpty ?? true))
            || (appName != nil && !(appName?.isEmpty ?? true)) else {
            return .passthrough
        }
        // 敏感条目解密失败时放弃判定：宁可走原有路径，也不把掩码当命令分析
        guard case .success(let plainText) = item.revealPlainContentResult(), !plainText.isEmpty else {
            return .passthrough
        }
        return TerminalPasteGuard.decide(
            bundleId: bundleId,
            appName: appName,
            includeIdeTerminals: isIdeTerminalGuardEnabled(),
            text: plainText
        )
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
    ///
    /// 目标应用是终端时必须过护栏：多条合并天然是多行，粘进终端会逐行执行——
    /// 这正是护栏要挡的经典事故，不能因为「批量」就绕过去。
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

        var textToPaste = combined
        let bundleId = bundleIdProvider(targetApplication)
        let appName = appNameProvider(targetApplication)
        if isTerminalGuardEnabled(),
           (bundleId != nil && !(bundleId?.isEmpty ?? true)) || (appName != nil && !(appName?.isEmpty ?? true)) {
            switch TerminalPasteGuard.decide(
                bundleId: bundleId,
                appName: appName,
                includeIdeTerminals: isIdeTerminalGuardEnabled(),
                text: combined
            ) {
            case .passthrough:
                break
            case .silentStrip(let assessment):
                // 批量内容理论上不少于两行，静默档不会命中；保留分支以免将来放宽时漏处理
                textToPaste = assessment.pasteText
            case .confirm(let assessment):
                switch confirmTerminalPaste(assessment) {
                case .cancel:
                    return false
                case .safe:
                    textToPaste = assessment.pasteText
                case .raw:
                    textToPaste = combined
                }
            }
        }

        closeOrPreserve(closePanel)
        _ = clipboardWriter.pasteText(textToPaste, targetApplication: targetApplication, containsSensitive: containsSensitive)
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
