import SwiftUI

// MARK: - US3 敏感脱敏卡片（同原型 maskCard，密文/明文来自真实数据）

@MainActor
struct SensitiveMaskCard: View {
    let maskedText: String
    let revealedText: String?
    let isRevealed: Bool
    var countdownSeconds: Int = 0
    /// 查看失败原因（授权被拒 ≠ 密文损坏）：正文位置改显对应提示
    var revealFailure: ClipboardItem.RevealFailure?
    /// 粘完即焚提示里展示的兜底秒数（默认 30，调用方传入 sensitiveClipboardTimeout）
    var autoBurnSeconds: Int = 30
    /// 「保留此条」动作（nil = 不渲染该按钮，保证既有调用点无需改动）
    var onKeep: (() -> Void)? = nil
    /// 「立即焚毁」动作（nil = 不渲染该按钮）
    var onBurn: (() -> Void)? = nil
    let onToggle: () -> Void
    @State private var didKeep = false

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: NookClipIcon.Sensitive.lock)
                .font(.system(size: NookClipIconSize.titleDisplay))
                .foregroundStyle(NookClip.colorSensitive)
            Text(L10n.tr("preview.mask.title"))
                .font(.nookClip(12, .medium))
                .foregroundStyle(NookClip.textPrimary)
                .padding(.top, 9)
            if let failure = revealFailure {
                Text(L10n.tr(failure == .keyUnavailable
                    ? "preview.mask.reveal_denied"
                    : "preview.mask.reveal_error"))
                    .font(.nookClipMono(13))
                    .foregroundStyle(NookClip.colorDanger)
                    .lineLimit(2)
                    .padding(.top, 6)
            } else if isRevealed {
                // 明文态：完整展示（超长内滚动）+ 可选中复制；30s 自动重新遮罩不变
                ScrollView(.vertical, showsIndicators: true) {
                    Text(verbatim: revealedText ?? "")
                        .font(.nookClipMono(13, .medium))
                        .foregroundStyle(NookClip.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                }
                .frame(maxHeight: 280)
                .background(NookClip.bgInset, in: RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.top, 8)
            } else {
                Text(verbatim: maskedText)
                    .font(.nookClipMono(14))
                    .foregroundStyle(NookClip.textSecondary)
                    .lineLimit(2)
                    .padding(.top, 6)
            }

            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: isRevealed ? NookClipIcon.Sensitive.remask : NookClipIcon.Sensitive.reveal)
                        .font(.system(size: NookClipIconSize.compactMedium, weight: .medium))
                    Text(buttonTitle)
                }
                .font(.nookClipSubheadMedium)
                .foregroundStyle(isRevealed ? NookClip.accent : NookClip.colorSensitive)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                        .fill(isRevealed ? NookClip.bgChipSelected : NookClip.colorSensitive.opacity(0.14))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .padding(.top, 12)

            autoBurnHint
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background {
            RoundedRectangle(cornerRadius: NookClip.radiusCard, style: .continuous)
                .fill(NookClip.bgCode)
        }
    }
    /// 卡片底部的「粘完即焚」说明条：
    /// 一句说明（秒数由调用方传入），外加可选的两个动作按钮。
    /// 两个闭包都为 nil 时整行按钮不渲染，既有调用点外观保持不变。
    @ViewBuilder
    private var autoBurnHint: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: NookClipIcon.AutoBurn.burn)
                    .font(.system(size: NookClipIconSize.micro, weight: .semibold))
                    .foregroundStyle(NookClip.colorSensitive)
                Text(L10n.tr("preview.autoburn.hint", autoBurnSeconds))
                    .font(.nookClipCaption)
                    .foregroundStyle(NookClip.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            let activeOnKeep = didKeep ? nil : onKeep
            if activeOnKeep != nil || onBurn != nil {
                HStack(spacing: 10) {
                    if let activeOnKeep {
                        autoBurnButton(
                            title: L10n.tr("preview.autoburn.keep"),
                            isDanger: false,
                            action: {
                                didKeep = true
                                activeOnKeep()
                            }
                        )
                    }
                    if let onBurn {
                        autoBurnButton(
                            title: L10n.tr("preview.autoburn.burn"),
                            isDanger: true,
                            action: onBurn
                        )
                    }
                }
            }
        }
        .padding(.top, 14)
        .padding(.horizontal, 16)
    }

    private func autoBurnButton(
        title: String,
        isDanger: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.nookClipSubheadMedium)
                .foregroundStyle(isDanger ? NookClip.colorDanger : NookClip.textSecondary)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                        .fill(isDanger ? NookClip.bgDangerSubtle : NookClip.bgRowOn)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    private var buttonTitle: String {
        guard isRevealed else { return L10n.tr("preview.mask.reveal") }
        if countdownSeconds > 0 {
            return L10n.tr("preview.mask.remask_countdown", countdownSeconds)
        }
        return L10n.tr("preview.mask.remask")
    }
}
