import SwiftUI

// MARK: - 底部多选工具栏（36px · US5 接线 · T038 拆自 MainView，纯移动）

/// 批量模式底部工具栏：计数 + 操作提示 + 合并粘贴/删除按钮。
/// 状态与回调参数化，MainView 只接线。
struct BatchBar: View {
    /// 勾选条目数
    let selectedCount: Int
    /// 合并粘贴勾选集（⏎）
    let onMergePaste: () -> Void
    /// 删除勾选集（⌘⌫）
    let onDelete: () -> Void

    var body: some View {
        // 两行布局：列表列仅 336pt，单行塞「计数 + 提示 + 两按钮」会挤压截断
        // 提示文字——上行放计数与操作提示，下行右对齐放操作按钮
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                Text(L10n.tr("batch.selected_count", String(selectedCount)))
                    .font(.nookClipSubheadMedium)
                    .monospacedDigit()
                    .foregroundStyle(NookClip.textPrimary)
                    .lineLimit(1)
                Text(L10n.tr("batch.extend_selection"))
                    .font(.nookClipCaption)
                    .foregroundStyle(NookClip.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(L10n.tr("batch.exit_selection"))
                    .font(.nookClipCaption)
                    .foregroundStyle(NookClip.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                batchButton(text: L10n.tr("batch.merge_paste"), kbd: "⏎", role: .primary) {
                    onMergePaste()
                }
                batchButton(text: L10n.tr("batch.delete"), kbd: "⌘\u{200A}⌫", role: .danger) {
                    onDelete()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(height: 54)
        .background(NookClip.bgFooter)
    }

    enum ButtonRole { case primary, danger }

    func batchButton(text: String, kbd: String, role: ButtonRole, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(text)
                KbdView(text: kbd, fontSize: 10)
            }
            .font(.nookClipSubheadMedium)
            .foregroundStyle(role == .primary ? NookClip.accent : NookClip.colorDanger)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background {
                // 主操作 = 系统蓝浅底强调；危险操作保持微底警示
                RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                    .fill(role == .primary ? NookClip.bgChipSelected : NookClip.bgDangerSubtle)
                    .overlay {
                        RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                            .strokeBorder(role == .primary ? NookClip.borderRowSelectedSubtle : NookClip.borderDangerHover, lineWidth: 0.5)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}
