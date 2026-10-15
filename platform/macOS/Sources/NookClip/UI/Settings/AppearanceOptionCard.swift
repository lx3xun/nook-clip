import SwiftUI

// MARK: - 外观选择卡片 (跟随系统 / 浅色 / 深色)

/// Mini 窗口预览配色：浅色/深色两套，仅颜色不同，几何（侧栏条/内容条尺寸与圆角）共用
private struct MiniWindowPalette {
    /// 侧边栏背景
    let sidebarBackground: Color
    /// 侧边栏主条（第一根，较强对比）
    let sidebarBarPrimary: Color
    /// 侧边栏次条（后两根，较弱对比）
    let sidebarBarSecondary: Color
    /// 内容区背景
    let contentBackground: Color
    /// 内容区主条（标题位，较强对比）
    let contentBarPrimary: Color
    /// 内容区次条（正文位，较弱对比）
    let contentBarSecondary: Color

    static let light = MiniWindowPalette(
        sidebarBackground: Color(hex: 0xECECF0),
        sidebarBarPrimary: Color.black.opacity(0.14),
        sidebarBarSecondary: Color.black.opacity(0.08),
        contentBackground: Color(hex: 0xFAFAFC),
        contentBarPrimary: Color.black.opacity(0.22),
        contentBarSecondary: Color.black.opacity(0.10)
    )

    static let dark = MiniWindowPalette(
        sidebarBackground: Color(hex: 0x202024),
        sidebarBarPrimary: Color.white.opacity(0.18),
        sidebarBarSecondary: Color.white.opacity(0.10),
        contentBackground: Color(hex: 0x2E2E32),
        contentBarPrimary: Color.white.opacity(0.28),
        contentBarSecondary: Color.white.opacity(0.12)
    )
}

struct AppearanceOptionCard: View {
    let mode: String
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    previewWindow
                        .frame(width: 100, height: 66)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(
                                    isSelected ? NookClip.accent : (isHovered ? NookClip.separator : NookClip.borderHairline),
                                    lineWidth: isSelected ? 2 : 1
                                )
                        }

                    if isSelected {
                        Image(systemName: NookClipIcon.Control.radioSelected)
                            .font(.system(size: NookClipIconSize.regularMedium, weight: .bold))
                            .foregroundStyle(NookClip.accent)
                            .background(Circle().fill(NookClip.textOnAccent).padding(1))
                            .offset(x: 4, y: -4)
                    }
                }

                HStack(spacing: 5) {
                    Circle()
                        .fill(isSelected ? NookClip.accent : Color.clear)
                        .frame(width: 6, height: 6)
                        .overlay {
                            Circle().stroke(isSelected ? NookClip.accent : NookClip.textTertiary, lineWidth: 1)
                        }
                    Text(title)
                        .font(isSelected ? .nookClipMetaMedium : .nookClipMeta)
                        .foregroundStyle(isSelected ? NookClip.textPrimary : NookClip.textSecondary)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(NookClip.animHover, value: isSelected)
        .animation(NookClip.animHover, value: isHovered)
    }

    @ViewBuilder
    private var previewWindow: some View {
        switch mode {
        case "light":
            miniWindow(palette: .light)
        case "dark":
            miniWindow(palette: .dark)
        default:
            miniSystemWindow
        }
    }

    /// 单一渲染：Mini 侧边栏（三根示意条）+ Mini 内容区（三根示意条），
    /// 浅色/深色仅 palette 不同
    private func miniWindow(palette: MiniWindowPalette) -> some View {
        HStack(spacing: 0) {
            // Mini 侧边栏
            VStack(alignment: .leading, spacing: 3.5) {
                RoundedRectangle(cornerRadius: 1.5).fill(palette.sidebarBarPrimary).frame(width: 18, height: 3)
                RoundedRectangle(cornerRadius: 1.5).fill(palette.sidebarBarSecondary).frame(width: 14, height: 3)
                RoundedRectangle(cornerRadius: 1.5).fill(palette.sidebarBarSecondary).frame(width: 16, height: 3)
                Spacer(minLength: 0)
            }
            .padding(4)
            .frame(width: 32)
            .background(palette.sidebarBackground)

            // Mini 内容区
            VStack(alignment: .leading, spacing: 3.5) {
                RoundedRectangle(cornerRadius: 1.5).fill(palette.contentBarPrimary).frame(width: 44, height: 3.5)
                RoundedRectangle(cornerRadius: 1.5).fill(palette.contentBarSecondary).frame(width: 54, height: 2.5)
                RoundedRectangle(cornerRadius: 1.5).fill(palette.contentBarSecondary).frame(width: 38, height: 2.5)
                Spacer(minLength: 0)
            }
            .padding(5)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.contentBackground)
        }
    }

    /// 跟随系统：深色在下、浅色沿对角线（左上三角）遮罩，展示两种外观并存
    private var miniSystemWindow: some View {
        ZStack {
            miniWindow(palette: .dark)
            miniWindow(palette: .light)
                .mask(
                    GeometryReader { geo in
                        Path { path in
                            path.move(to: .zero)
                            path.addLine(to: CGPoint(x: geo.size.width, y: 0))
                            path.addLine(to: CGPoint(x: 0, y: geo.size.height))
                            path.closeSubpath()
                        }
                    }
                )
        }
    }

}
