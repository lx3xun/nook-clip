import AppKit
import SwiftUI

// MARK: - US6 代码卡片（等宽 + 语法高亮 + 行号）

@MainActor
struct CodePreviewCard: View {
    let text: String
    var forcedLanguage: String? = nil
    /// 语言 pill 展示名：来自 highlight.js 检测结果（异步更新）；
    /// 占位与检测失败回退已知语言规范名或 Code
    @State private var pillLanguage: String?

    /// 清洗外部传入的语言标识：过滤 "code"/"unknown" 占位值并转为规范展示名（如 "objc" → "Objective-C"）
    private var fallbackPillTitle: String {
        if let pillLanguage, !pillLanguage.isEmpty {
            return pillLanguage
        }
        if let raw = forcedLanguage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            let normalized = LanguageClassifier.normalize(raw)
            if normalized != "code" && normalized != "unknown" {
                return LanguageClassifier.displayName(for: normalized)
            }
        }
        return L10n.tr("preview.code_fallback")
    }

    /// 统一换行符（\r\n / \r → \n）后再按行切分，防止行尾残留 \r 破坏行号基线与统计
    static func normalizedLines(_ text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized.components(separatedBy: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                PillView(text: fallbackPillTitle, isAccent: true)
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 9)
            CodeBlockView(
                lines: Self.normalizedLines(text),
                forcedLanguage: forcedLanguage,
                onDetectedLanguage: { pillLanguage = $0 }
            )
        }
    }
}

// MARK: - 代码块（行号 + 语法高亮 · 可跨行选择复制 · 超长行横向滚动）

struct CodeBlockView: View {
    /// 超大文本降级：最多渲染 400 行（specs Edge：超大文本 UI 不卡死）。
    /// 400 行 × 19pt = 7600pt，@2x 下 15200px，低于图层纹理单边 16384px
    /// 上限（500 行会整体渲染空白，实测）
    static let maxLines = 400

    let lines: [String]
    /// 已知语言固定传入（JSON 卡片传 "json"），nil = highlight.js 自动检测
    var forcedLanguage: String? = nil
    /// 检测到语言名时回调（驱动语言 pill）；检测失败回调 nil
    var onDetectedLanguage: ((String?) -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // 内容/固定语言/明暗任一变化 → 内核身份重建（@State 归零、task 重跑），
        // 避免切换条目时旧高亮串叠在新文本上闪一帧
        CodeBlockContent(
            lines: lines,
            forcedLanguage: forcedLanguage,
            onDetectedLanguage: onDetectedLanguage,
            dark: colorScheme == .dark
        )
        .id(Identity(lines: lines, forcedLanguage: forcedLanguage, dark: colorScheme == .dark))
    }

    private struct Identity: Hashable {
        let lines: [String]
        let forcedLanguage: String?
        let dark: Bool
    }
}

/// 有状态内核：双阶段渲染——占位阶段同步用自研 SyntaxHighlighter 着色
/// （首帧不空），highlight.js 结果返回后无动画直接替换；失败/超时保持占位。
private struct CodeBlockContent: View {
    let lines: [String]
    let forcedLanguage: String?
    let onDetectedLanguage: ((String?) -> Void)?
    let dark: Bool

    @State private var highlighted: NSAttributedString?

    private var displayed: [String] {
        Array(lines.prefix(CodeBlockView.maxLines))
    }

    private var displayedText: String {
        displayed.joined(separator: "\n")
    }

    var body: some View {
        let cached = highlighted == nil
            ? CodeHighlightService.cachedOutcome(for: displayedText, forcedLanguage: forcedLanguage, dark: dark)
            : nil
        let activeAttributed = highlighted ?? cached?.attributed ?? SyntaxHighlighter.attributedText(displayed)

        VStack(alignment: .leading, spacing: 0) {
            // NSTextView 承载整段代码：原生选择可跨行拖选（旧实现逐行
            // Text + 容器 textSelection，选择被限制在单行内）。
            // 超长行不换行、不截断：横向平移读全文（触控板两指横滑/
            // shift+滚轮），两侧渐隐提示还有内容。
            // AppKit 文本布局 500 行仅数毫秒；缓存命中时首帧直接展示完整高亮，零闪烁。
            SelectableCodeText(attributed: activeAttributed)
            if lines.count > displayed.count {
                Text(L10n.tr("preview.code.truncated", String(displayed.count), String(lines.count)))
                    .font(.nookClipMono(10))
                    .foregroundStyle(NookClip.codeComment)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: NookClip.radiusCard, style: .continuous)
                .fill(NookClip.bgCode)
        }
        .task {
            // 缓存已命中时仅同步语言标签，免去二次异步跳帧
            if let hit = CodeHighlightService.cachedOutcome(
                for: displayedText,
                forcedLanguage: forcedLanguage,
                dark: dark
            ) {
                highlighted = hit.attributed
                onDetectedLanguage?(hit.languageName)
                return
            }
            let outcome = await CodeHighlightService.outcome(
                for: displayedText,
                forcedLanguage: forcedLanguage,
                dark: dark
            )
            guard !Task.isCancelled else { return }
            if let outcome {
                highlighted = outcome.attributed
                onDetectedLanguage?(outcome.languageName)
            } else {
                onDetectedLanguage?(nil)
            }
        }
    }
}

// MARK: - 可选择代码文本（固定行号列 + 手动横向平移 + 渐隐遮罩）

/// 行号列常量：行号宽 16 右对齐 + 10pt 间距 + 行高 19
/// （行高由 CodeTypography.paragraphStyle 的 minimumLineHeight 保证）
private enum CodeGutter {
    static let numberWidth: CGFloat = 16
    static let spacing: CGFloat = 10
    static var leadingInset: CGFloat { numberWidth + spacing }
    static let fadeWidth: CGFloat = 20

    /// 按行数位数动态加宽行号列：≥100 行时三位数行号超出固定 16pt
    /// 宽度，右对齐绘制会从负坐标起笔被裁掉。用最大位数数字 "8" 探宽
    /// （等宽字体），≤2 位数仍取 16pt，1–99 行布局不变。
    static func leadingInset(lineCount: Int) -> CGFloat {
        let digits = max(String(max(lineCount, 1)).count, 2)
        let probe = String(repeating: "8", count: digits) as NSString
        let width = probe.size(withAttributes: CodeTypography.baseAttributes).width
        return max(width, numberWidth) + spacing
    }
}

/// 行号列：固定在左侧（编辑器标准布局），枚举文本视图布局管理器的行片段
/// 逐行绘制行号——基线微调对齐代码基线，且不入文本存储，选择/复制结果只含代码本身。
/// 不参与命中测试。
final class CodeGutterOverlayView: NSView {
    weak var textView: NSTextView?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NookClip.nsBgCode.setFill()
        bounds.fill()
        guard let textView, let layoutManager = textView.layoutManager else { return }
        let storage = textView.string as NSString
        // 行起始字符索引（一次扫描；≤500 行开销可忽略）
        var lineStarts: [Int] = [0]
        for index in 0..<storage.length where storage.character(at: index) == 0x0A {
            lineStarts.append(index + 1)
        }
        var attributes = CodeTypography.baseAttributes
        attributes[.foregroundColor] = NookClip.nsCodeLineNumber
        let origin = textView.textContainerOrigin
        for (lineIndex, start) in lineStarts.enumerated() {
            // 末尾换行后的空行无字形：用布局管理器的额外行片段定位
            let fragmentRect: NSRect
            if start < storage.length {
                let glyphIndex = layoutManager.glyphIndexForCharacter(at: start)
                fragmentRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            } else if layoutManager.extraLineFragmentTextContainer != nil {
                fragmentRect = layoutManager.extraLineFragmentRect
            } else {
                continue
            }
            let number = "\(lineIndex + 1)" as NSString
            let size = number.size(withAttributes: attributes)
            // 文本与行号统一应用 baselineOffset: 1.0 垂直居中，直接与行片段对齐
            let point = NSPoint(
                x: bounds.width - CodeGutter.spacing - size.width,
                y: fragmentRect.minY + origin.y
            )
            number.draw(at: point, withAttributes: attributes)
        }
    }
}

/// 右侧边缘渐隐遮罩：向卡片底色渐隐，提示右侧还有内容（左侧无渐隐以免遮挡行首代码）。
/// 纯装饰，不挡事件
final class EdgeFadeView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        // 左透明 → 右底色
        let gradient = NSGradient(starting: NSColor.clear, ending: NookClip.nsBgCode)
        gradient?.draw(in: bounds, angle: 0)
    }
}

/// 鼠标悬浮整行高亮：按 19pt 行高整行铺悬浮底色（横跨行号列与代码区，
/// 编辑器标准行为）。纯装饰，不挡事件。
final class LineHighlightView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 当前悬浮行（0 起）；nil = 无悬浮
    var highlightRow: Int? {
        didSet {
            if highlightRow != oldValue { needsDisplay = true }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let row = highlightRow else { return }
        let lineHeight = CodeTypography.lineHeight
        let rect = NSRect(
            x: 0,
            y: CGFloat(row) * lineHeight,
            width: bounds.width,
            height: lineHeight
        )
        guard rect.intersects(bounds) else { return }
        NookClip.nsCodeLineHover.setFill()
        rect.fill()
    }
}

/// 自定义横向滚动视图：支持超宽横向滚动条；纵向滚轮直接驱动外层预览面板纵向滚动，
/// 绝不将纵向滚轮误转为横向平移（防止使用滚轮上下滚动时内容向左漂移）。
final class CodeScrollView: NSScrollView {
    var maxOffset: CGFloat {
        guard let tv = documentView as? NSTextView else { return 0 }
        return max(tv.frame.width - contentSize.width, 0)
    }

    private func findAncestorScrollView() -> NSScrollView? {
        var v = self.superview
        while let curr = v {
            if let sv = curr as? NSScrollView, sv !== self {
                return sv
            }
            v = curr.superview
        }
        return nil
    }

    override func scrollWheel(with event: NSEvent) {
        // 1. 明确的横向手势（触控板两指横向滑动）或按住 Shift + 滚轮 -> 代码横向滚动
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) || event.modifierFlags.contains(.shift) {
            if maxOffset > 0 {
                let dx = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
                let curX = documentVisibleRect.minX
                let delta = event.hasPreciseScrollingDeltas ? dx : dx * 24.0
                let targetX = min(max(curX - delta, 0), maxOffset)
                if targetX != curX {
                    contentView.scroll(to: NSPoint(x: targetX, y: 0))
                    reflectScrolledClipView(contentView)
                    return
                }
            }
            super.scrollWheel(with: event)
            return
        }

        // 2. 纵向手势与普通上下滚轮 -> 驱动外层预览面板纵向滚动，绝不发生横向漂移
        if let ancestor = findAncestorScrollView() {
            let cur = ancestor.documentVisibleRect.origin
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 24.0
            let maxScrollY = max((ancestor.documentView?.frame.height ?? 0) - ancestor.contentSize.height, 0)
            let targetY = min(max(cur.y - delta, 0), maxScrollY)
            ancestor.contentView.scroll(to: NSPoint(x: cur.x, y: targetY))
            ancestor.reflectScrolledClipView(ancestor.contentView)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }
}

/// 代码滚动容器：左侧固定行号列 + 右侧 CodeScrollView 承载文本视图。
/// 横向溢出时滚动条常驻在内容底部供操作；文本拖选跨出边界时支持平滑自动平移。
final class CodeScrollContainer: NSView {
    let textView: NSTextView
    let gutter = CodeGutterOverlayView()
    let scrollView = CodeScrollView()
    let trailingFade = EdgeFadeView()
    let lineHighlight = LineHighlightView()
    /// 行数决定行号列宽度（≥100 行三位数行号需要更宽的列）
    var lineCount: Int = 1 {
        didSet {
            guard lineCount != oldValue else { return }
            lineHighlight.highlightRow = nil
            needsLayout = true
        }
    }
    /// 横向文档宽度封顶：单行超长（压缩 JSON 等）不撑爆图层纹理
    private static let maxDocumentWidth: CGFloat = 8000

    override var isFlipped: Bool { true }

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = true

        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = false
        scrollView.documentView = textView

        addSubview(scrollView)
        gutter.textView = textView
        addSubview(gutter)
        addSubview(lineHighlight)

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScroll),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: 鼠标悬浮整行高亮

    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    private func updateHoverRow(at point: NSPoint) {
        // 容器翻转坐标 + 行高 19 固定：行号 = y / 行高
        let row = Int(floor(point.y / CodeTypography.lineHeight))
        lineHighlight.highlightRow = (0..<lineCount).contains(row) ? row : nil
    }

    override func mouseEntered(with event: NSEvent) {
        updateHoverRow(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoverRow(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        lineHighlight.highlightRow = nil
    }

    @objc private func handleScroll() {
        updateFade()
    }

    private func updateFade() {
        let maxScroll = max(textView.frame.width - scrollView.contentSize.width, 0)
        let curScroll = scrollView.documentVisibleRect.minX
        trailingFade.isHidden = maxScroll <= 1.0 || curScroll >= maxScroll - 1.0
    }

    /// 文本变化后同步文档尺寸
    func syncDocumentSize(resetScroll: Bool) {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        let contentWidth = scrollView.contentSize.width
        let hasOverflow = contentWidth > 0 && used.width > contentWidth + 1.0

        // 横向溢出时强制使用 legacy 样式常驻展示滚动条（overlay 样式会在指针静止时被系统淡出）；
        // 未溢出时不展示滚动条
        scrollView.hasHorizontalScroller = hasOverflow
        if hasOverflow {
            scrollView.scrollerStyle = .legacy
            scrollView.autohidesScrollers = false
            scrollView.horizontalScroller?.controlSize = .small
        }

        let width = min(max(used.width, contentWidth), Self.maxDocumentWidth)
        let height = max(used.height, scrollView.contentSize.height)
        textView.minSize = NSSize(width: width, height: height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        if resetScroll {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else {
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        gutter.needsDisplay = true
        updateFade()
    }

    override func layout() {
        super.layout()
        let gutterWidth = CodeGutter.leadingInset(lineCount: lineCount)
        gutter.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        scrollView.frame = NSRect(
            x: gutterWidth,
            y: 0,
            width: max(bounds.width - gutterWidth, 0),
            height: bounds.height
        )
        let fadeWidth = CodeGutter.fadeWidth
        lineHighlight.frame = bounds
        trailingFade.frame = NSRect(
            x: max(bounds.width - fadeWidth, gutterWidth),
            y: 0,
            width: fadeWidth,
            height: bounds.height
        )
        syncDocumentSize(resetScroll: false)
    }
}

struct SelectableCodeText: NSViewRepresentable {
    let attributed: NSAttributedString

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// 自定义 NSTextView：增强跨行拖选复制时的自动滚动支持
    final class SelectableCodeTextView: NSTextView {
        override func mouseDragged(with event: NSEvent) {
            super.mouseDragged(with: event)
            guard let sv = enclosingScrollView else { return }
            let loc = convert(event.locationInWindow, from: nil)
            let visible = sv.documentVisibleRect
            let maxScroll = max(frame.width - sv.contentSize.width, 0)
            if loc.x > visible.maxX - 15, maxScroll > 0 {
                let newX = min(visible.minX + 30.0, maxScroll)
                sv.contentView.scroll(to: NSPoint(x: newX, y: visible.minY))
                sv.reflectScrolledClipView(sv.contentView)
            } else if loc.x < visible.minX + 15, visible.minX > 0 {
                let newX = max(visible.minX - 30.0, 0)
                sv.contentView.scroll(to: NSPoint(x: newX, y: visible.minY))
                sv.reflectScrolledClipView(sv.contentView)
            }
        }

        override func copy(_ sender: Any?) {
            defer {
                NotificationCenter.default.post(name: .restoreKeyboardFocus, object: nil)
            }
            guard selectedRange.length > 0,
                  NSMaxRange(selectedRange) <= (string as NSString).length else { return }
            let selected = (string as NSString).substring(with: selectedRange)
            let pasteboard = PasteboardAccess.general
            pasteboard.clearContents()
            pasteboard.setString(selected, forType: .string)
        }
    }

    func makeNSView(context: Context) -> NSView {
        let textView = SelectableCodeTextView()
        configure(textView)
        textView.textStorage?.setAttributedString(attributed)
        let container = CodeScrollContainer(textView: textView)
        container.lineCount = Self.lineCount(of: attributed)
        container.syncDocumentSize(resetScroll: true)
        context.coordinator.container = container
        context.coordinator.lastText = attributed
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let container = context.coordinator.container else { return }
        guard context.coordinator.lastText != attributed else { return }
        context.coordinator.lastText = attributed
        container.textView.textStorage?.setAttributedString(attributed)
        container.lineCount = Self.lineCount(of: attributed)
        container.syncDocumentSize(resetScroll: true)
    }

    private static func lineCount(of attributed: NSAttributedString) -> Int {
        max(attributed.string.components(separatedBy: "\n").count, 1)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        guard let textView = context.coordinator.container?.textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return nil }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        let inset = textView.textContainerInset
        let gutterInset = CodeGutter.leadingInset(lineCount: Self.lineCount(of: attributed))
        let width = proposal.width ?? used.width + inset.width * 2 + gutterInset
        let hasOverflow = (proposal.width ?? 0) > 0 && (used.width + gutterInset > proposal.width!)
        let scrollerPadding: CGFloat = hasOverflow ? 14 : 0
        let height = used.height + inset.height * 2 + scrollerPadding
        return CGSize(width: max(width, 1), height: max(height, 1))
    }

    private func configure(_ textView: NSTextView) {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        // 不换行：一行代码 = 一个视觉行，行号才能对齐；超宽横向平移
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = []
    }

    final class Coordinator {
        var container: CodeScrollContainer?
        var lastText: NSAttributedString?
    }
}

