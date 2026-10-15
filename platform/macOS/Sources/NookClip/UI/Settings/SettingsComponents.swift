import AppKit
import SwiftUI

// MARK: - 设置分组卡片与行布局组件

/// 设置分组卡片：新版系统设置观感——卡片上方小号次要色分组标题、
/// 无描边填充卡、圆角 10，行间发丝分隔线
struct SettingsSectionView<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.nookClipMetaMedium)
                .foregroundStyle(NookClip.textSecondary)
                .padding(.leading, 6)

            VStack(spacing: 0) {
                content()
            }
            // 内容窄时（如纯 Label 列表）也要撑满卡片宽度，
            // 否则被外层居中成窄卡，与其他分组左右不对齐
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: NookClip.radiusPanel, style: .continuous)
                    .fill(NookClip.bgContent)
            }
            .clipShape(RoundedRectangle(cornerRadius: NookClip.radiusPanel, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: NookClip.radiusPanel, style: .continuous)
                    .strokeBorder(NookClip.borderHairline, lineWidth: 0.5)
            }
        }
    }
}

/// 设置行左侧标准文案：13pt 标题 + 可选 11pt 副标题（与各 Tab 原内联写法逐像素一致）
struct SettingsRowTitle: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.nookClipBody)
                .foregroundStyle(NookClip.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(.nookClipMeta)
                    .foregroundStyle(NookClip.textSecondary)
            }
        }
    }
}

struct SettingsRowView<Leading: View, Trailing: View>: View {
    var showDivider: Bool
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    init(
        showDivider: Bool = false,
        @ViewBuilder leading: @escaping () -> Leading,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.showDivider = showDivider
        self.leading = leading
        self.trailing = trailing
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                leading()
                Spacer(minLength: 8)
                trailing()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if showDivider {
                Rectangle()
                    .fill(NookClip.separator)
                    .frame(height: 0.5)
                    .padding(.leading, 16)
            }
        }
    }
}

extension SettingsRowView where Leading == SettingsRowTitle {
    /// 便捷 init：标准「标题 + 可选副标题 + 右侧控件」行，替代各处手写的
    /// VStack(13pt 标题 + 11pt 副标题) 样板
    init(
        title: String,
        subtitle: String? = nil,
        showDivider: Bool = false,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.init(
            showDivider: showDivider,
            leading: { SettingsRowTitle(title: title, subtitle: subtitle) },
            trailing: trailing
        )
    }
}

// MARK: - 原生系统开关样式

/// 对齐 macOS 原生开关规范（.toggleStyle(.switch)），完全支持系统无障碍、高对比度与键盘交互
extension ToggleStyle where Self == SwitchToggleStyle {
    static var nookSwitch: SwitchToggleStyle { SwitchToggleStyle() }
}
