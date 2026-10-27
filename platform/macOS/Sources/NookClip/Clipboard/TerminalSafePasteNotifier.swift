import AppKit
import SwiftUI

// MARK: - 终端护栏的轻提示（非阻断悬浮胶囊）
//
// 为什么不用主面板里的 `ActionToast`：护栏触发时面板已经收起（粘贴动作本来
// 就要把焦点还给目标终端），面板内的 toast 会跟着一起消失，用户只会觉得
// 「我按了回车，然后什么都没发生」。这里用一张独立小窗，在鼠标附近浮 2 秒。

@MainActor
final class TerminalSafePasteNotifier {
    static let shared = TerminalSafePasteNotifier()

    /// 复用同一张面板：连续粘贴时只改文案并续期，不会叠出一摞窗口
    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?

    private init() {}

    func show(_ message: String, duration: TimeInterval = 2.0) {
        dismissWorkItem?.cancel()

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: TerminalSafePasteToastView(message: message))
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 240, height: 34))
        positionNearMouse(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }

        let work = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func dismiss() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 34),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        // 不抢焦点：用户此刻正站在终端里准备按键，弹窗一旦成为 key window
        // 就会把输入吞掉，反而制造新的事故
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = true
        return panel
    }

    /// 贴在鼠标指针下方（用户刚在面板里点/按完回车，视线就在这一带）
    private func positionNearMouse(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        var x = mouse.x - size.width / 2
        var y = mouse.y - size.height - 16
        if y < visible.minY + 12 { y = mouse.y + 20 }
        x = max(visible.minX + 12, min(x, visible.maxX - size.width - 12))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - 胶囊视图

private struct TerminalSafePasteToastView: View {
    let message: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: NookClipIcon.Sensitive.shieldOk)
                .font(.system(size: NookClipIconSize.compact))
                .foregroundStyle(NookClip.colorSuccess)
            Text(message)
                .font(.nookClipSubhead)
                .foregroundStyle(NookClip.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background {
            RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                .fill(NookClip.bgPopover)
                .overlay {
                    RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                        .strokeBorder(NookClip.separator, lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
        }
        .fixedSize()
        .accessibilityAddTraits(.isStaticText)
    }
}
