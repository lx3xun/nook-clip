import SwiftUI
import CoreImage.CIFilterBuiltins

// MARK: - 链接二维码（CIQRCodeGenerator 纯函数生成 + 预览区卡片）

/// 二维码生成：CoreImage CIQRCodeGenerator，无第三方依赖。
/// 输出按目标像素整数倍放大（保持模块边缘锐利），NSCIImageRep 转 NSImage。
enum QRCodeGenerator {
    /// 生成二维码图片；文本为空或滤镜失败返回 nil
    static func image(for text: String, targetPixel: CGFloat = 480) -> NSImage? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(cleaned.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage, output.extent.width > 0 else { return nil }

        let scale = max(1, (targetPixel / output.extent.width).rounded(.up))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// 预览区二维码卡片：白底承载（扫码对比度要求，深色模式同样白底）
struct QRCodeCard: View {
    let text: String

    var body: some View {
        HStack(spacing: 16) {
            if let image = QRCodeGenerator.image(for: text) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 144, height: 144)
                    .padding(10)
                    .background(NookClip.bgQRCodeCanvas, in: RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                            .strokeBorder(NookClip.borderHairline, lineWidth: 0.5)
                    }
            } else {
                // 生成失败（文本超二维码容量上限或滤镜失败）：明确提示而非
                // 空白卡片（审计 BUG-041）
                VStack(spacing: 8) {
                    Image(systemName: NookClipIcon.Empty.qrcode)
                        .font(.system(size: NookClipIconSize.heroLarge))
                        .foregroundStyle(NookClip.textTertiary)
                    Text(L10n.tr("preview.qrcode.unavailable"))
                        .font(.nookClipMeta)
                        .foregroundStyle(NookClip.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(width: 164, height: 164)
                .background(NookClip.bgInset, in: RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: NookClipIcon.Action.qrcode)
                        .font(.system(size: NookClipIconSize.compactMedium, weight: .medium))
                        .foregroundStyle(NookClip.accent)
                    Text(L10n.tr("preview.qrcode.button"))
                        .font(.nookClipSubheadMedium)
                        .foregroundStyle(NookClip.textPrimary)
                }
                Text(L10n.tr("preview.qrcode.hint"))
                    .font(.nookClipMeta)
                    .foregroundStyle(NookClip.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(NookClip.bgInset)
        .clipShape(RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                .strokeBorder(NookClip.borderHairline, lineWidth: 0.5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
