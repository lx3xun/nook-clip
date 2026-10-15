import SwiftUI

// MARK: - 时间锚点条（8pt 极简微轨 · 左向加宽至 12pt · 绝不越过列表分割线）

/// 锚点条条目（纯时间分组）
struct TimelineRailItem: Identifiable, Equatable {
    let id: String
    let title: String
    let count: Int?
}

/// 极简自适应刻度微岛：
/// 1. 平时：极致纤细 8pt 居中于右缘内侧，距离右侧分割线/窗口边框留有 4pt 明确安全留白，绝不越线溢出。
/// 2. 鼠标移入/拖拽：自适应向左平滑加宽至 12pt，右边缘保持锚定锁定，完全在列表面板内部舒展。
/// 3. 实底气泡 HUD：左侧浮现实底毛玻璃圆角卡片，实时清晰显示分组全名及数量（如「今天 · 29」）。
/// 4. 彻底屏蔽窗口边缘缩放手柄，收起/展开预览模式下均绝无「双向拖动光标」干扰。
struct TimelineIndexRail: View {
    let items: [TimelineRailItem]
    /// 胶囊指示的当前项 id（跟随吸顶组）
    let currentID: String?
    /// 连续定位
    let onScrub: (String) -> Void

    @State private var isHovered = false
    @State private var isDragging = false
    @State private var activeIndex: Int?
    @State private var bubbleDismissTask: Task<Void, Never>?

    private var isActive: Bool { isHovered || isDragging }
    /// 悬停/拖拽时动态向左加宽至 12pt，平时收缩至 8pt
    private var currentWidth: CGFloat {
        isActive ? NookClip.widthTimeRailExpanded : NookClip.widthTimeRail
    }

    var body: some View {
        GeometryReader { geo in
            let count = max(items.count, 1)
            let maxTrackHeight = max(geo.size.height - 32, 60)
            let slotHeight = min(
                max(maxTrackHeight / CGFloat(count), NookClip.heightTimeRailRowMin),
                NookClip.heightTimeRailRow
            )
            let totalTrackHeight = slotHeight * CGFloat(count)
            // 垂直居中分布在视口中央，避开视口顶部的滚动条滑块与底部控制栏
            let trackTop = max((geo.size.height - totalTrackHeight) / 2, 8)

            ZStack(alignment: .topTrailing) {
                // 浮动气泡 HUD：位于轨道左侧，实底圆角卡片，随激活项纵向居中
                if let activeIndex, items.indices.contains(activeIndex), isActive {
                    let item = items[activeIndex]
                    let targetY = trackTop + CGFloat(activeIndex) * slotHeight + slotHeight / 2
                    bubbleView(for: item)
                        .offset(
                            x: -currentWidth - 8,
                            y: min(max(targetY - 13, 6), max(geo.size.height - 32, 6))
                        )
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .trailing)),
                            removal: .opacity
                        ))
                }

                // 刻度微轨主体（以右侧为锚点对齐，宽度变化仅向左延伸，右边缘绝不移动）
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        trackMark(for: item, isHighlighted: index == activeIndex)
                            .frame(width: currentWidth, height: slotHeight)
                    }
                }
                .padding(.vertical, 3)
                .background {
                    Capsule(style: .continuous)
                        .fill(NookClip.bgTimeRail(isActive: isActive))
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(NookClip.separator, lineWidth: 0.5)
                        }
                }
                .offset(y: trackTop)
                .frame(width: currentWidth, alignment: .trailing)
            }
            .frame(width: max(currentWidth, NookClip.hitWidthTimeRail), height: geo.size.height, alignment: .topTrailing)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    bubbleDismissTask?.cancel()
                    isHovered = true
                    let idx = itemIndex(atY: location.y - trackTop, slotHeight: slotHeight)
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) {
                        activeIndex = idx
                    }
                case .ended:
                    isHovered = false
                    if !isDragging {
                        bubbleDismissTask?.cancel()
                        bubbleDismissTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 180_000_000)
                            if !Task.isCancelled && !isHovered && !isDragging {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    activeIndex = nil
                                }
                            }
                        }
                    }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        bubbleDismissTask?.cancel()
                        isDragging = true
                        let idx = itemIndex(atY: value.location.y - trackTop, slotHeight: slotHeight)
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) {
                            activeIndex = idx
                        }
                        if let idx, items.indices.contains(idx) {
                            onScrub(items[idx].id)
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                        if !isHovered {
                            bubbleDismissTask?.cancel()
                            bubbleDismissTask = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 250_000_000)
                                if !Task.isCancelled && !isHovered && !isDragging {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        activeIndex = nil
                                    }
                                }
                            }
                        }
                    }
            )
        }
        .frame(width: max(currentWidth, NookClip.hitWidthTimeRail), alignment: .trailing)
        .padding(.trailing, 2)
        .opacity(isActive ? 1.0 : NookClip.timeRailIdleOpacity)
        .animation(.spring(response: 0.25, dampingFraction: 0.78), value: isActive)
        .accessibilityLabel(L10n.tr("time.rail.accessibility"))
    }

    /// 刻度标记：悬停加宽时微幅放大
    @ViewBuilder
    private func trackMark(for item: TimelineRailItem, isHighlighted: Bool) -> some View {
        let isCurrent = item.id == currentID

        if isCurrent {
            Capsule()
                .fill(NookClip.accent)
                .frame(
                    width: isActive ? (isHighlighted ? 4.8 : 4.0) : 3.5,
                    height: isActive ? (isHighlighted ? 13 : 11) : 9
                )
                .shadow(color: NookClip.accent.opacity(0.4), radius: 2)
        } else {
            Circle()
                .fill(isHighlighted ? NookClip.textPrimary : NookClip.textSecondary.opacity(0.6))
                .frame(
                    width: isActive ? (isHighlighted ? 3.8 : 3.0) : 2.6,
                    height: isActive ? (isHighlighted ? 3.8 : 3.0) : 2.6
                )
        }
    }

    /// 浮动气泡 HUD：实底材质 + 清晰阴影，不与行尾文字透底打架
    private func bubbleView(for item: TimelineRailItem) -> some View {
        HStack(spacing: 5) {
            Text(item.title)
                .font(.nookClipMetaMedium)
                .foregroundStyle(NookClip.textPrimary)
                .lineLimit(1)
            if let count = item.count {
                Text("· \(count)")
                    .font(.nookClipCaption)
                    .monospacedDigit()
                    .foregroundStyle(NookClip.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4.5)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(NookClip.bgPopover)
                }
                .shadow(color: .black.opacity(0.24), radius: 8, x: -2, y: 3)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(NookClip.separator, lineWidth: 0.5)
        }
        .fixedSize()
        .allowsHitTesting(false)
    }

    private func itemIndex(atY y: CGFloat, slotHeight: CGFloat) -> Int? {
        guard !items.isEmpty, slotHeight > 0 else { return nil }
        let idx = Int(floor(y / slotHeight))
        return min(max(idx, 0), items.count - 1)
    }
}
