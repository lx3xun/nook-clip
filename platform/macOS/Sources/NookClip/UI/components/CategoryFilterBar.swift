import SwiftUI

// MARK: - 分类筛选条（搜索框下方 · 固定「全部/收藏」+ 数量前 1 · 第 4 槽动态切换）

/// 分类筛选条：全部/收藏常驻 + 数量前 1 的类型类目固定展示；第 4 槽为动态槽，
/// 展示一个可切换类目。点击胶囊主体直接选中该类目（触发过滤），仅最右侧 ▾
/// 热区展开下拉切换占位类目（含「最近删除」）。
/// 选中类目落在可切换集合内时永远占据第 4 槽可见。
/// 图标常态展示补齐视觉质感；计数仅在选中项显示（大数 k 缩写），释放横向空间。
struct CategoryFilterBar: View {
    let chips: [SidebarCategory]
    /// 第 4 槽占位类目（nil = 无可切换类目，不渲染该槽）
    let slotCategory: SidebarCategory?
    /// 下拉是否还有可切换项（决定 ▾ 热区渲染）
    var hasSlotMenu: Bool = false
    /// 当前生效分类 id（chip / 第 4 槽选中态判定）
    let selectedID: Int
    var isSlotMenuOpen: Bool = false
    let onSelect: (Int) -> Void
    var onToggleSlotMenu: (() -> Void)? = nil

    @State private var isSlotHovered = false
    @State private var isChevronHovered = false
    @Namespace private var flexNamespace
    @Namespace private var scrollNamespace

    var body: some View {
        // 宽度自适应降级（ViewThatFits 按可用宽度自动选档）：
        // 1) 等摊富余（默认档）：4 项在自然宽度上等量加宽、整行占满列宽，
        //    消除短文案语言（中文等）下的右侧空余；子项永不窄于自然宽度
        // 2) 横向滚动（极端兜底：自然总宽已超列宽，长文案语言），
        //    第 4 槽固定在行尾，不随滚动
        // 图标常驻 + 仅选中项展示计数（大数 k 缩写）；横向空间大幅释放，
        // 常规列宽均稳定落在默认档
        ViewThatFits(in: .horizontal) {
            EqualShareFlex(spacing: 5) {
                chipViews(fills: true, namespace: flexNamespace)
                if let slot = slotCategory {
                    slotButton(slot, fills: true, namespace: flexNamespace)
                }
            }
            HStack(spacing: 5) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) { chipViews(fills: false, namespace: scrollNamespace) }
                        // 滚动档内防内容被压缩
                        .fixedSize(horizontal: true, vertical: false)
                }
                if let slot = slotCategory {
                    slotButton(slot, fills: false, namespace: scrollNamespace)
                }
            }
        }
        .frame(height: NookClip.heightCategoryBar)
    }

    private func chipViews(fills: Bool, namespace: Namespace.ID) -> some View {
        ForEach(chips) { chip in
            CategoryChipButton(
                chip: chip,
                isSelected: chip.id == selectedID,
                fillsWidth: fills,
                namespace: namespace
            ) {
                onSelect(chip.id)
            }
        }
    }
    /// 第 4 槽（动态槽）：点击胶囊主体直接选中当前占位类目（触发过滤）；
    /// 有更多可切换类目时，仅最右侧 ▾ 热区展开下拉；无可切换项时整体即选中按钮
    private func slotButton(_ slot: SidebarCategory, fills: Bool, namespace: Namespace.ID) -> some View {
        let isSelected = slot.id == selectedID
        return HStack(spacing: 0) {
            Button {
                onSelect(slot.id)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: slot.symbol)
                        .font(.system(size: NookClipIconSize.micro, weight: isSelected ? .semibold : .medium))
                    Text(slot.name)
                        .font(isSelected ? .nookClipMetaMedium : .nookClipMeta)
                        .lineLimit(1)
                        .fixedSize()
                    if isSelected {
                        Text(slot.formattedCount)
                            .font(.nookClipBadge)
                            .monospacedDigit()
                            .foregroundStyle(slot.tintColor.opacity(0.88))
                            .fixedSize()
                    }
                }
                .foregroundStyle(isSelected ? slot.tintColor : (isSlotHovered ? NookClip.textPrimary : NookClip.textSecondary))
                .padding(.leading, 6)
                .padding(.trailing, hasSlotMenu ? 2 : 6)
                .frame(maxWidth: fills ? .infinity : nil)
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("\(slot.name) (\(slot.count))")

            if hasSlotMenu {
                Rectangle()
                    .fill(isSelected ? slot.tintColor.opacity(0.22) : NookClip.separator)
                    .frame(width: 0.5, height: 11)

                Button {
                    onToggleSlotMenu?()
                } label: {
                    Image(systemName: NookClipIcon.Nav.chevronDown)
                        .font(.system(size: NookClipIconSize.microSmall, weight: .semibold))
                        .foregroundStyle(isSelected ? slot.tintColor : (isChevronHovered || isSlotMenuOpen ? NookClip.textPrimary : NookClip.textTertiary))
                        .frame(width: 16, height: 22)
                        .background {
                            if isChevronHovered || isSlotMenuOpen {
                                UnevenRoundedRectangle(
                                    topLeadingRadius: 0,
                                    bottomLeadingRadius: 0,
                                    bottomTrailingRadius: NookClip.radiusControl,
                                    topTrailingRadius: NookClip.radiusControl,
                                    style: .continuous
                                )
                                .fill(NookClip.bgRowOn)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .onHover { isChevronHovered = $0 }
                .help(L10n.tr("search.more_categories"))
            }
        }
        .frame(maxWidth: fills ? .infinity : nil)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                    .fill(slot.tintColor.opacity(0.14))
                    .overlay {
                        RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                            .strokeBorder(slot.tintColor.opacity(0.24), lineWidth: 0.5)
                    }
                    .matchedGeometryEffect(id: "activeCategoryIndicator", in: namespace)
            } else if isSlotMenuOpen || isSlotHovered {
                RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                    .fill(NookClip.bgRowOn)
            }
        }
        .onHover { isSlotHovered = $0 }
        .animation(NookClip.animSpring, value: isSelected)
        .animation(NookClip.animHover, value: isSlotHovered)
    }
}

struct CategoryChipButton: View {
    let chip: SidebarCategory
    let isSelected: Bool
    /// 默认档（等摊富余）吃满分配宽度、胶囊铺满所在段；滚动兜底档保持自然宽度
    var fillsWidth: Bool = false
    var namespace: Namespace.ID? = nil
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: chip.symbol)
                    .font(.system(size: NookClipIconSize.micro, weight: isSelected ? .semibold : .medium))
                Text(chip.name)
                    .font(isSelected ? .nookClipMetaMedium : .nookClipMeta)
                    .lineLimit(1)
                    .fixedSize()
                if isSelected {
                    Text(chip.formattedCount)
                        .font(.nookClipBadge)
                        .monospacedDigit()
                        .foregroundStyle(chip.tintColor.opacity(0.88))
                        .fixedSize()
                }
            }
            .foregroundStyle(isSelected ? chip.tintColor : (isHovered ? NookClip.textPrimary : NookClip.textSecondary))
            .padding(.horizontal, 6)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .frame(height: 22)
            .background {
                if isSelected {
                    if let namespace {
                        RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                            .fill(chip.tintColor.opacity(0.14))
                            .overlay {
                                RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                                    .strokeBorder(chip.tintColor.opacity(0.24), lineWidth: 0.5)
                            }
                            .matchedGeometryEffect(id: "activeCategoryIndicator", in: namespace)
                    } else {
                        RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                            .fill(chip.tintColor.opacity(0.14))
                            .overlay {
                                RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                                    .strokeBorder(chip.tintColor.opacity(0.24), lineWidth: 0.5)
                            }
                    }
                } else if isHovered {
                    RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                        .fill(NookClip.bgRowOn)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("\(chip.name) (\(chip.count))")
        .onHover { isHovered = $0 }
        .animation(NookClip.animSpring, value: isSelected)
        .animation(NookClip.animHover, value: isHovered)
    }
}

// MARK: - 等摊富余横排（分类筛选条默认档）

/// 每个子项在自然宽度上等量加宽，整行填满可用宽度（子项内部需以
/// frame(maxWidth: .infinity) 吃满分配宽度）。自然总宽超出可用宽度时不压缩、
/// 返回自然尺寸（长文案语言不截断），交由外层 ViewThatFits 的横向滚动档兜底。
///
/// `maxStretch` 限制单个子项能分到的富余量：类目数量会随数据变化
/// （空库时类型类目计数为 0 被隐藏，4 个胶囊变 2 个），把同样的列宽摊给
/// 更少的子项会让胶囊从 71pt 撑到 144pt——首次启动和清空历史后整条筛选条
/// 会变形。加上限后子项保持自然宽度附近，余量留在行尾，形状不再随数据跳动。
struct EqualShareFlex: Layout {
    var spacing: CGFloat
    /// 单个子项可分配的最大富余（pt）。默认 24：正常 4 个胶囊时
    /// 实际富余约 17pt，不受影响；只有类目变少时才生效。
    var maxStretch: CGFloat = 24

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = naturalSize(subviews)
        guard let width = proposal.width, width.isFinite, width > 0 else { return size }
        return CGSize(width: max(size.width, width), height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = subviews.map { $0.sizeThatFits(.unspecified).width }
        let count = max(subviews.count, 1)
        let naturalTotal = widths.reduce(0, +) + spacing * CGFloat(max(subviews.count - 1, 0))
        // 富余均摊到每个子项；不足（滚动兜底档不会走到这里）则保持自然宽度
        let share = min(max(0, (bounds.width - naturalTotal) / CGFloat(count)), maxStretch)
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            let width = widths[index] + share
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: nil))
            x += width + spacing
        }
    }

    private func naturalSize(_ subviews: Subviews) -> CGSize {
        let heights = subviews.map { $0.sizeThatFits(.unspecified).height }
        return CGSize(
            width: subviews.map { $0.sizeThatFits(.unspecified).width }.reduce(0, +)
                + spacing * CGFloat(max(subviews.count - 1, 0)),
            height: heights.max() ?? 0
        )
    }
}
