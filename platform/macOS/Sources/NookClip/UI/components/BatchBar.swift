import SwiftUI

// MARK: - 底部多选工具栏（54px · US5 接线 · T038 拆自 MainView）

/// 批量模式底部工具栏：计数 + 操作提示 + 合并粘贴/顺序粘贴/标签/删除。
///
/// 布局约束（踩过的坑）：列表列只有 `NookClip.widthListCol`（310pt），减去左右
/// 各 12pt 内边距后仅 286pt 可用。若四个动作都做成「文字 + 键帽」的等宽按钮，
/// 总宽会超出口径，SwiftUI 会把每个 `Text` 压成「合…」「…」「…」——
/// 四个按钮全部失去可读性（真机截图确认过）。
///
/// 因此定为「一主三辅」：
/// - 主操作（合并粘贴）保留文字 + 键帽，独占弹性宽度，一眼可见；
/// - 次要操作（顺序粘贴 / 标签 / 删除）用 28pt 图标按钮，全称与键位靠悬停提示
///   （`.help`）渐进披露 —— 与系统工具栏的图标按钮语义一致；
/// - 上行提示只保留「扩展选择 / 退出」两条通用操作，不再往里加键位说明，
///   否则两行文字会互相抢宽度，重蹈按钮被截断的覆辙。
///
/// 图标按钮都保留了 `.accessibilityLabel`，VoiceOver 读得到完整动作名。
struct BatchBar: View {
    /// 勾选条目数
    let selectedCount: Int
    /// 合并粘贴勾选集（⏎）
    let onMergePaste: () -> Void
    /// 顺序粘贴栈（⌥⏎ · US2）：按列表顺序逐条装填剪贴板，用户每按一次原生 ⌘V 前进一条
    var onStartPasteStack: (() -> Void)? = nil
    /// 删除勾选集（⌘⌫）
    let onDelete: () -> Void
    /// 打开批量标签编辑器（⌘L）
    var onEditTags: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
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
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                // 主操作：唯一带文字的按钮，占据剩余宽度
                batchButton(text: L10n.tr("batch.merge_paste"), kbd: "⏎", role: .primary) {
                    onMergePaste()
                }
                if let onStartPasteStack {
                    iconButton(
                        icon: NookClipIcon.Action.pasteStack,
                        help: L10n.tr("batch.paste_stack_help"),
                        role: .primary,
                        action: onStartPasteStack
                    )
                }
                if let onEditTags {
                    iconButton(
                        icon: NookClipIcon.Action.tag,
                        help: L10n.tr("tag.action"),
                        role: .primary,
                        action: onEditTags
                    )
                }
                iconButton(
                    icon: NookClipIcon.Action.delete,
                    help: L10n.tr("batch.delete"),
                    role: .danger,
                    action: onDelete
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(height: 54)
        .background(NookClip.bgFooter)
    }

    enum ButtonRole { case primary, danger }

    /// 主操作按钮：文字 + 键帽，弹性宽度（`layoutPriority` 保证不被图标按钮挤压）
    func batchButton(text: String, kbd: String, role: ButtonRole, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                KbdView(text: kbd, fontSize: 10)
            }
            .font(.nookClipSubheadMedium)
            .foregroundStyle(role == .primary ? NookClip.accent : NookClip.colorDanger)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .background { chipBackground(role: role) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .layoutPriority(1)
    }

    /// 次要操作按钮：28×24 图标按钮，全称与键位走悬停提示
    func iconButton(
        icon: String,
        help: String,
        role: ButtonRole,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: NookClipIconSize.compactMedium, weight: .medium))
                .foregroundStyle(role == .primary ? NookClip.accent : NookClip.colorDanger)
                .frame(width: 28, height: 24)
                .background { chipBackground(role: role) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private func chipBackground(role: ButtonRole) -> some View {
        // 主操作 = 系统蓝浅底强调；危险操作保持微底警示
        RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
            .fill(role == .primary ? NookClip.bgChipSelected : NookClip.bgDangerSubtle)
            .overlay {
                RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                    .strokeBorder(
                        role == .primary ? NookClip.borderRowSelectedSubtle : NookClip.borderDangerHover,
                        lineWidth: 0.5
                    )
            }
    }
}
