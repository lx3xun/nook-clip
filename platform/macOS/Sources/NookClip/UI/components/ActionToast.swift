import SwiftUI

// MARK: - 轻量动作反馈条（非阻断 toast）

/// 动作完成后的短暂反馈，如「已脱敏 2 类 3 处 · 邮箱、手机号」。
///
/// 与 `UndoToast` 的区别：撤销条带倒计时条、语义是「还能反悔」；
/// 这里只是「做完了」的确认，因此用单行胶囊 + 成功色盾牌图标，
/// 2 秒后由调用方清空。视觉上沿用 `NookClip.bgPopover` + 细描边 + 轻阴影，
/// 与列表底部的撤销条同一家族，避免出现第二套浮层语言。
struct ActionToast: View {
    /// 图标（SF Symbols 名）
    let systemImage: String
    let message: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: NookClipIconSize.compact))
                .foregroundStyle(NookClip.colorSuccess)
            Text(message)
                .font(.nookClipSubhead)
                .foregroundStyle(NookClip.textPrimary)
                .lineLimit(1)
                // 长摘要（多个规则名）优先压缩字号而不是截断语义
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background {
            RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                .fill(NookClip.bgPopover)
                .overlay {
                    RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                        .strokeBorder(NookClip.separator, lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
        }
        .padding(.bottom, 8)
        .allowsHitTesting(false)
        .accessibilityAddTraits(.isStaticText)
    }
}
