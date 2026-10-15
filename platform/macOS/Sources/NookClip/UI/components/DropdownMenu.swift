import SwiftUI

// MARK: - 通用下拉菜单（分类筛选 · 卡片式 · 键盘高亮联动）

/// 下拉菜单固定宽度（调用方据此对锚点做右缘对齐定位）
enum NookClipDropdownLayout {
    static let menuWidth: CGFloat = 224
}

struct DropdownOption<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
    var symbol: String? = nil
    var count: Int? = nil
    var isSelected: Bool = false
}

struct NookClipDropdownMenu<ID: Hashable>: View {
    let options: [DropdownOption<ID>]
    /// 键盘/悬停高亮行（nil = 无高亮）
    let highlightedID: ID?
    let onSelect: (ID) -> Void
    /// 鼠标悬停同步高亮（nil = 移出）；键盘导航时无需传
    var onHover: ((ID?) -> Void)? = nil
    /// 行拖拽重排（dragging 移到 target 之前；跨行悬停逐格推进）；
    /// nil = 行不可拖拽（如搜索建议下拉）
    var onReorder: ((ID, ID) -> Void)? = nil
    /// 右键「上移/下移」（offset = -1/+1）；nil = 无排序右键菜单
    var onNudge: ((ID, Int) -> Void)? = nil
    /// 尾部「恢复自动排序」项文案；nil = 不显示（仅手动序生效时传入）
    var resetOrderLabel: String? = nil
    var onResetOrder: (() -> Void)? = nil

    /// 拖拽中的行 id（DropDelegate 经 Binding 读写；nil = 未在拖拽）
    @State private var draggedID: ID?

    private var isReorderable: Bool { onReorder != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(options) { option in
                menuRow(option, isHighlighted: option.id == highlightedID)
            }
            if let label = resetOrderLabel, let onResetOrder {
                Divider()
                    .overlay(NookClip.separator)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                resetOrderRow(label: label, action: onResetOrder)
            }
        }
        .padding(.vertical, 4)
        .frame(width: NookClipDropdownLayout.menuWidth, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: NookClip.radiusCard, style: .continuous)
                .fill(NookClip.bgPopover)
        }
        .overlay {
            RoundedRectangle(cornerRadius: NookClip.radiusCard, style: .continuous)
                .strokeBorder(NookClip.separator, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
    }


    /// 行内容（按钮版与排序版共用）
    private func rowContent(_ option: DropdownOption<ID>, isHighlighted: Bool) -> some View {
        HStack(spacing: 7) {
            if let symbol = option.symbol {
                Image(systemName: symbol)
                    .font(.system(size: NookClipIconSize.compactMedium))
                    .frame(width: 14)
                    .foregroundStyle(NookClip.textSecondary)
            }
            Text(option.title)
                .font(option.isSelected ? .nookClipBodyMedium : .nookClipBody)
                .foregroundStyle(NookClip.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let count = option.count {
                Text("\(count)")
                    .font(.nookClipMeta)
                    .monospacedDigit()
                    .foregroundStyle(NookClip.textTertiary)
            }
            if option.isSelected {
                Image(systemName: NookClipIcon.Nav.checkmark)
                    .font(.system(size: NookClipIconSize.micro, weight: .semibold))
                    .foregroundStyle(NookClip.accent)
                // 拖拽把手（选中行原位显示 ✓，把手让位）
                Image(systemName: NookClipIcon.Nav.reorder)
                    .font(.system(size: NookClipIconSize.micro))
                    .foregroundStyle(NookClip.textTertiary.opacity(0.6))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background {
            RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                .fill(isHighlighted ? NookClip.bgRowOn : .clear)
        }
        .animation(NookClip.animHover, value: isHighlighted)
        .contentShape(Rectangle())
    }

    /// 排序面行：**不能用 Button**——onDrag 挂在 Button 上会被按钮自身的
    /// 手势吞掉、拖拽永远无法启动（macOS SwiftUI 已知行为，仅 List 行例外），
    /// 选择改由点击手势承载（键盘 ⏎ 选择在 MainView 层处理，不受影响）
    private func reorderableRow(_ option: DropdownOption<ID>, isHighlighted: Bool) -> some View {
        rowContent(option, isHighlighted: isHighlighted)
            .onTapGesture { onSelect(option.id) }
            .onHover { hovering in
                onHover?(hovering ? option.id : nil)
            }
            .onDrag {
                draggedID = option.id
                return NSItemProvider(object: String(describing: option.id) as NSString)
            }
            .onDrop(of: [.text], delegate: rowDropDelegate(for: option))
            .contextMenu {
                if let onNudge {
                    Button {
                        onNudge(option.id, -1)
                    } label: {
                        Label(L10n.tr("category.move_up"), systemImage: NookClipIcon.Nav.arrowUp)
                    }
                    Button {
                        onNudge(option.id, 1)
                    } label: {
                        Label(L10n.tr("category.move_down"), systemImage: NookClipIcon.Nav.arrowDown)
                    }
                }
            }
    }

    @ViewBuilder
    private func menuRow(_ option: DropdownOption<ID>, isHighlighted: Bool) -> some View {
        if isReorderable {
            reorderableRow(option, isHighlighted: isHighlighted)
        } else {
            rowButton(option, isHighlighted: isHighlighted)
        }
    }

    private func rowButton(_ option: DropdownOption<ID>, isHighlighted: Bool) -> some View {
        Button {
            onSelect(option.id)
        } label: {
            rowContent(option, isHighlighted: isHighlighted)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            onHover?(hovering ? option.id : nil)
        }
    }

    /// 尾部「恢复自动排序」行（与菜单行同款样式，去计数/把手）
    private func resetOrderRow(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: NookClipIcon.Nav.resetOrder)
                    .font(.system(size: NookClipIconSize.compactMedium))
                    .frame(width: 14)
                    .foregroundStyle(NookClip.textSecondary)
                Text(label)
                    .font(.nookClipBody)
                    .foregroundStyle(NookClip.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func rowDropDelegate(for option: DropdownOption<ID>) -> MenuRowDropDelegate<ID> {
        MenuRowDropDelegate(
            targetID: option.id,
            draggedID: $draggedID,
            onReorder: onReorder
        )
    }
}

/// 菜单行拖放目标：拖拽行悬停到目标行时即时重排（父级持久化后列表即时重渲，
/// 逐格推进产生实时跟手效果）；紧邻其前不动作（防悬停振荡，见 CategoryOrdering.reorder）
private struct MenuRowDropDelegate<ID: Hashable>: DropDelegate {
    let targetID: ID
    let draggedID: Binding<ID?>
    let onReorder: ((ID, ID) -> Void)?

    func dropEntered(info: DropInfo) {
        guard let dragged = draggedID.wrappedValue,
              dragged != targetID,
              let onReorder else { return }
        onReorder(dragged, targetID)
    }

    func dropUpdated(info: DropInfo) -> DropInfo? { info }

    func performDrop(info: DropInfo) -> Bool {
        draggedID.wrappedValue = nil
        return true
    }
}

// MARK: - 全窗口透明点击捕获层（下拉菜单打开时点击外部关闭）

/// SwiftUI 点击命中不裁剪到父视图边界，超大透明矩形从锚点铺满整窗即可拦截外部点击
struct OutsideTapCatcher: View {
    let onTap: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 2400, height: 2400)
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
    }
}
