import AppKit
import SwiftUI

// MARK: - 智能表单拆解悬浮提示（非阻断胶囊 Toast）

@MainActor
final class FormBurstToastController {
    static let shared = FormBurstToastController()

    private var panel: FormBurstToastPanel?
    private var dismissWorkItem: DispatchWorkItem?

    private init() {}

    func suggest(for text: String) {
        // 如果开关关闭，不弹窗
        let enabled = UserDefaults.standard.object(forKey: UserDefaultsKey.formBurstAutoSuggestEnabled.rawValue) as? Bool ?? true
        guard enabled else { return }

        // 如果已经在顺序粘贴栈运行中，不重复打扰
        if PasteStackController.shared.isRecording || PasteStackController.shared.isActive {
            return
        }

        let pieces = burstFormText(text: text)
        guard pieces.count >= 2 else { return }

        let rawKind = detectFormBurstKind(text: text)
        let kindTitle = Self.formatKindTitle(rawKind)

        dismissWorkItem?.cancel()
        dismissWorkItem = nil

        let panel = self.panel ?? FormBurstToastPanel()
        self.panel = panel

        panel.configure(
            text: text,
            count: pieces.count,
            kindTitle: kindTitle,
            onBurst: { [weak self] in
                self?.dismiss()
                let now = Date()
                let burstItems = pieces.enumerated().map { index, piece in
                    ClipboardItem(
                        id: UUID(),
                        type: .text,
                        title: piece,
                        summary: piece,
                        createdAt: now.addingTimeInterval(TimeInterval(index))
                    )
                }
                PasteStackController.shared.start(with: burstItems)
            },
            onClose: { [weak self] in
                self?.dismiss()
            },
            onHoverChanged: { [weak self] isHovered in
                if isHovered {
                    self?.pauseDismiss()
                } else {
                    self?.resumeDismiss(delay: 3.0)
                }
            }
        )

        panel.show()
        scheduleDismiss(delay: 3.0)
    }

    func scheduleDismiss(delay: TimeInterval = 3.0) {
        dismissWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func pauseDismiss() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
    }

    func resumeDismiss(delay: TimeInterval = 3.0) {
        scheduleDismiss(delay: delay)
    }

    func dismiss() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        panel?.hide()
    }

    private static func formatKindTitle(_ kind: String) -> String {
        switch kind {
        case "table":
            return L10n.tr("form_burst.kind.table")
        case "contact":
            return L10n.tr("form_burst.kind.contact")
        case "json":
            return L10n.tr("form_burst.kind.json")
        case "key_value":
            return L10n.tr("form_burst.kind.key_value")
        case "list":
            return L10n.tr("form_burst.kind.list")
        default:
            return L10n.tr("form_burst.kind.default")
        }
    }
}

// MARK: - 悬浮面板实体

@MainActor
final class FormBurstToastPanel: NSPanel {
    private var onBurst: (() -> Void)?
    private var onClose: (() -> Void)?
    private var keyMonitor: Any?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 350, height: 44),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        // 无边框 + 透明背景：四角圆角由 SwiftUI 渲染，投影由系统根据真实 alpha 轮廓在窗口外生成
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        isMovableByWindowBackground = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func configure(
        text: String,
        count: Int,
        kindTitle: String,
        onBurst: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onHoverChanged: @escaping (Bool) -> Void
    ) {
        self.onBurst = onBurst
        self.onClose = onClose

        let view = FormBurstToastView(
            count: count,
            kindTitle: kindTitle,
            onBurst: onBurst,
            onClose: onClose,
            onHoverChanged: onHoverChanged
        )

        let hostingView = NSHostingView(rootView: view)
        hostingView.autoresizingMask = [.width, .height]
        contentView = hostingView
        invalidateShadow()
    }

    func show() {
        installKeyMonitor()
        positionNearMouse()
        invalidateShadow()
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            animator().alphaValue = 1
        }
    }

    func hide() {
        removeKeyMonitor()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
        })
    }

    /// 定位在鼠标指针（即复制操作处）附近，带多屏与屏幕边缘智能翻转避让
    private func positionNearMouse() {
        let mouseLocation = NSEvent.mouseLocation
        let activeScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first

        guard let screen = activeScreen else { return }
        let visible = screen.visibleFrame
        let panelWidth: CGFloat = 350
        let panelHeight: CGFloat = 44

        // 默认显示在鼠标右下方，偏移 12pt 避免遮挡光标指针
        var targetX = mouseLocation.x + 12
        var targetY = mouseLocation.y - panelHeight - 12

        // 若靠右超出屏幕边界，翻转到鼠标左侧
        if targetX + panelWidth > visible.maxX - 12 {
            targetX = mouseLocation.x - panelWidth - 12
        }

        // 若靠下超出屏幕边界，翻转到鼠标上方
        if targetY < visible.minY + 12 {
            targetY = mouseLocation.y + 20
        }

        // 兜底夹取，确保窗口始终完整落在屏幕可视区域内
        targetX = max(visible.minX + 12, min(targetX, visible.maxX - panelWidth - 12))
        targetY = max(visible.minY + 12, min(targetY, visible.maxY - panelHeight - 12))

        setFrame(NSRect(x: targetX, y: targetY, width: panelWidth, height: panelHeight), display: true)
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        // 监听全局 Option+Enter 快捷激活
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == [.option] && event.keyCode == 36 { // 36 = Return
                self.onBurst?()
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}

// MARK: - SwiftUI 胶囊视图

private struct FormBurstToastView: View {
    let count: Int
    let kindTitle: String
    let onBurst: () -> Void
    let onClose: () -> Void
    let onHoverChanged: (Bool) -> Void

    @State private var isBurstHovered = false
    @State private var isCloseHovered = false

    var body: some View {
        HStack(spacing: 8) {
            // NookClip 产品官方标识
            AppBranding.iconView(size: 20)

            HStack(spacing: 4) {
                Text("NookClip")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(NookClip.accent)
                Text("·")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(NookClip.textTertiary)
                Text(L10n.tr("form_burst.toast.summary", kindTitle, count))
                    .font(.nookClipMetaMedium)
                    .foregroundStyle(NookClip.textPrimary)
            }
            .lineLimit(1)

            Spacer(minLength: 4)

            // 连续填表主按钮
            Button(action: onBurst) {
                HStack(spacing: 4) {
                    Text(L10n.tr("form_burst.toast.action"))
                        .font(.nookClipMetaMedium)
                    KbdView(text: "⌥⏎", fontSize: 9)
                }
                .foregroundStyle(isBurstHovered ? Color.white : NookClip.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isBurstHovered ? NookClip.accent : NookClip.accent.opacity(0.15))
                }
            }
            .buttonStyle(.plain)
            .onHover { isBurstHovered = $0 }

            // 关闭按钮
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(isCloseHovered ? NookClip.textPrimary : NookClip.textTertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isCloseHovered = $0 }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 44)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(NookClip.bgPopover)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(NookClip.separator, lineWidth: 0.5)
                }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { isHovered in
            onHoverChanged(isHovered)
        }
    }
}
