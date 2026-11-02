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

    /// 展示用图标：仅读 NSCache，未命中先给中性占位图标，由 .task 后台预取后写回。
    /// AppKit 图标对象本身要求主线程持有，但取盘读文件这一步挪到后台，
    /// 主线程只做最终的对象创建/赋值（滚动大目录不再逐行卡在读盘上）。
    private var displayIcon: NSImage {
        if let cachedIcon { return cachedIcon }
        return Self.placeholderIcon
    }

    /// 通用中性占位（纯内存，不读盘）
    private static let placeholderIcon: NSImage = {
        let size = NSSize(width: 32, height: 32)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        image.size = size
        return image
    }()

    /// 主线程按扩展名批量预热常用图标：NSWorkspace.icon(forFile:) 只对
    /// 存在的文件读盘；常用扩展名各取一次后进 NSCache，滚动时直接命中。
    private static let commonExtensions: [String] = [
        "txt", "md", "pdf", "png", "jpg", "jpeg", "gif", "webp", "heic",
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "zip", "json", "csv",
    ]

    private static func prefetchIcon(forPath path: String) {
        guard iconCache.object(forKey: path as NSString) == nil else { return }
        let ext = (path as NSString).pathExtension.lowercased()
        if commonExtensions.contains(ext) {
            // 常用扩展名：按 UTType 取类型图标（无文件 IO 依赖路径存在性）
            if let utType = UTType(filenameExtension: ext) {
                let icon = NSWorkspace.shared.icon(for: utType)
                iconCache.setObject(icon, forKey: path as NSString)
            }
            return
        }
        // 少见扩展名：读盘取真实文件图标，但只在后台任务里进入本函数
        let icon = NSWorkspace.shared.icon(forFile: path)
        iconCache.setObject(icon, forKey: path as NSString)
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
            exists = fileExists
            // 图标预取：常用扩展名零 IO，少见扩展名读盘但已离开滚动热路径
            Self.prefetchIcon(forPath: rowPath)
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
