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
    /// 打开标签编辑器（⌘L / 末尾 +）
    var onEditTags: (() -> Void)? = nil
    /// 当前条目标签（顶部直接展示，替代原独立标签行）
    var tags: [String] = []
    /// 点击标签 → 按该标签过滤列表
    var onSelectTag: ((String) -> Void)? = nil
    /// 移除当前条目的某标签（悬停 ×）
    var onRemoveTag: ((String) -> Void)? = nil
    /// 右键标签：全局重命名 / 删除
    var onRenameTag: ((String) -> Void)? = nil
    var onDeleteTag: ((String) -> Void)? = nil
    /// ⌃⏎ 脱敏粘贴：把本条目做语义占位符脱敏后粘贴（US1）
    var onScrubPaste: (() -> Void)? = nil
    /// ⌘P 钉在屏幕：把本条目钉成置顶贴条（US3）
    var onPinToScreen: (() -> Void)? = nil
    /// 当前条目能否脱敏粘贴（图片/文件条目无可脱敏文本，按钮置灰不显示）
    var canScrubPaste: Bool = false
    /// ⌘D 行内对比：对比两条记录的字词级差异
    var onDiff: (() -> Void)? = nil
    /// 当前条目能否参与对比（列表至少 2 条且当前条目含文本或 OCR 文字）
    var canDiff: Bool = false
    /// 手机快传：打开/收起局域网扫码免安装双向快传面板（spec 014 · US1）
    var onPhoneDrop: (() -> Void)? = nil
    /// 手机快传面板是否处于展开态（高亮顶栏按钮，再次点击可收起）
    var isPhoneDropActive: Bool = false


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
            // 左侧：来源应用标识（App 图标 + 应用名）。
            // 列表行内只保留来源 App 的小角标、不再写应用文字名，故完整名称改在此处展示，
            // 与左列互补。
            if let item {
                sourceLabel(item)
            }
            // 类型相关的主操作（打开链接 / 打开文件）。二维码、在访达中显示等低频动作
            // 收进「更多」菜单，避免顶栏堆一排纯图标。
            if let item {
                leadingActions(item)
            }
            // 标签紧邻来源展示：最多 1 个 chip + `+N`，其余在「更多 › 编辑标签」里管理。
            if item != nil {
                tagChips
            }
            Spacer(minLength: 8)
            // 右侧：复制次数 → [含敏感内容时：脱敏粘贴] → 钉在屏幕 → 收藏 → 更多菜单
            if let item {
                copyCountPill(item)
            }
            HStack(spacing: 4) {
                if canScrubPaste, let onScrubPaste {
                    ToolbarActionButton(
                        title: L10n.tr("preview.scrub.button"),
                        shortcut: "⌃⏎",
                        icon: NookClipIcon.Action.scrub,
                        tooltipAlignment: .bottomTrailing,
                        action: onScrubPaste
                    )
                }
                if let onPinToScreen {
                    ToolbarActionButton(
                        title: L10n.tr("preview.pin.button"),
                        shortcut: "⌘P",
                        icon: NookClipIcon.Action.pin,
                        tooltipAlignment: .bottomTrailing,
                        action: onPinToScreen
                    )
                }
                ToolbarFavoriteButton(isFavorite: isFavorite) {
                    onFavorite?()
                }
                if let item {
                    moreMenu(item)
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

    /// 顶栏左侧来源应用标识：App 图标 + 应用名（与列表行右下角小角标互补）。
    @ViewBuilder
    private func sourceLabel(_ item: ClipboardRowModel) -> some View {
        HStack(spacing: 5) {
            AppIconBadge(app: item.source, size: 16)
            Text(item.sourceDisplayName)
                .font(.nookClipMetaMedium)
                .foregroundStyle(NookClip.textSecondary)
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.sourceDisplayName)
    }

    /// 顶栏左侧：类型相关的主操作(打开链接 / 打开文件)。
    /// 二维码、在访达中显示等低频动作改由 `moreMenu` 承载。
    @ViewBuilder
    private func leadingActions(_ item: ClipboardRowModel) -> some View {
        switch item.kind {
        case .url:
            if let url = resolvedURL(item) {
                ToolbarActionButton(
                    title: L10n.tr("preview.open_link"),
                    icon: NookClipIcon.Action.openExternal
                ) {
                    NSWorkspace.shared.open(url)
                }
            }
        case .file:
            let filePaths = resolvedFilePaths(item)
            if !filePaths.isEmpty, diskMeta.filesExist == true {
                ToolbarActionButton(
                    title: L10n.tr("preview.action.open"),
                    icon: NookClipIcon.Action.openExternal
                ) {
                    filePaths.map { URL(fileURLWithPath: $0) }.forEach { NSWorkspace.shared.open($0) }
                }
            } else if !filePaths.isEmpty, diskMeta.filesExist == false {
                // 原文件已不存在：明示失效（不再提供打开/访达按钮）
                metaPill(text: L10n.tr("file.missing.badge"), isWarning: true)
            }
        default:
            EmptyView()
        }
    }

    /// 解析链接类条目的可打开 URL（http/https 才视为有效）。
    private func resolvedURL(_ item: ClipboardRowModel) -> URL? {
        guard item.kind == .url,
              let urlString = contentText ?? (item.summary.isEmpty ? nil : item.summary),
              let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    /// 解析文件类条目的路径列表（payloadPath 优先，其次 contentText 换行分隔）。
    private func resolvedFilePaths(_ item: ClipboardRowModel) -> [String] {
        guard item.kind == .file else { return [] }
        return (item.payloadPath ?? contentText)?
            .components(separatedBy: "\n").filter { !$0.isEmpty } ?? []
    }

    // MARK: - 「更多」菜单
    //
    // 顶栏右侧常驻「钉在屏幕 / 收藏 / 更多」（含敏感内容时额外显示「脱敏粘贴」）；
    // 对比、手机快传、二维码、在访达中显示、编辑标签与删除等动作统一收进这里。
    // 采用纯 SwiftUI Button + AppKit NSMenu 弹出（对齐 GroupHeaderView.showGroupMenu）：
    // 1. 避免 SwiftUI Menu (NSPopUpButton) 在 ImageRenderer 快照中退化为 🚫 占位符；
    // 2. 菜单关闭后主动调 DraggablePanel.restoreKeyboardFocus()，防止 LSUIElement 面板丢失键盘焦点；
    // 3. 快捷键以文字形式附在标题后（如「脱敏粘贴 (⌃⏎)」），按键仍由 PanelKeyActions 统一分发。

    @ViewBuilder
    private func moreMenu(_ item: ClipboardRowModel) -> some View {
        ToolbarMoreButton(
            isActive: isPhoneDropActive || showQRCode,
            buildActions: {
                buildMoreMenuSections(for: item)
            }
        )
    }

    private func buildMoreMenuSections(for item: ClipboardRowModel) -> [[ToolbarMoreAction]] {
        var sections: [[ToolbarMoreAction]] = []
        let advanced = advancedActions(item)
        if !advanced.isEmpty {
            sections.append(advanced)
        }
        let typeSpecific = typeSpecificActions(item)
        if !typeSpecific.isEmpty {
            sections.append(typeSpecific)
        }
        var manage: [ToolbarMoreAction] = []
        if let onEditTags {
            manage.append(ToolbarMoreAction(
                title: L10n.tr("tag.title"),
                icon: NookClipIcon.Action.tag,
                shortcut: "⌘L",
                action: onEditTags
            ))
        }
        if let onDelete {
            manage.append(ToolbarMoreAction(
                title: L10n.tr("hints.delete"),
                icon: NookClipIcon.Action.delete,
                shortcut: "⌘⌫",
                isDestructive: true,
                action: onDelete
            ))
        }
        if !manage.isEmpty {
            sections.append(manage)
        }
        return sections
    }

    /// 与当前条目无关、只要有文本/列表就能用的进阶动作。
    private func advancedActions(_ item: ClipboardRowModel) -> [ToolbarMoreAction] {
        var actions: [ToolbarMoreAction] = []
        if canDiff, let onDiff {
            actions.append(ToolbarMoreAction(
                title: L10n.tr("preview.diff.button"),
                icon: NookClipIcon.Action.diff,
                shortcut: "⌘D",
                action: onDiff
            ))
        }
        if let onPhoneDrop, !(item.kind == .file && diskMeta.filesExist == false) {
            actions.append(ToolbarMoreAction(
                title: L10n.tr("preview.phone_drop.button"),
                icon: NookClipIcon.Action.phoneDrop,
                isActive: isPhoneDropActive,
                action: onPhoneDrop
            ))
        }
        return actions
    }

    /// 仅在特定内容类型下出现的动作（二维码 / 在访达中显示）。
    private func typeSpecificActions(_ item: ClipboardRowModel) -> [ToolbarMoreAction] {
        switch item.kind {
        case .url:
            if resolvedURL(item) != nil, let onToggleQRCode {
                return [ToolbarMoreAction(
                    title: L10n.tr("preview.qrcode.button"),
                    icon: NookClipIcon.Action.qrcode,
                    isActive: showQRCode,
                    action: onToggleQRCode
                )]
            }
        case .file:
            let filePaths = resolvedFilePaths(item)
            if !filePaths.isEmpty, diskMeta.filesExist == true {
                return [ToolbarMoreAction(
                    title: L10n.tr("preview.action.reveal_in_finder"),
                    icon: NookClipIcon.Action.revealInFinder
                ) {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        filePaths.map { URL(fileURLWithPath: $0) }
                    )
                }]
            }
        default:
            break
        }
        return []
    }

    /// 复制次数小 pill（预览区独有信息，列表行不展示）
    @ViewBuilder
    private func copyCountPill(_ item: ClipboardRowModel) -> some View {
        if item.copyCount > 1 {
            Text(L10n.tr("preview.copy_count_short", String(item.copyCount)))
                .font(.nookClipMeta)
                .monospacedDigit()
                .foregroundStyle(NookClip.textTertiary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    /// 顶部标签 chip 区：单行展示前 1 个 + `+N`。
    /// 点击 chip 按标签过滤、悬停 × 移除、右键重命名/删除；编辑标签入口收进「更多」菜单。
    private var tagChips: some View {
        HStack(spacing: 4) {
            let visible = Array(tags.prefix(Self.maxVisibleChips))
            ForEach(visible, id: \.self) { tag in
                TagChipView(
                    tag: tag,
                    size: .compact,
                    onRemove: onRemoveTag.map { remove in { remove(tag) } },
                    onTap: onSelectTag.map { select in { select(tag) } }
                )
                .contextMenu {
                    Button {
                        onRenameTag?(tag)
                    } label: {
                        Label(L10n.tr("tag.rename"), systemImage: NookClipIcon.Context.rename)
                    }
                    Button(role: .destructive) {
                        onDeleteTag?(tag)
                    } label: {
                        Label(L10n.tr("tag.delete"), systemImage: NookClipIcon.Context.delete)
                    }
                }
            }
            if tags.count > Self.maxVisibleChips {
                Text("+\(tags.count - Self.maxVisibleChips)")
                    .font(.nookClipMeta)
                    .foregroundStyle(NookClip.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// 顶栏最多直接展示的标签数（超出显示 +N）。收窄为 1，避免标签本身把顶栏撑爆。
    private static let maxVisibleChips = 1

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

    /// 极轻量警示文字 pill（目前仅用于文件失效提示）。
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
    var shortcut: String? = nil
    let icon: String
    var isActive: Bool = false
    var tooltipAlignment: Alignment = .bottomLeading
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
        // 左侧动作按钮：气泡向左下生长会溢出到左列（列表列 zIndex 更高会盖住它），
        // 改为 `bottomLeading` 让它向右下生长，始终落在预览列内、浮于下方内容之上。
        .overlay(alignment: tooltipAlignment) {
            if showTooltip {
                InstantTooltipBubble(text: shortcut.map { "\(title) (\($0))" } ?? title)
            }
        }
        .accessibilityLabel(title)
    }
}

/// 「更多」菜单里的一项动作：文字标题 + 图标 + 可选快捷键提示 + 激活态 / 警示态。
private struct ToolbarMoreAction {
    let title: String
    let icon: String
    var shortcut: String? = nil
    var isActive: Bool = false
    var isDestructive: Bool = false
    let action: () -> Void
}

@MainActor
private final class ToolbarMoreMenuTarget: NSObject {
    static let shared = ToolbarMoreMenuTarget()
    var actions: [Int: () -> Void] = [:]

    @objc func invoke(_ sender: NSMenuItem) {
        let action = actions[sender.tag]
        actions.removeAll()
        action?()
    }
}

/// 预览区工具栏操作按钮：「更多」（Icon-Only · 24×24pt，点击弹出原生 NSMenu 并在关闭后恢复面板键盘焦点）
private struct ToolbarMoreButton: View {
    let isActive: Bool
    let buildActions: () -> [[ToolbarMoreAction]]

    @State private var isHovered = false
    @State private var showTooltip = false
    @State private var tooltipTask: Task<Void, Never>?

    var body: some View {
        Button {
            tooltipTask?.cancel()
            showTooltip = false
            presentMenu()
        } label: {
            Image(systemName: NookClipIcon.Action.more)
                .font(.system(size: NookClipIconSize.compactMedium, weight: .semibold))
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
                InstantTooltipBubble(text: L10n.tr("preview.more.button"))
            }
        }
        .accessibilityLabel(L10n.tr("preview.more.button"))
        .accessibilityHint(L10n.tr("preview.more.hint"))
    }

    private func presentMenu() {
        let sections = buildActions()
        guard !sections.isEmpty else { return }
        let menu = NSMenu()
        var callbacks: [Int: () -> Void] = [:]
        var nextTag = 1
        for (sectionIndex, section) in sections.enumerated() {
            if sectionIndex > 0 {
                menu.addItem(.separator())
            }
            for entry in section {
                let label = entry.shortcut.map { "\(entry.title) (\($0))" } ?? entry.title
                let item = NSMenuItem(
                    title: label,
                    action: #selector(ToolbarMoreMenuTarget.invoke(_:)),
                    keyEquivalent: ""
                )
                item.target = ToolbarMoreMenuTarget.shared
                item.tag = nextTag
                item.state = entry.isActive ? .on : .off
                if let img = NSImage(systemSymbolName: entry.icon, accessibilityDescription: nil) {
                    item.image = img
                }
                callbacks[nextTag] = entry.action
                nextTag += 1
                menu.addItem(item)
            }
        }
        ToolbarMoreMenuTarget.shared.actions = callbacks
        if let event = NSApp.currentEvent,
           let window = NSApp.keyWindow ?? NSApp.mainWindow,
           let contentView = window.contentView {
            NSMenu.popUpContextMenu(menu, with: event, for: contentView)
        } else if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: window.contentView)
        }
        DispatchQueue.main.async {
            (NSApp.windows.first { $0 is DraggablePanel } as? DraggablePanel)?
                .restoreKeyboardFocus()
        }
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

