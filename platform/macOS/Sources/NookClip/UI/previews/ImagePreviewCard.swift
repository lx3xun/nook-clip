import SwiftUI

// MARK: - US6 图片卡片（payloadPath 真实渲染 · 失败回退占位符）

@MainActor
struct ImagePreviewCard: View {
    let path: String
    var isScanning: Bool = false
    var onTriggerOCR: (() -> Void)? = nil

    /// 预览数据出口（窗格量级下采样解码；见 FileStore.previewMaxPixelSize）
    private let previewData = PreviewDataProvider.live
    /// 后台解码结果（主线程渲染）：大图（5K 截图/单反原片）同步解码会卡住
    /// 主线程数秒（审计 BUG-028）；.task(id:) 随 path 变化自动取消旧加载
    @State private var image: NSImage?
    @State private var scanOffset: CGFloat = 0

    var body: some View {
        Group {
            if let image {
                ZStack(alignment: .bottomTrailing) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .overlay {
                            if isScanning {
                                scanningOverlay
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: NookClip.radiusCard, style: .continuous))
                        .overlay {
                            if isScanning {
                                RoundedRectangle(cornerRadius: NookClip.radiusCard, style: .continuous)
                                    .strokeBorder(NookClip.accent.opacity(0.6), lineWidth: 1.5)
                            }
                        }

                    if let onTriggerOCR, !isScanning {
                        LiveTextButton(onTriggerOCR: onTriggerOCR)
                            .padding(8)
                    }
                }
            } else {
                // 加载中/失败回退占位（居中大尺寸图片卡片，清晰表达图片类型）
                placeholderCard
            }
        }
        .task(id: path) {
            let provider = previewData
            let decoded = await Task.detached(priority: .userInitiated) {
                provider.previewImage(for: path)
            }.value
            if !Task.isCancelled {
                image = decoded
            }
        }
        .onDisappear {
            image = nil
        }
    }

    /// 扫描动画覆盖层：垂直往返激光扫描线 + 科技感微光
    @ViewBuilder
    private var scanningOverlay: some View {
        GeometryReader { geo in
            let height = geo.size.height
            ZStack(alignment: .top) {
                // 浅蓝/主题色半透明扫描光带
                LinearGradient(
                    colors: [
                        NookClip.accent.opacity(0.0),
                        NookClip.accent.opacity(0.18),
                        NookClip.accent.opacity(0.35)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 32)
                .overlay(alignment: .bottom) {
                    // 底部高亮光线
                    Rectangle()
                        .fill(NookClip.accent)
                        .frame(height: 2)
                        .shadow(color: NookClip.accent, radius: 4, x: 0, y: 0)
                }
                .offset(y: scanOffset * max(height - 32, 1))
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .onAppear {
                scanOffset = 0
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                    scanOffset = 1
                }
            }
        }
    }

    /// 加载中或失败时的占位卡片：大尺寸图片图标与说明，清晰表达图片类型
    @ViewBuilder
    private var placeholderCard: some View {
        RoundedRectangle(cornerRadius: NookClip.radiusControl)
            .fill(NookClip.bgInset)
            .frame(maxWidth: .infinity)
            .frame(height: 140)
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: NookClipIcon.Category.image)
                        .font(.system(size: NookClipIconSize.heroMedium, weight: .regular))
                        .foregroundStyle(RowKind.image.tintColor.opacity(0.75))
                    Text(L10n.tr("item.type_image"))
                        .font(.nookClipSubheadMedium)
                        .foregroundStyle(NookClip.textTertiary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: NookClip.radiusCard, style: .continuous))
    }
}

/// 原生实况文本（Live Text）毛玻璃悬浮按钮（对齐 macOS Quick Look / 照片原生规范）
private struct LiveTextButton: View {
    let onTriggerOCR: () -> Void

    @State private var isHovered = false
    @State private var showTooltip = false
    @State private var tooltipTask: Task<Void, Never>?

    var body: some View {
        Button(action: onTriggerOCR) {
            Image(systemName: NookClipIcon.Action.ocr)
                .font(.system(size: NookClipIconSize.compactMedium, weight: .medium))
                .foregroundStyle(isHovered ? NookClip.textPrimary : NookClip.textSecondary)
                .frame(width: 26, height: 26)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.regularMaterial)
                        .shadow(color: Color.black.opacity(0.12), radius: 3, y: 1.5)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(NookClip.borderHairline, lineWidth: 0.5)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering in
            withAnimation(NookClip.animHover) {
                isHovered = hovering
            }
            tooltipTask?.cancel()
            if hovering {
                tooltipTask = Task {
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    if !Task.isCancelled {
                        withAnimation(.easeOut(duration: 0.12)) {
                            showTooltip = true
                        }
                    }
                }
            } else {
                withAnimation(.easeOut(duration: 0.08)) {
                    showTooltip = false
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if showTooltip {
                InstantTooltipBubble(text: L10n.tr("preview.ocr.recognize"))
                    .offset(y: -30)
            }
        }
        .accessibilityLabel(L10n.tr("preview.ocr.recognize"))
    }
}
