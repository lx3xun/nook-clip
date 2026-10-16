import SwiftUI

// MARK: - 右列预览区（40px 工具栏 + 详情内容 · specs/001-new-ui-cutover/T014）
// US3 敏感脱敏卡片（30s 自动重新遮罩 + 清系统剪贴板）+ US6 全类型预览卡片
// （代码/JSON/图片/OCR/色值/URL/文件）。
// 视觉规格与 nook-swiftui 原型 MainView.swift / OCRColorView.swift 逐项一致（contracts C4）；
// 全部剪贴板写入经 PasteService（contracts C2），不直调 NSPasteboard。

@MainActor
struct PreviewPane: View {
    /// 预览数据源（nil = 空态）
    var item: ClipboardRowModel?
    var onFavorite: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onTriggerOCR: ((UUID, (@Sendable @MainActor (OCRProgressStage) -> Void)?) async -> String?)? = nil
    /// 搜索命中高亮关键词（nil = 非搜索态，纯文本渲染；仅作用于标题/文本正文/OCR）
    var highlightKeywords: [String]? = nil
    /// 底层实体供给（data-model §4：预览区经 selectedID 取原 ClipboardItem）。
    /// 敏感明文（revealPlainContent）、图片 payloadPath/ocrText、文件路径/大小、
    /// 全文内容均来自该回调；未接线时降级为 RowModel 自带摘要。
    var entityProvider: ((ClipboardRowModel) -> ClipboardItem?)? = nil
    /// 预览数据出口（文件元数据/剪贴板操作；集中自此，视图不直连 FileStore/PasteService）
    var previewData: PreviewDataProvider

    // MARK: US3 脱敏状态（data-model §3.2：明文态持续 ≤30s，离开明文态必清剪贴板）

    @State private var isRevealed = false
    @State private var revealedPlainText: String?
    @State private var revealTask: Task<Void, Never>?
    @State private var revealFailure: ClipboardItem.RevealFailure?
    /// 链接二维码展示状态（切换选中条目时重置）
    @State private var showQRCode = false
    /// 图片 OCR 扫描动画状态与实时阶段日志
    @State private var isScanningOCR = false
    @State private var ocrProgressStage: OCRProgressStage? = nil
    @State private var urlCopied = false
    @State private var asyncTotalSize: Int64? = nil
    @State private var asyncHasMissingPath = false

    private func entity(_ item: ClipboardRowModel) -> ClipboardItem? {
        entityProvider?(item)
    }

    /// 文本类条目全文（敏感条目为掩码形态，明文仅经 revealPlainContent）
    private func fullText(_ item: ClipboardRowModel) -> String {
        entity(item)?.summary ?? item.summary
    }

    var body: some View {
        if let item {
            VStack(spacing: 0) {
                PreviewToolbar(
                    isFavorite: item.isFavorite,
                    item: item,
                    contentText: fullText(item),
                    showQRCode: showQRCode,
                    onToggleQRCode: { showQRCode.toggle() },
                    onFavorite: onFavorite,
                    onDelete: onDelete
                )
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        if !item.isSubtitleRedundant {
                            // 用户设置过别名（title 非空且与正文不冗余）时展示海报级大标题区
                            titleSection(item)
                                .padding(.bottom, 14)
                        }
                        contentBody(item)
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 10)
                    .padding(.bottom, 22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .onDisappear { maskSensitive(clearClipboard: true) }
            .onChange(of: item.id) { _, _ in
                // 切换选中：取消定时器并离开明文态（清剪贴板），收起二维码
                maskSensitive(clearClipboard: true)
                revealFailure = nil
                showQRCode = false
                urlCopied = false
                asyncTotalSize = nil
                asyncHasMissingPath = false
            }
            .task(id: item.id) {
                if item.kind == .file, let entityItem = entity(item) {
                    let paths = entityItem.payloadPath?
                        .components(separatedBy: "\n").filter { !$0.isEmpty } ?? []
                    if !paths.isEmpty {
                        let provider = previewData
                        let (missing, size) = await Task.detached(priority: .utility) {
                            let hasMissing = paths.contains { !provider.fileExists(atPath: $0) }
                            let total = paths.reduce(Int64(0)) { $0 + provider.fileSize(atPath: $1) }
                            return (hasMissing, total)
                        }.value
                        guard !Task.isCancelled else { return }
                        asyncHasMissingPath = missing
                        asyncTotalSize = size
                    }
                }
                isScanningOCR = false
                ocrProgressStage = nil
            }
            .onChange(of: entity(item)?.ocrText) { _, newOcr in
                if newOcr != nil {
                    isScanningOCR = false
                    ocrProgressStage = nil
                }
            }
        } else {
            emptyState
        }
    }

    // MARK: 标题（敏感条目：锁形图标 + 橙色等宽密文）

    @ViewBuilder
    private func titleSection(_ item: ClipboardRowModel) -> some View {
        HStack(spacing: 7) {
            if item.isSensitive {
                Image(systemName: NookClipIcon.Sensitive.lock)
                    .font(.system(size: NookClipIconSize.regularMedium))
                    .foregroundStyle(NookClip.colorSensitive)
            }
            SearchHighlight.text(item.displayTitle, keywords: highlightKeywords)
                .font(item.titleMono ? .nookClipTitleMono : .nookClipTitle)
                .foregroundStyle(item.isSensitive ? NookClip.colorSensitive : NookClip.textPrimary)
                .lineLimit(2)
        }
    }

    // MARK: 元信息行已上移合并至 PreviewToolbar 顶栏左侧（方案 B）

    // MARK: 摘要正文（按 kind 分发 · US6 全类型卡片）

    @ViewBuilder
    private func contentBody(_ item: ClipboardRowModel) -> some View {
        switch item.kind {
        case .sensitive:
            sensitiveSection(item)
        case .json:
            JSONPreviewCard(text: fullText(item))
        case .code:
            // id 跟随条目：切换选中时卡片状态（语言 pill 等）整体归零，
            // 不残留上一条的检测结果
            let forcedLang: String? = {
                if case .language(let lang) = item.badge { return lang }
                return entity(item)?.metadata.language
            }()
            CodePreviewCard(text: fullText(item), forcedLanguage: forcedLang)
                .id(item.id)
        case .color:
            ColorPreviewCard(item: item)
        case .image:
            imageSection(item)
        case .url:
            urlSection(item)
        case .file:
            fileSection(item)
        case .text:
            summaryText(fullText(item))
        }
    }

    /// 纯文本预览的行数上限：与 CodeBlockView 的超大文本降级同策略——
    /// 数万行日志全量进 SearchHighlight + Text 布局会假死主线程（审计 BUG-029）
    private static let plainTextMaxLines = 500

    private func summaryText(_ text: String) -> some View {
        let allLines = text.components(separatedBy: "\n")
        let displayed = Array(allLines.prefix(Self.plainTextMaxLines))
        return VStack(alignment: .leading, spacing: 6) {
            SearchHighlight.text(displayed.joined(separator: "\n"), keywords: highlightKeywords)
                .font(.nookClipBody)
                .foregroundStyle(NookClip.textPrimary)
                .lineSpacing(6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if allLines.count > displayed.count {
                // 复用代码块的截断提示文案（行数口径一致）
                Text(L10n.tr("preview.code.truncated", String(displayed.count), String(allLines.count)))
                    .font(.nookClipMeta)
                    .foregroundStyle(NookClip.textTertiary)
            }
        }
    }

    // MARK: US3 敏感脱敏区（状态胶囊 + 脱敏卡片 + 30s 说明）

    private func sensitiveSection(_ item: ClipboardRowModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 状态胶囊行（克制微底色 + 语义前景色，避免高饱和纯色块夺目）
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: NookClipIcon.Sensitive.shieldOk)
                        .font(.system(size: NookClipIconSize.micro, weight: .semibold))
                    Text(L10n.tr("preview.sensitive.encrypted"))
                }
                .font(.nookClipBadge)
                .foregroundStyle(NookClip.colorSuccess)
                .padding(.horizontal, 8)
                .frame(height: 18)
                .background(NookClip.colorSuccess.opacity(0.12), in: Capsule())

                Text(L10n.tr("preview.sensitive.local_only"))
                    .font(.nookClipBadge)
                    .foregroundStyle(NookClip.textSecondary)
                    .padding(.horizontal, 8)
                    .frame(height: 18)
                    .background(NookClip.bgRowOn, in: Capsule())
            }

            SensitiveMaskCard(
                maskedText: item.displayTitle,
                revealedText: revealedPlainText,
                isRevealed: isRevealed,
                revealFailure: revealFailure
            ) {
                toggleReveal(item)
            }
            .padding(.top, 14)

            Text(L10n.tr("preview.sensitive.auto_remask"))
                .font(.nookClipMeta)
                .foregroundStyle(NookClip.textTertiary)
                .padding(.top, 10)
        }
    }

    // MARK: US6 图片区（真实渲染 + 元信息 + OCR 卡片）

    @ViewBuilder
    private func imageSection(_ item: ClipboardRowModel) -> some View {
        let entityItem = entity(item)
        let hasOcr = entityItem?.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let triggerAction: (() -> Void)? = hasOcr ? nil : {
            startScan(for: item.id)
        }
        VStack(alignment: .leading, spacing: 0) {
            if let path = entityItem?.payloadPath, !path.isEmpty {
                ImagePreviewCard(
                    path: path,
                    isScanning: isScanningOCR,
                    onTriggerOCR: triggerAction
                )
                imageMetaRow(path: path, capturedAt: item.createdAt)
                    .padding(.top, 8)
            }
            OCRPreviewCard(
                itemId: item.id,
                ocrText: entityItem?.ocrText,
                highlightKeywords: highlightKeywords,
                isScanning: isScanningOCR,
                currentStage: ocrProgressStage,
                onTriggerOCR: triggerAction
            )
            .padding(.top, 14)
        }
    }

    private func startScan(for id: UUID) {
        guard !isScanningOCR else { return }
        isScanningOCR = true
        ocrProgressStage = .loadingEngine
        let trigger = onTriggerOCR
        Task { @MainActor in
            // 识别结束（含识别不到文字的失败）必须复位扫描状态；
            // 成功路径 ocrText 已先行写入，onChange 同样会复位，双保险
            _ = await trigger?(id) { stage in
                self.ocrProgressStage = stage
            }
            isScanningOCR = false
            ocrProgressStage = nil
        }
    }

    /// 图片元信息行（分辨率 / 格式 · 大小 · 识别状态，来自真实文件属性）
    private func imageMetaRow(path: String, capturedAt: Date) -> some View {
        let ext = (path as NSString).pathExtension.uppercased()
        let info = previewData.imageInfo(for: path)
        return HStack(spacing: 10) {
            if let dimensions = info?.dimensions, !dimensions.isEmpty {
                Text(dimensions)
                    .monospacedDigit()
            }
            if let fileSize = info?.fileSize {
                Text("\(ext.isEmpty ? L10n.tr("preview.image.fallback_type") : ext) · \(fileSize)")
                    .monospacedDigit()
            }
            Text(L10n.tr("preview.image.ocr_badge"))
        }
        .font(.nookClipMeta)
        .foregroundStyle(NookClip.textTertiary)
    }

    // MARK: US6 链接卡片

    private func urlSection(_ item: ClipboardRowModel) -> some View {
        let urlString = entity(item)?.metadata.url ?? item.summary
        let parsedURL = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines))
        let host = parsedURL?.host
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                if let host, !host.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: NookClipIcon.Category.url)
                            .font(.system(size: NookClipIconSize.compactMedium, weight: .semibold))
                            .foregroundStyle(NookClip.tintCategoryURL)
                        Text(verbatim: host)
                            .font(.nookClipBodyMedium)
                            .foregroundStyle(NookClip.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button {
                            if previewData.copyText(urlString) {
                                urlCopied = true
                                Task {
                                    try? await Task.sleep(for: .seconds(2))
                                    urlCopied = false
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                if urlCopied {
                                    Text(L10n.tr("preview.copied_feedback"))
                                        .font(.nookClipCaption)
                                        .foregroundStyle(NookClip.colorSuccess)
                                }
                                Image(systemName: urlCopied ? NookClipIcon.Action.copied : NookClipIcon.Action.copy)
                                    .font(.system(size: NookClipIconSize.compact))
                                    .foregroundStyle(urlCopied ? NookClip.colorSuccess : NookClip.textTertiary)
                            }
                            .frame(minWidth: 18, minHeight: 18)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                    }
                }
                Text(verbatim: urlString)
                    .font(.nookClipCode)
                    .foregroundStyle(NookClip.textSecondary)
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: NookClip.radiusCard, style: .continuous)
                    .fill(NookClip.bgInset)
            }

            if showQRCode {
                QRCodeCard(text: urlString)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: US6 文件卡片（名称 / 大小 / 路径 · 多文件逐条列表卡片）

    private func fileSection(_ item: ClipboardRowModel) -> some View {
        let entityItem = entity(item)
        let paths = entityItem?.payloadPath?
            .components(separatedBy: "\n").filter { !$0.isEmpty } ?? []
        return VStack(alignment: .leading, spacing: 8) {
            fileMetaLine(entityItem: entityItem, paths: paths)
            // 任一路径缺失时统一警示（行内名称同步标红，异步探测）
            if asyncHasMissingPath {
                HStack(spacing: 5) {
                    Image(systemName: NookClipIcon.Feedback.warning)
                        .font(.system(size: NookClipIconSize.compact))
                    Text(L10n.tr("file.missing.hint"))
                }
                .font(.nookClipMeta)
                .foregroundStyle(NookClip.colorDanger)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(NookClip.bgDangerSubtle, in: RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous))
            }
            if !paths.isEmpty {
                FilePreviewCard(paths: paths)
            }
        }
    }

    /// 大小汇总行：单文件仅大小；多文件为「N 个文件 · 共 X」（分别 stat 后求和）
    @ViewBuilder
    private func fileMetaLine(entityItem: ClipboardItem?, paths: [String]) -> some View {
        if let fileInfo = entityItem?.metadata.fileInfo, !fileInfo.isEmpty {
            Text(fileInfo)
                .font(.nookClip(11))
                .foregroundStyle(NookClip.textSecondary)
        } else if !paths.isEmpty {
            if let totalSize = asyncTotalSize, totalSize > 0 {
                let sizeText = ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
                Text(paths.count > 1
                    ? L10n.tr("preview.file.count_total", String(paths.count), sizeText)
                    : sizeText)
                    .font(.nookClip(11))
                    .foregroundStyle(NookClip.textSecondary)
            } else if paths.count > 1 {
                Text(L10n.tr("preview.file.count", String(paths.count)))
                    .font(.nookClip(11))
                    .foregroundStyle(NookClip.textSecondary)
            }
        }
    }

    // 代码语言 pill 不再在此推导：由 CodePreviewCard 异步取
    // highlight.js 检测结果（CodeBlockView.onDetectedLanguage）

    // MARK: US3 30s 定时器（D6：视图消失 / 切换选中取消；到期回遮罩 + 清剪贴板）

    private func toggleReveal(_ item: ClipboardRowModel) {
        if isRevealed {
            maskSensitive(clearClipboard: true)
        } else {
            let result = entity(item)?.revealPlainContentResult()
                ?? .failure(.keyUnavailable)
            switch result {
            case .success(let plain):
                reveal(plain: plain)
            case .failure(let failure):
                revealFailure = failure
            }
        }
    }

    private func reveal(plain: String) {
        revealFailure = nil
        revealedPlainText = plain
        isRevealed = true
        revealTask?.cancel()
        revealTask = Task {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            maskSensitive(clearClipboard: true)
        }
    }

    private func maskSensitive(clearClipboard: Bool) {
        revealTask?.cancel()
        revealTask = nil
        let plain = revealedPlainText
        isRevealed = false
        revealedPlainText = nil
        // 仅当系统剪贴板仍为该明文时清空（PasteService 契约 C2）
        if clearClipboard, let plain {
            previewData.clearClipboardIfContent(matches: plain)
        }
    }

    // MARK: 空态

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: NookClipIcon.Empty.preview)
                .font(.system(size: NookClipIconSize.hero, weight: .regular))
                .foregroundStyle(NookClip.textTertiary.opacity(0.65))
            Text(L10n.tr("preview.empty.hint"))
                .font(.nookClipSubhead)
                .foregroundStyle(NookClip.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

