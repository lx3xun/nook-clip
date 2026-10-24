import SwiftUI

/// 展开过滤面板实测高度（供外层合成卡的单一整体背景/阴影延伸覆盖）
struct FilterPanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - 搜索框展开过滤面板（Spotlight / Raycast / 飞书搜索式）
// 平时呼出面板左列只有「搜索框 + 剪贴板列表」，干净利落；点击搜索框（或 ⌘F）
// 且未打字时，本卡片从搜索框下方浮出（不透明底，直接叠在列表上方）：
//
//   ┌────────────────────────────┐  256pt 宽
//   │  按类型                     │  分组小标题
//   │  [收藏][图片][文本][链接]   │  固定 4 列 × 2 行网格（8 槽）
//   │  [代码][文件][颜色][回收站] │  计数 0 置灰半透明，位置不变
//   │  ─────────────────────     │  细分割线
//   │  按标签                     │  无标签时整区隐藏（卡片自动变薄）
//   │  (#灵感)(#待办)(#api) …     │  自适应流式胶囊，最多 2 行可滚动
//   └────────────────────────────┘
//
// 点选类型/标签后浮层自动收起，条件作为小胶囊嵌入搜索框左侧（见 NookClipSearchField）。

struct CategoryFilterPanel: View {
    /// 8 个固定类型槽（顺序固定；空槽 count == 0）
    let categories: [SidebarCategory]
    /// 当前生效分类 id（0 = 全部，无高亮）
    let selectedCategoryID: Int
    /// 标签统计（空数组时下半区隐藏、卡片变薄）
    let tags: [TagStat]
    /// 当前生效标签过滤（用于高亮）
    let selectedTag: String?

    /// 是否自绘不透明底纸与圆角描边。合成卡场景（搜索框 + 面板同一张卡）传 false：
    /// 背景/阴影由外层贯穿两者的单张整体形状统一绘制，避免两块面互相投影导致接缝割裂。
    var drawsBackground: Bool = true

    let onSelectCategory: (Int) -> Void
    let onSelectTag: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel(L10n.tr("filter.by_type"))
            typeGrid
            if !tags.isEmpty {
                Rectangle()
                    .fill(NookClip.separator)
                    .frame(height: 0.5)
                    .padding(.vertical, 8)
                sectionLabel(L10n.tr("filter.by_tag"))
                tagFlow
            }
        }
        .padding(NookClip.filterPanelPadding)
        .frame(width: NookClip.widthFilterPanel, alignment: .leading)
        .background {
            if drawsBackground {
                // 「与搜索框一体」展开：同一块不透明底纸，仅底部两角圆角，上沿与搜索框
                // 严丝合缝相连（顶角为直角），视觉上像搜索框向下长出的一体面板。
                // 不透明底：windowBackgroundColor 实色 + 主题叠加，避免透出下层列表文字。
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: NookClip.radiusCard,
                    bottomTrailingRadius: NookClip.radiusCard,
                    topTrailingRadius: 0,
                    style: .continuous
                )
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay {
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: NookClip.radiusCard,
                        bottomTrailingRadius: NookClip.radiusCard,
                        topTrailingRadius: 0,
                        style: .continuous
                    )
                    .fill(NookClip.bgPopover)
                }
                .overlay(alignment: .bottomLeading) {
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: NookClip.radiusCard,
                        bottomTrailingRadius: NookClip.radiusCard,
                        topTrailingRadius: 0,
                        style: .continuous
                    )
                    .strokeBorder(NookClip.separator, lineWidth: 0.5)
                }
            }
        }
        // 上报自身高度：合成卡场景下，外层据此把单张整体背景/阴影延伸覆盖到面板底部。
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: FilterPanelHeightKey.self, value: proxy.size.height)
            }
        }
    }

    // MARK: 分组小标题

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.nookClipMeta)
            .foregroundStyle(NookClip.textTertiary)
            .frame(height: NookClip.heightFilterSectionLabel, alignment: .leading)
    }

    // MARK: 类型网格（固定 4 列 × 2 行）

    private var typeGrid: some View {
        let rows = stride(from: 0, to: categories.count, by: NookClip.filterGridColumns).map { start in
            Array(categories[start..<min(start + NookClip.filterGridColumns, categories.count)])
        }
        return VStack(spacing: NookClip.filterGridSpacingV) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: NookClip.filterGridSpacingH) {
                    ForEach(row) { category in
                        CategoryFilterCell(
                            category: category,
                            isSelected: category.id == selectedCategoryID,
                            action: { onSelectCategory(category.id) }
                        )
                    }
                    // 补齐末行空位，保持 4 列等宽
                    if row.count < NookClip.filterGridColumns {
                        ForEach(0..<(NookClip.filterGridColumns - row.count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
        }
    }

    // MARK: 标签流式胶囊

    private var tagFlow: some View {
        ScrollView(.vertical, showsIndicators: false) {
            FlowLayout(spacing: 6) {
                ForEach(tags, id: \.name) { tag in
                    TagChipView(
                        tag: tag.name,
                        size: .compact,
                        isSelected: selectedTag?.caseInsensitiveCompare(tag.name) == .orderedSame,
                        onTap: { onSelectTag(tag.name) }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: NookClip.maxHeightFilterTags, alignment: .top)
    }
}

// MARK: - 类型单元格（实心色块图标 + 名称 + 计数）

private struct CategoryFilterCell: View {
    let category: SidebarCategory
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    /// 空分类（计数 0）置灰半透明，但仍占位
    private var isEmpty: Bool { category.count == 0 }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: category.symbol)
                    .font(.system(size: NookClipIconSize.compactMedium, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(category.tintColor)
                    }
                Text(category.name)
                    .font(.nookClipBadge)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(isSelected ? category.tintColor : NookClip.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: NookClip.heightFilterCell)
            .background {
                RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                    .fill(backgroundFill)
            }
            .contentShape(RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(isEmpty)
        .opacity(isEmpty ? 0.36 : 1.0)
        .help("\(category.name) (\(category.count))")
        .onHover { isHovered = $0 }
        .animation(NookClip.animHover, value: isHovered)
    }

    private var backgroundFill: Color {
        if isSelected { return category.tintColor.opacity(0.14) }
        if isHovered { return NookClip.bgRowOn }
        return .clear
    }
}

// MARK: - 流式布局（自适应换行；自适应宽度、纵向堆叠）

/// 从左到右排布子项，超出容器宽度自动换行。用于标签胶囊流（最多 2 行，
/// 由外层 maxHeight 裁剪 + ScrollView 兜底）。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        rows.removeAll()
        return CGSize(width: maxWidth == .infinity ? naturalWidth(subviews) : maxWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var height: CGFloat = 0 }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var x: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let advance = (current.indices.isEmpty ? 0 : spacing) + size.width
            if x + advance > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
                x = 0
            }
            x += (current.indices.isEmpty ? 0 : spacing) + size.width
            current.indices.append(index)
            current.height = max(current.height, size.height)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }

    private func naturalWidth(_ subviews: Subviews) -> CGFloat {
        subviews.map { $0.sizeThatFits(.unspecified).width }.reduce(0, +)
            + spacing * CGFloat(max(subviews.count - 1, 0))
    }
}
