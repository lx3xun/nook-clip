import SwiftUI
import AppKit

// MARK: - 预览区工具栏（40px · 收藏/删除带文案 · 悬浮提示快捷键）

struct PreviewToolbar: View {
    var isFavorite: Bool = false
    var item: ClipboardRowModel? = nil
    var contentText: String? = nil
    var showQRCode: Bool = false
    var onToggleQRCode: (() -> Void)? = nil
    var onFavorite: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil


    /// 磁盘派生元信息（trailingInfo 异步加载，body 内不做同步磁盘 IO · 契约 C8/FR-019）
    private struct DiskDerivedMeta: Equatable {
        /// 文件条目路径存在性（nil = 非文件条目或判定未完成；判定中不显示打开/失效按钮，最终一致）
        var filesExist: Bool?
        /// 图片条目像素尺寸文案（nil = 非图片条目或未读出；期间回退徽标/分类文案）
        var imagePixelSize: String?

        static let empty = DiskDerivedMeta(filesExist: nil, imagePixelSize: nil)
    }

    @State private var diskMeta = DiskDerivedMeta.empty

    var body: some View {
        HStack(spacing: 8) {
            if let item {
                leadingMeta(item)
            }
            Spacer(minLength: 8)
            if let item {
                trailingInfo(item)
            }
            HStack(spacing: 4) {
                ToolbarFavoriteButton(isFavorite: isFavorite) {
                    onFavorite?()
                }
                // 别名（重命名）入口仅在列表行内（⌘R / 右键菜单），预览区不放
                ToolbarDeleteButton {
                    onDelete?()
                }
            }
        }
        .padding(.horizontal, 20)
        .frame(height: NookClip.heightToolbar)
        // 按条目（+影响路径的文本）异步加载磁盘派生元信息；切换条目自动取消重载
        .task(id: metaTaskKey) {
            await loadDiskDerivedMeta()
        }
    }

    /// 顶栏左侧：来源图标 · 来源应用 · 相对时间 · 复制次数（合并原独立元信息行）
    private func leadingMeta(_ item: ClipboardRowModel) -> some View {
        HStack(spacing: 6) {
            AppIconBadge(app: item.source, size: 15)
            Text(L10n.tr("preview.meta_line", item.sourceDisplayName, RelativeTime.string(from: item.lastUsedAt), String(item.copyCount)))
                .font(.nookClipMeta)
                .monospacedDigit()
                .foregroundStyle(NookClip.textSecondary)
                .lineLimit(1)
        }
    }

    private var metaTaskKey: String {
        // 文件条目的可打开性取决于 contentText 中的路径列表（体积小）；其余类型的
        // 磁盘元信息只随条目身份变化。不把全文内容拼进 task id——大文本每次
        // body 求值都要 O(n) 字符串拷贝与比较，点击切换条目时明显卡顿
        guard let item else { return "none" }
        if item.kind == .file {
            return "\(item.id.uuidString)|\(contentText ?? "")"
        }
        return item.id.uuidString
    }

    private func loadDiskDerivedMeta() async {
        guard let item else {
            diskMeta = .empty
            return
        }
        let isFile = item.kind == .file
        let isImage = item.kind == .image
        let payloadPath = item.payloadPath
        let text = contentText
        // 磁盘判定（fileExists / 图片尺寸元数据读取）放后台线程，主线程只写状态；
        // 尺寸经 CGImageSource 只读元数据（不解码全图），与预览正文元信息行同源（像素值）
        let meta = await Task.detached(priority: .userInitiated) { () -> DiskDerivedMeta in
            if isFile {
                let filePaths = (payloadPath ?? text)?
                    .components(separatedBy: "\n").filter { !$0.isEmpty } ?? []
                if filePaths.isEmpty { return .empty }
                return DiskDerivedMeta(
                    filesExist: filePaths.allSatisfy { FileManager.default.fileExists(atPath: $0) },
                    imagePixelSize: nil
                )
            }
            if isImage, let path = payloadPath, !path.isEmpty,
               let dims = FileStore.pixelDimensions(atPath: path) {
                return DiskDerivedMeta(
                    filesExist: nil,
                    imagePixelSize: "\(dims.width) × \(dims.height)"
                )
            }
            return .empty
        }.value
        diskMeta = meta
    }

    @ViewBuilder
    private func trailingInfo(_ item: ClipboardRowModel) -> some View {
        HStack(spacing: 8) {
            switch item.kind {
            case .url:
                if let urlString = contentText ?? (item.summary.isEmpty ? nil : item.summary),
                   let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
                   let scheme = url.scheme?.lowercased(),
                   scheme == "http" || scheme == "https" {
                    ToolbarActionButton(
                        title: L10n.tr("preview.open_link"),
                        icon: NookClipIcon.Action.openExternal
                    ) {
                        NSWorkspace.shared.open(url)
                    }
                    ToolbarActionButton(
                        title: L10n.tr("preview.qrcode.button"),
                        icon: NookClipIcon.Action.qrcode,
                        isActive: showQRCode
                    ) {
                        onToggleQRCode?()
                    }
                }
                metaPill(text: "URL")

            case .file:
                let filePaths = (item.payloadPath ?? contentText)?
                    .components(separatedBy: "\n").filter { !$0.isEmpty } ?? []
                if !filePaths.isEmpty, diskMeta.filesExist == true {
                    ToolbarActionButton(
                        title: L10n.tr("preview.action.open"),
                        icon: NookClipIcon.Action.openExternal
                    ) {
                        filePaths.map { URL(fileURLWithPath: $0) }.forEach { NSWorkspace.shared.open($0) }
                    }
                    ToolbarActionButton(
                        title: L10n.tr("preview.action.reveal_in_finder"),
                        icon: NookClipIcon.Action.revealInFinder
                    ) {
                        NSWorkspace.shared.activateFileViewerSelecting(filePaths.map { URL(fileURLWithPath: $0) })
                    }
                } else if !filePaths.isEmpty, diskMeta.filesExist == false {
                    // 原文件已不存在：明示失效，不再提供打开/访达按钮
                    metaPill(text: L10n.tr("file.missing.badge"), isWarning: true)
                }
                metaPill(text: L10n.tr("category.file"))

            case .image:
                if let pixelSize = diskMeta.imagePixelSize {
                    metaPill(text: pixelSize)
                } else if let badge = item.badge {
                    metaPill(text: badge.label)
                } else {
                    metaPill(text: L10n.tr("category.image"))
                }

            case .color:
                if let hex = item.colorHex {
                    metaPill(text: hex)
                } else {
                    metaPill(text: L10n.tr("category.color"))
                }

            case .sensitive:
                metaPill(text: L10n.tr("category.sensitive"), isWarning: true)

            case .code, .json, .text:
                if let text = contentText ?? (item.summary.isEmpty ? nil : item.summary) {
                    let chars = text.count
                    let lines = text.components(separatedBy: "\n").count
                    let label = lines > 1
                        ? L10n.tr("preview.lines_and_chars", lines, chars)
                        : L10n.tr("preview.characters", chars)
                    metaPill(text: label)
                }
            }
        }
    }

    private func metaPill(text: String, isWarning: Bool = false) -> some View {
        Text(text)
            .font(.nookClipMeta)
            .monospacedDigit()
            .foregroundStyle(isWarning ? NookClip.colorSensitive : NookClip.textTertiary)
            .padding(.horizontal, 4)
    }
}
/// 预览区工具栏即时悬停微气泡（80ms 极速浮现，移出立即关闭）
struct InstantTooltipBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.nookClipBadge)
            .foregroundStyle(NookClip.textPrimary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3.5)
            .background {
                RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                            .fill(NookClip.bgPopover)
                    }
                    .shadow(color: Color.black.opacity(0.14), radius: 4, y: 2)
            }
            .overlay {
                RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                    .strokeBorder(NookClip.borderHairline, lineWidth: 0.5)
            }
            .fixedSize()
            .offset(y: 25)
            .allowsHitTesting(false)
            .zIndex(999)
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }
}

/// 预览区工具栏通用操作按钮（Icon-Only · 24×24pt 微圆角，带即时微气泡）
private struct ToolbarActionButton: View {
    let title: String
    let icon: String
    var isActive: Bool = false
    let action: () -> Void

    @State private var isHovered = false
    @State private var showTooltip = false
    @State private var tooltipTask: Task<Void, Never>?

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: NookClipIconSize.compactMedium))
                .foregroundStyle(
                    isActive
                        ? NookClip.accent
                        : (isHovered ? NookClip.textPrimary : NookClip.textSecondary)
                )
                .frame(width: 24, height: 24)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            isActive
                                ? NookClip.bgRowSelected
                                : (isHovered ? NookClip.bgRowOn : Color.clear)
                        )
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering in
            withAnimation(NookClip.animHover) {
                isHovered = hovering
            }
            tooltipTask?.cancel()
            if hovering {
                tooltipTask = Task {
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    if !Task.isCancelled {
                        withAnimation(.easeOut(duration: 0.12)) {
                            showTooltip = true
                        }
                    }
                }
            } else {
                withAnimation(.easeOut(duration: 0.08)) {
                    showTooltip = false
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if showTooltip {
                InstantTooltipBubble(text: title)
            }
        }
        .accessibilityLabel(title)
    }
}

/// 预览区工具栏操作按钮：收藏（Icon-Only · 24×24pt，未收藏中性灰度，悬停微光；收藏后琥珀金实心徽标，带即时微气泡）
private struct ToolbarFavoriteButton: View {
    let isFavorite: Bool
    let action: () -> Void

    @State private var isHovered = false
    @State private var showTooltip = false
    @State private var tooltipTask: Task<Void, Never>?

    var body: some View {
        Button(action: action) {
            Image(systemName: isFavorite ? NookClipIcon.Action.favoriteFilled : (isHovered ? NookClipIcon.Action.favoriteFilled : NookClipIcon.Action.favorite))
                .font(.system(size: NookClipIconSize.compactMedium, weight: isFavorite ? .semibold : .medium))
                .foregroundStyle(isFavorite ? NookClip.colorFavorite : (isHovered ? NookClip.colorFavorite : NookClip.textSecondary))
                .frame(width: 24, height: 24)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            isFavorite
                                ? (isHovered ? NookClip.bgFavoriteActiveHover : NookClip.bgFavoriteActive)
                                : (isHovered ? NookClip.bgRowOn : Color.clear)
                        )
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering in
            withAnimation(NookClip.animHover) {
                isHovered = hovering
            }
            tooltipTask?.cancel()
            if hovering {
                tooltipTask = Task {
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    if !Task.isCancelled {
                        withAnimation(.easeOut(duration: 0.12)) {
                            showTooltip = true
                        }
                    }
                }
            } else {
                withAnimation(.easeOut(duration: 0.08)) {
                    showTooltip = false
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if showTooltip {
                InstantTooltipBubble(text: "\(L10n.tr(isFavorite ? "context.unfavorite" : "hints.favorite")) (⌘S)")
            }
        }
        .accessibilityLabel(L10n.tr(isFavorite ? "hints.favorited" : "hints.favorite"))
        .accessibilityHint(L10n.tr(isFavorite ? "preview.toolbar.unfavorite.hint" : "preview.toolbar.favorite.hint"))
    }
}

/// 预览区工具栏操作按钮：删除（Icon-Only · 24×24pt，平时中性克制融入工具栏，悬停提供柔和警示红底与高亮，带即时微气泡）
private struct ToolbarDeleteButton: View {
    let action: () -> Void

    @State private var isHovered = false
    @State private var showTooltip = false
    @State private var tooltipTask: Task<Void, Never>?

    var body: some View {
        Button(action: action) {
            Image(systemName: isHovered ? NookClipIcon.Action.deleteFilled : NookClipIcon.Action.delete)
                .font(.system(size: NookClipIconSize.compactMedium))
                .foregroundStyle(isHovered ? NookClip.colorDanger : NookClip.textSecondary)
                .frame(width: 24, height: 24)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? NookClip.bgDangerHover : Color.clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering in
            withAnimation(NookClip.animHover) {
                isHovered = hovering
            }
            tooltipTask?.cancel()
            if hovering {
                tooltipTask = Task {
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    if !Task.isCancelled {
                        withAnimation(.easeOut(duration: 0.12)) {
                            showTooltip = true
                        }
                    }
                }
            } else {
                withAnimation(.easeOut(duration: 0.08)) {
                    showTooltip = false
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if showTooltip {
                InstantTooltipBubble(text: "\(L10n.tr("hints.delete")) (⌘⌫)")
            }
        }
        .accessibilityLabel(L10n.tr("hints.delete"))
        .accessibilityHint(L10n.tr("preview.toolbar.delete.hint"))
    }
}
