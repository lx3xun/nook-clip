import SwiftUI

// MARK: - US6 文件列表卡片（多文件逐条 · 系统类型图标 / 名称 / 路径 / 大小 / 复制路径）

@MainActor
struct FilePreviewCard: View {
    let paths: [String]


    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(paths.enumerated()), id: \.offset) { index, path in
                if index > 0 {
                    Rectangle().fill(NookClip.separator).frame(height: 0.5)
                }
                FilePreviewRow(path: path)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: NookClip.radiusCard, style: .continuous)
                .fill(NookClip.bgInset)
        }
    }
}

@MainActor
struct FilePreviewRow: View {
    let path: String
    /// 预览数据出口（文件元数据/剪贴板复制）
    private let previewData = PreviewDataProvider.live

    @State private var sizeText: String?
    @State private var copied = false
    @State private var hovered = false

    /// 系统文件类型图标缓存（主线程访问；容量上限 128，缺失文件返回通用文档图标）
    @MainActor private static let iconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 128
        return cache
    }()

    private var exists: Bool { previewData.fileExists(atPath: path) }

    @MainActor
    private static func icon(for path: String) -> NSImage {
        let key = path as NSString
        if let cached = iconCache.object(forKey: key) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        iconCache.setObject(icon, forKey: key)
        return icon
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // 首行：图标 + 文件名 + 大小 + 复制按钮；路径不与图标挤同行，
            // 独占下方整行宽度换行展示（长路径不再中截断）
            HStack(alignment: .center, spacing: 9) {
                Image(nsImage: Self.icon(for: path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 20, height: 20)
                Text(verbatim: (path as NSString).lastPathComponent)
                    .font(.nookClip(12, .medium))
                    .foregroundStyle(exists ? NookClip.textPrimary : NookClip.colorDanger)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let sizeText {
                    Text(sizeText)
                        .font(.nookClip(10))
                        .monospacedDigit()
                        .foregroundStyle(NookClip.textTertiary)
                        .lineLimit(1)
                }
                copyButton
            }
            // 完整路径：自动换行展示全文（无空格长路径实测可按字符折行），
            // 与文件名列对齐（图标 20 + 间距 9）
            Text(verbatim: path)
                .font(.nookClipMono(10))
                .foregroundStyle(exists ? NookClip.textTertiary : NookClip.colorDanger.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.leading, 29)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        // 行内大小懒加载：磁盘 IO 后台执行（仿 RowThumbnailView / FileSizeText 先例）
        .task(id: path) {
            let provider = previewData
            let size = await Task.detached(priority: .utility) {
                provider.fileSize(atPath: path)
            }.value
            if size > 0 {
                sizeText = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            }
        }
    }

    /// 悬停显示的复制路径按钮（经 PasteService 契约 C2 · 2s 已复制反馈）
    private var copyButton: some View {
        Button {
            if previewData.copyText(path) {
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            }
        } label: {
            Image(systemName: copied ? NookClipIcon.Action.copied : NookClipIcon.Action.copy)
                .font(.system(size: NookClipIconSize.compact))
                .foregroundStyle(copied ? NookClip.colorSuccess : NookClip.textSecondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(L10n.tr("preview.copy_path"))
        .opacity(hovered || copied ? 1 : 0)
    }
}
