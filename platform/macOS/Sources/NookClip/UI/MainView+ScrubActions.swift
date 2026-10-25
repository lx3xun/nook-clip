import AppKit
import SwiftUI

// MARK: - 三大效率动作的视图层实现（specs/012 US1/US2/US3）
//
// 这一层只做「状态路由」：从当前选择态取出条目、调用对应的服务、把结果反馈
// 呈现给用户。真正的算法（脱敏/还原）在 Rust 核心，窗口管理在
// PasteStackController / PinnedWindowManager。拆成独立文件是为了让
// MainView.swift（已 1100+ 行）不再膨胀，也与 MainView+Keyboard /
// MainView+Category 的既有拆分惯例一致。

extension MainView {

    // MARK: - ⌃⏎ 脱敏粘贴（US1）

    /// 把选中条目做语义占位符脱敏后粘贴。
    ///
    /// 关键决策：**先脱敏、再写入剪贴板**。绝不把明文短暂写进系统剪贴板，
    /// 否则任何剪贴板监听工具都能在 5ms 窗口内抓到真实密钥
    /// （product-competitiveness-architecture.md 安全红线）。
    func scrubPasteSelected() {
        guard !isBatchMode, let id = selectionCoordinator.selectedID else {
            // 多选态的批量脱敏不在本期范围：明确告知而非静默失败
            showScrubFeedback(L10n.tr("scrub.action.single_only"))
            return
        }
        guard let item = store.item(withID: id) else { return }

        // 文件/图片条目没有可脱敏的文本，明确提示而不是让按键无反应
        guard item.type == .text || item.type == .url else {
            showScrubFeedback(L10n.tr("scrub.action.text_only"))
            return
        }

        // 敏感条目要走解密路径；解密失败则降级用 summary（绝不粘贴掩码串）
        let plainText: String
        switch item.revealPlainContentResult() {
        case .success(let text):
            plainText = text
        case .failure:
            showScrubFeedback(L10n.tr("scrub.action.reveal_failed"))
            return
        }

        guard !plainText.isEmpty else { return }

        let service = ScrubService.shared
        let outcome = service.scrub(plainText)

        // 没命中任何敏感项：仍然粘贴原文，但明确告知「本条目无需脱敏」，
        // 避免用户以为 ⌃⏎ 失效（透明反馈优先于静默）
        guard outcome.hasReplacements else {
            showScrubFeedback(L10n.tr("scrub.result.none"))
            pasteTextDirectly(plainText, containsSensitive: item.isSensitive)
            return
        }

        store.markUsed(id)
        pasteTextDirectly(outcome.scrubbedText, containsSensitive: false)
        showScrubFeedback(outcome.localizedSummary)
    }

    // MARK: - ⌃⇧⏎ 还原粘贴（US1 反向）

    /// 把当前剪贴板文本里的占位符还原成真实值再粘贴。
    ///
    /// 典型场景：AI 聊天框返回了带 `<EMAIL_1>` 的代码/文案，用户按 ⌃⇧⏎
    /// 直接粘贴还原后的版本，不需要手工逐个替换。
    func restoreScrubPaste() {
        let pasteboardText = PasteboardAccess.general.string(forType: .string) ?? ""
        guard !pasteboardText.isEmpty else { return }

        let outcome = ScrubService.shared.restore(pasteboardText)

        // 没有可还原的占位符：回退成普通粘贴（用户按错了不该毫无反应）
        guard outcome.restoredCount > 0 else {
            showScrubFeedback(L10n.tr("scrub.restore.none"))
            pasteCurrentClipboard()
            return
        }

        // 还原后的文本含真实敏感值：必须以 containsSensitive 写入，
        // 让 PasteService 打上 transient/concealed 标记并调度 30s 自毁
        pasteTextDirectly(outcome.restoredText, containsSensitive: true)
        showScrubFeedback(L10n.tr("scrub.restore.summary", String(outcome.restoredCount)))
    }

    /// 脱敏/还原的统一粘贴出口：写入剪贴板 → 模拟 ⌘V → 关面板。
    private func pasteTextDirectly(_ text: String, containsSensitive: Bool) {
        onClose()
        _ = clipboardWriter.pasteText(
            text,
            targetApplication: getTargetApplication(),
            containsSensitive: containsSensitive
        )
    }

    /// 把剪贴板当前内容原样再贴一次（⌃⇧⏎ 无占位符时的回退路径）
    private func pasteCurrentClipboard() {
        guard let text = PasteboardAccess.general.string(forType: .string) else { return }
        pasteTextDirectly(text, containsSensitive: false)
    }

    // MARK: - ⌥⏎ 顺序粘贴栈（US2）

    /// 多选态启动顺序粘贴栈；单选态返回 false 让分发表回落成普通纯文本粘贴。
    ///
    /// - Returns: 是否消费了本次按键
    @discardableResult
    func startPasteStackFromSelection() -> Bool {
        guard isBatchMode else { return false }

        let selectedIDs = selectionCoordinator.selectionIDs
        guard selectedIDs.count >= 2 else { return false }

        // 取条目本身，然后按「复制先后」排 —— **刻意不用列表显示序**。
        // 列表按 `lastUsedAt` 倒序（刚复制的排最上），照搬会把顺序整个翻过来：
        // 依次复制 A、B、C 后多选启动，用户期待 A → B → C，实际却贴 C → B → A。
        // 「顺序粘贴」的全部价值就是「照我复制的顺序来」，排序统一由
        // `PasteStackQueue.inCopyOrder` 负责（那里有确定性与理由的完整注释）。
        let selected = selectedIDs.compactMap { store.item(withID: $0) }
        guard selected.count >= 2 else { return false }

        // 敏感条目无法解密时跳过（绝不把掩码串塞进粘贴栈）
        let usable = PasteStackQueue.inCopyOrder(
            selected.filter { !$0.isSensitive || $0.revealPlainContentResult().isSuccess }
        )
        guard !usable.isEmpty else { return false }

        onClose()
        PasteStackController.shared.start(with: usable)
        return true
    }

    // MARK: - ⌘P 钉在屏幕（US3）

    /// 把选中条目钉成屏幕贴条。
    func pinSelectedToScreen() {
        guard !isBatchMode, let id = selectionCoordinator.selectedID else {
            showScrubFeedback(L10n.tr("pin.action.single_only"))
            return
        }
        guard let item = store.item(withID: id) else { return }

        guard !PinnedWindowManager.shared.isAtCapacity else {
            showScrubFeedback(L10n.tr("pin.limit_reached", String(PinnedWindowManager.maxPinnedNotes)))
            return
        }

        onClose()
        PinnedWindowManager.shared.pin(item: item)
    }

    // MARK: - 轻量反馈（toast，2 秒自动消失）

    /// 展示一条短暂的动作反馈。
    /// 用独立 @State 而非复用 staleFileMessage：后者绑定 alert（阻断式），
    /// 而脱敏/还原多为成功反馈，用非阻断的 toast 更合适。
    func showScrubFeedback(_ message: String) {
        scrubFeedbackMessage = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if scrubFeedbackMessage == message {
                scrubFeedbackMessage = nil
            }
        }
    }
}

// MARK: - Result 便利

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
