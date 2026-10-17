import AppKit
import SwiftUI

// MARK: - 应用搜索结果行视图（52px · 复用 NookClipRowShell · 原生 App 图标与打开指引）

struct AppRowView: View {
    let app: InstalledApp
    let isSelected: Bool
    var selectionNamespace: Namespace.ID? = nil
    var highlightKeywords: [String]? = nil
    var onTap: (() -> Void)? = nil
    var onDoubleTap: (() -> Void)? = nil

    var body: some View {
        NookClipRowShell(
            isSelected: isSelected,
            selectionNamespace: selectionNamespace,
            style: .single,
            accessibilitySummary: app.name,
            onTap: onTap,
            onDoubleTap: onDoubleTap
        ) { _ in
            // 前置瓦片：直接展示 32×32 原生应用图标（不加外框底板，铺满 32×32 前置槽）
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 32, height: 32)
        } title: { isSolid in
            HStack(spacing: 6) {
                SearchHighlight.text(
                    app.name,
                    keywords: highlightKeywords,
                    isOnAccent: isSolid
                )
                .searchHighlightRenderer()
                .font(.nookClipBodyMedium)
                .foregroundStyle(isSolid ? NookClip.textOnAccent : NookClip.textPrimary)
                .lineLimit(1)
            }
        } titleAccessory: { isSolid in
            // 右侧快捷提示：⏎ 打开
            HStack(spacing: 3) {
                Text(L10n.tr("app.action_open"))
                    .font(.nookClipMeta)
                Text(verbatim: "⏎")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(isSolid ? NookClip.textOnAccentSecondary : NookClip.textTertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                Capsule()
                    .fill(isSolid ? Color.white.opacity(0.2) : NookClip.bgInset)
            }
        } subtitle: { isSolid in
            Text(verbatim: app.path)
                .font(.nookClipMeta)
                .foregroundStyle(isSolid ? NookClip.textOnAccentSecondary : NookClip.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
