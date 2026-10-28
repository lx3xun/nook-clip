import SwiftUI

// MARK: - 粘完即焚状态徽章（列表敏感行 / 预览卡片共用）
//
// 这里只负责「把状态画出来」，不持有任何计时逻辑：一条内容到底处于
// 验证码提纯、倒计时擦除还是已保留，由调度器判断后通过 style 传进来。
// 这样列表行不需要知道剪贴板何时被擦除，视觉也不会跟真实状态打架。

struct AutoBurnBadge: View {
    /// 三种展示档位
    enum Style: Equatable {
        /// 验证码：火焰 + 「验证码」
        case otp
        /// 倒计时擦除：火焰 + 「剪贴板 N 秒后擦除」
        case clearing
        /// 已保留：手掌 + 「已保留」
        case keep
    }

    let style: Style
    /// `.clearing` 专用：剩余秒数（其它档位忽略）
    var seconds: Int = 0
    /// 行处于实底强调色选中态时，文字与图标需反白
    var isOnSolidAccent: Bool = false
    /// 自定义无障碍朗读文案；nil 时用「粘完即焚状态 + 当前档位文字」
    var accessibilityText: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: iconName)
                .font(.system(size: NookClipIconSize.micro, weight: .semibold))
            Text(text)
                .font(.nookClip(10, .medium))
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 5)
        .frame(height: 16)
        .background(
            background,
            in: RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText ?? "\(L10n.tr("a11y.autoburn.badge"))：\(text)")
    }

    /// 火焰代表「会烧掉」，手掌代表「按住不让它烧」——与火焰语义相反。
    private var iconName: String {
        switch style {
        case .otp, .clearing: return NookClipIcon.AutoBurn.burn
        case .keep: return NookClipIcon.AutoBurn.keep
        }
    }

    private var text: String {
        switch style {
        case .otp: return L10n.tr("row.autoburn.badge_otp")
        case .clearing: return L10n.tr("row.autoburn.badge_clearing", seconds)
        case .keep: return L10n.tr("row.autoburn.badge_keep")
        }
    }

    private var foreground: Color {
        if isOnSolidAccent { return NookClip.textOnAccent }
        switch style {
        case .otp, .clearing: return NookClip.colorSensitive
        case .keep: return NookClip.textSecondary
        }
    }

    private var background: Color {
        if isOnSolidAccent { return NookClip.bgPillOnAccent }
        switch style {
        case .otp, .clearing: return NookClip.colorSensitive.opacity(0.12)
        case .keep: return NookClip.bgRowOn
        }
    }
}
