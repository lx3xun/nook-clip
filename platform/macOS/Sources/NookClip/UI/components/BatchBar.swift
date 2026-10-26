import SwiftUI

// MARK: - 底部多选工具栏（54px · US5 接线 · T038 拆自 MainView）

/// 批量模式底部工具栏：计数 + 操作提示 + 合并粘贴/顺序粘贴/标签/删除。
///
/// 布局约束（踩过的坑）：列表列只有 `NookClip.widthListCol`（310pt），减去左右
/// 各 12pt 内边距后仅 286pt 可用。
///
/// 这里刻意**不让任何内容随鼠标改变尺寸**。前面试过两版「悬停才展开完整标签」的写法，
/// 功能上能把四个名字都显示出来，但代价是按钮宽度随指针移动而伸缩——鼠标扫过工具栏时
/// 整排按钮都在挪位置，想点的那个会在指针底下换地方，非常烦躁。
///
/// 现在改为「常量布局」：
/// - 四个动作全部常驻文字，谁都不用藏、谁都不用等悬停；
/// - 主操作「合并粘贴」是唯一的填色块（图标 + 名称 + ⏎ 键帽），占满剩余宽度；
/// - 三个次要动作是纯文字按钮，只有悬停时才浮出底色——macOS 工具栏的常见做法，
///   既保持位置稳定，又比一排蓝块安静；
/// - 次要动作的键帽（⌥⏎ / ⌘L / ⌘⌫）放进系统提示，不占行内宽度；
/// - 宽度不足时只降字号（`minimumScaleFactor`），绝不省略成「合…」，位置也绝不动。
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

    /// 主按钮悬停态：只影响底色，不影响尺寸
    @State private var isMergeHovered = false

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
            HStack(spacing: 4) {
                // 主操作吃满剩余宽度：宽度只由列宽决定，悬停不会改变它
                mergeButton
                if let onStartPasteStack {
                    BatchActionButton(
                        title: L10n.tr("batch.paste_stack"),
                        shortcut: "⌥⏎",
                        role: .primary,
                        action: onStartPasteStack
                    )
                }
                if let onEditTags {
                    BatchActionButton(
                        title: L10n.tr("tag.action"),
                        shortcut: "⌘L",
                        role: .primary,
                        action: onEditTags
                    )
                }
                BatchActionButton(
                    title: L10n.tr("batch.delete"),
                    shortcut: "⌘⌫",
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

    /// 主操作「合并粘贴」：图标 + 名称 + ⏎ 键帽，吃掉整行剩余宽度
    private var mergeButton: some View {
        Button(action: onMergePaste) {
            HStack(spacing: 5) {
                Image(systemName: NookClipIcon.Action.merge)
                    .font(.system(size: NookClipIconSize.compactMedium, weight: .medium))
                Text(L10n.tr("batch.merge_paste"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                KbdView(text: "⏎", fontSize: 9)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .font(.nookClipSubheadMedium)
            .foregroundStyle(NookClip.accent)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .background {
                RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                    .fill(isMergeHovered ? NookClip.bgRowSelected : NookClip.bgChipSelected)
                    .overlay {
                        RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                            .strokeBorder(NookClip.borderRowSelectedSubtle, lineWidth: 0.5)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering in
            withAnimation(NookClip.animHover) { isMergeHovered = hovering }
        }
        .accessibilityLabel(L10n.tr("batch.merge_paste"))
    }
}

/// 次要操作按钮（顺序粘贴 / 标签 / 删除）：常驻文字，宽度由文字决定，永不伸缩。
///
/// 刻意做成独立视图：`@State isHovered` 必须各自独立，否则悬停一个会把全排一起点亮。
/// 键帽放进系统提示（`.help`），不占行内宽度——三个键帽并排要多吃 60 多 pt，
/// 英文环境会直接把 286pt 撑爆。
struct BatchActionButton: View {
    let title: String
    let shortcut: String
    let role: BatchBar.ButtonRole
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.nookClipMeta)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(role == .primary ? NookClip.accent : NookClip.colorDanger)
                .padding(.horizontal, 6)
                .frame(height: 24)
                .background {
                    RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                        .fill(
                            isHovered
                                ? (role == .primary ? NookClip.bgRowSelected : NookClip.bgDangerHover)
                                : Color.clear
                        )
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering in
            withAnimation(NookClip.animHover) { isHovered = hovering }
        }
        .help("\(title)（\(shortcut)）")
        .accessibilityLabel(title)
    }
}
