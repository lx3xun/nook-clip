import AppKit
import SwiftUI

// MARK: - 应用预览区卡片（展示大图标、元数据与打开快捷按钮）

@MainActor
struct AppPreviewPane: View {
    let app: InstalledApp
    var onOpen: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏：应用名称与打开按钮
            HStack(spacing: 8) {
                Text(app.name)
                    .font(.nookClipTitle)
                    .foregroundStyle(NookClip.textPrimary)
                    .lineLimit(1)

                Spacer()

                Button {
                    onOpen()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 11, weight: .semibold))
                        Text(L10n.tr("app.action_open"))
                            .font(.nookClipBodyMedium)
                        Text(verbatim: "⏎")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(NookClip.textTertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background {
                        Capsule()
                            .fill(NookClip.accent.opacity(0.15))
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            .background(NookClip.bgPopover)

            // 详情内容
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 20) {
                    // 大图标与标题
                    VStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 80, height: 80)
                            .shadow(color: Color.black.opacity(0.15), radius: 6, x: 0, y: 3)

                        VStack(spacing: 4) {
                            Text(app.name)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(NookClip.textPrimary)

                            if !app.englishName.isEmpty, app.englishName != app.name {
                                Text(app.englishName)
                                    .font(.nookClipBody)
                                    .foregroundStyle(NookClip.textSecondary)
                            }
                        }
                    }
                    .padding(.top, 24)

                    // 属性信息卡片
                    VStack(alignment: .leading, spacing: 12) {
                        if let bundleID = app.bundleIdentifier, !bundleID.isEmpty {
                            metadataRow(
                                title: L10n.tr("app.bundle_id"),
                                value: bundleID,
                                copyable: true
                            )
                        }

                        metadataRow(
                            title: L10n.tr("app.path"),
                            value: app.path,
                            copyable: true
                        )
                    }
                    .padding(14)
                    .background {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(NookClip.bgInset)
                    }
                    .padding(.horizontal, 16)

                    // 底部大操作按钮
                    Button {
                        onOpen()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 13, weight: .semibold))
                            Text(L10n.tr("app.open_hint"))
                                .font(.nookClipBodyMedium)
                        }
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(NookClip.accent)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)

                    Spacer(minLength: 20)
                }
            }
        }
    }

    private func metadataRow(title: String, value: String, copyable: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.nookClipMeta)
                .foregroundStyle(NookClip.textTertiary)

            Text(verbatim: value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(NookClip.textSecondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }
}
