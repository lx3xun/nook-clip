import SwiftUI
import AppKit

// MARK: - 跨屏共享行内组件（kbd 键帽 / 胶囊徽标 / 来源图标 / 类型图标 / 色点 / 缩略图 / 行文本 / 元信息）
// 迁移自 nook-swiftui 原型 SharedComponents.swift；视觉规格逐项不变，仅替换数据类型与绑定。

/// 快捷键 kbd 键帽（DESIGN.md §6.9：mono 11px、白底 65%、0.5px 描边、下边模拟键帽）
struct KbdView: View {
    let text: String
    var fontSize: CGFloat = 11

    var body: some View {
        Text(text)
            .font(.nookClipMono(fontSize, .medium))
            .foregroundStyle(NookClip.textSecondary)
            .padding(.horizontal, 5)
            .frame(minWidth: fontSize == 11 ? 18 : 16, minHeight: fontSize == 11 ? 17 : 15)
            .background(NookClip.bgKbd)
            .clipShape(RoundedRectangle(cornerRadius: NookClip.radiusThumb, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: NookClip.radiusThumb, style: .continuous)
                    .strokeBorder(NookClip.borderKbd, lineWidth: 0.5)
            }
    }
}

/// 胶囊徽标（PNG / JSON / MD · 10px w500 · radius pill）
struct PillView: View {
    let text: String
    var isAccent: Bool = false
    var isOnAccent: Bool = false

    var body: some View {
        Text(text)
            .font(.nookClipBadge)
            .tracking(0.2)
            .foregroundStyle(isOnAccent ? NookClip.textOnAccentSecondary : (isAccent ? NookClip.accent : NookClip.textTertiary))
    }
}

/// 来源 App 图标（20px；列表行内作为元信息弱化显示、在 32×32 前置槽中居中；优先真实应用图标，解析不到回退原型色块 + SF Symbol）
struct AppIconBadge: View {
    let app: SourceAppModel
    var size: CGFloat = 20

    /// 真实图标解析缓存（bundleID 优先，应用名兜底；主线程访问）
    @MainActor private static var iconCache: [String: NSImage?] = [:]

    @MainActor
    static func clearIconCache() {
        iconCache.removeAll()
    }
    @MainActor
    private static func realAppIcon(for app: SourceAppModel) -> NSImage? {
        let key = app.bundleID ?? "name:\(app.name)"
        if let cached = iconCache[key] { return cached }
        var icon: NSImage?
        if let bundleID = app.bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        }
        if icon == nil {
            // 按应用名在常见安装目录兜底（含中文名直查 /Applications）
            for dir in ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"] {
                let path = "\(dir)/\(app.name).app"
                if FileManager.default.fileExists(atPath: path) {
                    icon = NSWorkspace.shared.icon(forFile: path)
                    break
                }
            }
        }
        iconCache[key] = icon
        return icon
    }

    var body: some View {
        if let icon = Self.realAppIcon(for: app) {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .fill(app.color)
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: app.symbol)
                        .font(.system(size: size * (app.glyphOnLight ? 0.62 : 0.55), weight: .medium))
                        .foregroundStyle(app.symbolColor)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                        .strokeBorder(NookClip.borderHairline, lineWidth: 0.5)
                }
        }
    }
}


/// 行分类图标（32×32 槽内居中、无底色纯符号）：与图片缩略图同规格占位，
/// 来源 App 图标由前置槽统一叠加为右下角小圆角标
struct CategoryIconTile: View {
    let kind: RowKind
    var isSolidSelected: Bool = false

    private var isSemanticWarning: Bool {
        kind == .sensitive
    }

    var body: some View {
        RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
            .fill(
                isSolidSelected
                    ? NookClip.bgPillOnAccent
                    : (isSemanticWarning ? NookClip.colorSensitive.opacity(0.12) : NookClip.bgRowOn)
            )
            .frame(width: 30, height: 30)
            .overlay {
                Image(systemName: kind.categorySymbol)
                    .font(.system(size: NookClipIconSize.regular, weight: .semibold))
                    .foregroundStyle(
                        isSolidSelected
                            ? NookClip.textOnAccent
                            : (isSemanticWarning ? NookClip.colorSensitive : NookClip.textSecondary)
                    )
            }
            .frame(width: 34, height: 34)
    }
}

/// 色值类型行前置色块瓦片（28×28 圆角实时色块 + 描边，直观呈现复制的颜色）
struct ColorSwatchTile: View {
    let color: Color
    var isSolidSelected: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
            .fill(color)
            .frame(width: 30, height: 30)
            .overlay {
                RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                    .strokeBorder(isSolidSelected ? NookClip.textOnAccent.opacity(0.65) : NookClip.borderHairline, lineWidth: isSolidSelected ? 1.5 : 1.0)
            }
            .frame(width: 34, height: 34)
    }
}

/// 来源 App 小圆角标（14px 圆 · bgContent 底 + 发丝描边，行背景变化时仍可读）
struct SourceCornerBadge: View {
    let app: SourceAppModel

    var body: some View {
        AppIconBadge(app: app, size: 15)
            .shadow(color: .black.opacity(0.18), radius: 1, x: 0, y: 0.5)
            .offset(x: 2.5, y: 2.5)
    }
}

/// 行内色点（10px · 1px 内描边）
struct ColorDot: View {
    let color: Color
    var size: CGFloat = 10

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay {
                Circle().strokeBorder(NookClip.borderHairline, lineWidth: 0.5)
            }
    }
}

/// 图片缩略图占位符（32×32 · 真实缩略图缺失或加载失败时回退显示图片类型图标）
struct ThumbnailPlaceholderView: View {
    var isSolidSelected: Bool = false

    var body: some View {
        CategoryIconTile(kind: .image, isSolidSelected: isSolidSelected)
    }
}

/// 图片行真实缩略图（28×28 置中于 32×32 前置槽，与分类图标瓦片 CategoryIconTile 尺寸严丝合缝对齐）
struct RowThumbnailView: View {
    let path: String
    var isSolidSelected: Bool = false
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                            .strokeBorder(NookClip.borderHairline, lineWidth: 0.5)
                    }
            } else {
                ThumbnailPlaceholderView(isSolidSelected: isSolidSelected)
            }
        }
        .frame(width: 34, height: 34)
        .task(id: path) {
            guard image == nil else { return }
            let loaded = await Task.detached(priority: .utility) {
                FileStore.shared.thumbnail(for: path, maxPixelSize: 64)
            }.value
            if let loaded {
                image = loaded
            }
        }
    }
}

/// 标准行标题（支持色点前置 + mono + 格式徽标胶囊 + 搜索命中高亮）
struct RowTitleView: View {
    let item: ClipboardRowModel
    var monoSize: CGFloat = 12
    var isSolidSelected: Bool = false
    /// 搜索命中高亮关键词（nil = 非搜索态，纯文本渲染）
    var highlightKeywords: [String]? = nil

    /// 单行化展示文本：将内部换行与连续空白折叠为单空格，防止首行仅有大括号或极短字符造成列表留白
    private var singleLineDisplayTitle: String {
        let raw = item.displayTitle
        if raw.contains("\n") || raw.contains("\r") {
            return raw
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        return raw
    }

    var body: some View {
        HStack(spacing: 5) {
            SearchHighlight.text(singleLineDisplayTitle, keywords: highlightKeywords, isOnAccent: isSolidSelected)
                .searchHighlightRenderer()
                .lineLimit(1)
                .truncationMode(item.kind == .url || item.kind == .file ? .middle : .tail)
                .font(item.titleMono ? .nookClipMono(monoSize, .medium) : .nookClipBodyMedium)
                .foregroundStyle(isSolidSelected ? NookClip.textOnAccent : (item.isSensitive ? NookClip.colorSensitive : NookClip.textPrimary))
        }
    }
}

/// 列表行副行（展示来源 App 图标与辅助上下文 · 支持搜索高亮）
struct RowSubtitleView: View {
    let item: ClipboardRowModel
    var isSolidSelected: Bool = false
    /// 行是否活跃（悬停或选中）：静止时行内标签不显示，保持列表干净
    var isActive: Bool = false
    var highlightKeywords: [String]? = nil

    /// 按记录类型补充有价值的副行上下文（不重复主标题，不展示复制次数）
    var contextualDetail: String? {
        // 用户自定义了别名（title 非空且与原文不冗余）时，副行补充原文首行或域名/尺寸摘要
        if !item.title.isEmpty && !item.isSubtitleRedundant {
            if let parts = item.urlParts {
                return parts.host + (parts.remainder == "/" ? "" : parts.remainder)
            }
            let cleaned = item.displaySummary
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !cleaned.isEmpty && cleaned != item.displayTitle {
                return cleaned
            }
        }
        switch item.kind {
        case .url:
            if item.title.isEmpty, let parts = item.urlParts, !parts.host.isEmpty {
                return parts.host
            }
        case .color:
            if let rgb = item.rgbValue, !rgb.isEmpty {
                return "RGB(\(rgb))"
            }
        case .file:
            if let firstPath = item.payloadPath?.components(separatedBy: "\n").first, !firstPath.isEmpty {
                let dir = (firstPath as NSString).deletingLastPathComponent
                let shortened = (dir as NSString).abbreviatingWithTildeInPath
                if !shortened.isEmpty && shortened != "/" {
                    return shortened
                }
            }
        default:
            break
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 4) {
            // 副行不再重复「来源图标 + 来源应用名」：来源 App 仅以主图标右下角的小角标呈现，
            // 完整应用名改到右侧预览区顶栏展示。副行整行统一为更浅的 textTertiary、
            // Regular 字重，让高对比度 Medium 主标题一眼跳出来（Spotlight 式层级）。
            // 文件/图片/代码等类型徽标（PNG/MD/JSON/语言）从主标题移到副行开头展示，
            // 主标题只保留纯内容，类型信息归入次级元信息层。
            if let badge = item.badge {
                PillView(text: badge.label, isAccent: badge.isAccent, isOnAccent: isSolidSelected)
                    .fixedSize()
            }
            if let detail = contextualDetail {
                SearchHighlight.text(detail, keywords: highlightKeywords, isOnAccent: isSolidSelected)
                    .searchHighlightRenderer()
                    .font(.nookClipMeta)
                    .foregroundStyle(isSolidSelected ? NookClip.textOnAccentTertiary : NookClip.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // 副行尾部迷你 #tag（最多 2 个，超出 +N）——始终展示，便于一眼看到条目标签
            RowTagsInlineView(
                tags: item.tags,
                maxVisible: 2,
                isSolidSelected: isSolidSelected
            )
        }
    }
}

/// 文件大小文本已移除（P1-3 信息层级收敛）：文件大小改在预览区文件卡展示
/// （FilePreviewCard 自带懒加载），列表行副行只保留路径摘要。

