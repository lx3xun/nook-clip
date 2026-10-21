import SwiftUI
import UniformTypeIdentifiers

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
    /// 文件是否存在：nil = 尚未探测（用中性色，避免缺失文件先显示正常色再闪红）
    @State private var exists: Bool?

    /// 系统文件类型图标缓存（仅主线程访问；容量上限 128）
    @MainActor private static let iconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 128
        return cache
    }()

    private var cachedIcon: NSImage? {
        Self.iconCache.object(forKey: path as NSString)
    }

    private var fallbackIcon: NSImage {
        NSWorkspace.shared.icon(for: .text)
    }

    /// 展示用图标：NSCache 命中即用；未命中在主线程取一次并写回。
    /// 图标是 AppKit 对象（NSWorkspace.icon 要求主线程），不放到后台线程加载。
    private var displayIcon: NSImage {
        if let cachedIcon { return cachedIcon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        Self.iconCache.setObject(icon, forKey: path as NSString)
        return icon
    }

    private var nameColor: Color {
        switch exists {
        case .some(false): return NookClip.colorDanger
        case .some(true): return NookClip.textPrimary
        case .none: return NookClip.textSecondary
        }
    }

    private var pathColor: Color {
        switch exists {
        case .some(false): return NookClip.colorDanger.opacity(0.75)
        case .some(true): return NookClip.textTertiary
        case .none: return NookClip.textTertiary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // 首行：图标 + 文件名 + 大小 + 复制按钮；路径不与图标挤同行，
            // 独占下方整行宽度换行展示（长路径不再中截断）
            HStack(alignment: .center, spacing: 9) {
                Image(nsImage: displayIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 20, height: 20)
                Text(verbatim: (path as NSString).lastPathComponent)
                    .font(.nookClip(12, .medium))
                    .foregroundStyle(nameColor)
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
                .foregroundStyle(pathColor)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.leading, 29)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        // 行内大小、存在性、系统图标统一后台加载：磁盘 IO 不在 body 求值路径上
        .task(id: path) {
            exists = nil
            sizeText = nil
            let provider = previewData
            let rowPath = path
            let (size, fileExists) = await Task.detached(priority: .utility) {
                (provider.fileSize(atPath: rowPath), provider.fileExists(atPath: rowPath))
            }.value
            if size > 0 {
                sizeText = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            }
            // 图标在主线程按需取（displayIcon），后台只做 stat
            exists = fileExists
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
