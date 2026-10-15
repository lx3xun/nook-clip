import SwiftUI

// MARK: - US6 色值卡片（同原型 ColorPaletteCard · 色值来自 item 真实数据）

@MainActor
struct ColorPreviewCard: View {
    let item: ClipboardRowModel
    /// 预览数据出口（色值复制）
    private let previewData = PreviewDataProvider.live

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 大色块（84pt · 1pt 描边 + 顶部微高光）
            if let swatch = item.swatchColor {
                RoundedRectangle(cornerRadius: NookClip.radiusCard, style: .continuous)
                    .fill(swatch)
                    .frame(height: 88)
                    .overlay {
                        RoundedRectangle(cornerRadius: NookClip.radiusCard, style: .continuous)
                            .strokeBorder(NookClip.borderHairline, lineWidth: 0.5)
                    }
                    .padding(.bottom, 12)
            }

            // 数值行（点击即复制 · 经 PasteService）
            VStack(spacing: 4) {
                valueRow(label: "HEX", value: item.colorHex ?? "")
                valueRow(label: "RGB", value: item.rgbValue ?? "")
            }

            // 说明
            Text(L10n.tr("preview.color.hint"))
                .font(.nookClipCaption)
                .foregroundStyle(NookClip.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 8, leading: 2, bottom: 0, trailing: 2))
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: NookClip.radiusCard, style: .continuous)
                .fill(NookClip.bgInset)
        }
    }

    /// 当前展示「已复制」反馈的数值行（label），nil 表示无反馈
    @State private var copiedFormat: String?

    private func valueRow(label: String, value: String) -> some View {
        let copied = copiedFormat == label
        return Button {
            if previewData.copyText(value) {
                copiedFormat = label
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    if copiedFormat == label { copiedFormat = nil }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(label)
                    .font(.nookClipMono(10, .medium))
                    .kerning(0.4)
                    .foregroundStyle(NookClip.textTertiary)
                    .frame(width: 30, alignment: .leading)
                Text(verbatim: value)
                    .font(.nookClipMono(13))
                    .foregroundStyle(NookClip.textPrimary)
                Spacer(minLength: 0)
                if copied {
                    Text(L10n.tr("preview.copied_feedback"))
                        .font(.nookClip(10))
                        .foregroundStyle(NookClip.colorSuccess)
                }
                Image(systemName: copied ? NookClipIcon.Action.copied : NookClipIcon.Action.copy)
                    .font(.system(size: NookClipIconSize.compact))
                    .foregroundStyle(copied ? NookClip.colorSuccess : NookClip.textTertiary)
            }
            .padding(.horizontal, 2)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}
