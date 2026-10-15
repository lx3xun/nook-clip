import SwiftUI

// MARK: - 删除撤销 toast（T038 拆自 MainView，纯移动）

/// 删除撤销 toast：列表底部悬浮（计数 + 撤销按钮 + 倒计时进度条），
/// 窗口时长见 DeletionWorkflow.undoWindow。状态与回调参数化，MainView 只接线。
@MainActor
struct UndoToast: View {
    /// 待撤销条目数
    let pendingCount: Int
    /// 撤销窗口截止时间（倒计时进度条；无截止时间时为满条）
    let undoDeadline: Date
    /// 撤销最近一次删除（⌘Z / toast 按钮）
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(L10n.tr("delete.toast.message", String(pendingCount)))
                .font(.nookClipSubheadMedium)
                .monospacedDigit()
                .foregroundStyle(NookClip.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                onUndo()
            } label: {
                Text(L10n.tr("delete.toast.undo"))
                    .font(.nookClipSubheadMedium)
                    .foregroundStyle(NookClip.accent)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background {
                        RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                            .fill(NookClip.bgChipSelected)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        // 倒计时进度条贴胶囊底缘（不拦截点击）
        .overlay(alignment: .bottom) {
            undoCountdownBar
        }
        .background {
            RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                .fill(NookClip.bgPopover)
                .overlay {
                    RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                        .strokeBorder(NookClip.separator, lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// 撤销倒计时进度条：剩余时长占窗口比例（TimelineView 逐帧重算；
    /// 窗口重开时 undoDeadline 更新，进度自动复位）
    private var undoCountdownBar: some View {
        TimelineView(.animation(minimumInterval: 0.05)) { context in
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(NookClip.separator.opacity(0.6))
                    Rectangle()
                        .fill(NookClip.accent.opacity(0.85))
                        .frame(width: geo.size.width * remainingRatio(at: context.date))
                }
            }
        }
        .frame(height: 2)
        .padding(.horizontal, 4)
        .clipShape(RoundedRectangle(cornerRadius: 1))
        .allowsHitTesting(false)
    }

    /// 撤销窗口剩余比例（0...1；无截止时间时为满条）
    private func remainingRatio(at now: Date) -> CGFloat {
        guard undoDeadline > .distantPast else { return 1 }
        let remaining = max(0, undoDeadline.timeIntervalSince(now))
        return CGFloat(min(1, remaining / DeletionWorkflow.undoWindow))
    }
}
