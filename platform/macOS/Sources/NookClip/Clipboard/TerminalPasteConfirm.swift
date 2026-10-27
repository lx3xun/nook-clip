import AppKit

// MARK: - 终端安全粘贴确认弹窗（P0）
//
// 用系统 `NSAlert` 而不是自绘 SwiftUI 浮层，原因是这一档交互的本质是
// **打断**：它要在用户误触之前抢到注意力，并且必须支持「回车 = 安全粘贴 /
// Esc = 取消」这套用户已经肌肉记忆的键盘语义。自绘窗口要自己处理键盘焦点、
// 与主面板的层级关系、读屏语义，收益只是外观统一，风险却大得多。
//
// 内容区用等宽字体展示真实将要粘贴的文本（而不是缩略摘要）：用户判断
// 「这行 rm -rf 到底删的是哪」靠的就是这个路径，抹掉就等于没拦。

/// 用户在确认弹窗里的选择。
enum TerminalPasteConfirmChoice {
    /// 安全粘贴：多行压成一行填进输入行，用户自己按回车才执行
    case safe
    /// 原样粘贴：明确知道风险，仍按原文粘贴
    case raw
    /// 取消：什么都不做，保留面板现场
    case cancel
}

enum TerminalPasteConfirm {
    /// 弹出阻断式确认，返回用户的选择。
    ///
    /// 必须在主线程调用；调用方应保证此时主面板已经收起，避免两个窗口抢焦点。
    @MainActor
    static func present(_ assessment: TerminalPasteAssessment) -> TerminalPasteConfirmChoice {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("terminal.confirm.title")
        alert.informativeText = assessment.localizedSummary

        let preview = makePreview(assessment.safeText)
        // accessoryView 的尺寸由我们给定，NSAlert 不会自动测量
        preview.frame = NSRect(x: 0, y: 0, width: 420, height: 132)
        alert.accessoryView = preview

        alert.addButton(withTitle: L10n.tr("terminal.confirm.safe"))
        alert.addButton(withTitle: L10n.tr("terminal.confirm.raw"))
        alert.addButton(withTitle: L10n.tr("terminal.confirm.cancel"))

        // 首键 = 安全粘贴：用户手感上「回车确认」不该等于直接执行命令
        alert.buttons.first?.keyEquivalent = "\r"
        if alert.buttons.count >= 3 {
            alert.buttons[2].keyEquivalent = "\u{1b}"
        }

        // 确保弹窗层级高于主面板（.floating）与顺序粘贴栈胶囊，不被悬浮窗口遮挡
        alert.window.level = .modalPanel

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .safe
        case .alertSecondButtonReturn:
            return .raw
        default:
            return .cancel
        }
    }

    /// 只读等宽预览：高亮危险片段成本很高、误报也更吓人，
    /// 这里只保证「看得到、看得清」——不染色、不加粗。
    private static func makePreview(_ text: String) -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.string = text
        textView.textContainerInset = NSSize(width: 6, height: 6)
        // 横向不换行：命令被折行后更容易看漏后半段（`rm -rf /` 可能被折到下一行）
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]

        scroll.documentView = textView
        return scroll
    }
}
