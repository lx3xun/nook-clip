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
    /// 当前条目完整标签（由宿主按 id 提供；空则不渲染标签行）
    var tagsProvider: ((UUID) -> [String])? = nil
    /// 点击某标签 → 按该标签过滤列表（设置 selectedTag）
    var onSelectTag: ((String) -> Void)? = nil
    /// 移除当前条目的某标签
    var onRemoveTag: ((UUID, String) -> Void)? = nil
    /// 打开标签编辑器（末尾 + 胶囊）
    var onEditTags: ((UUID) -> Void)? = nil
    /// 右键标签：全局重命名该标签
    var onRenameTag: ((String) -> Void)? = nil
    /// 右键标签：全局删除该标签（不删条目）
    var onDeleteTag: ((String) -> Void)? = nil
    /// 敏感条目跨端同步**当前是否真正生效**（E2EE 开 + 口令非空 + 用户显式开启），
    /// 由宿主从 `ICloudDriveSyncEngine.isE2EESensitiveSyncActive` 注入。
    /// 预览区不能无条件断言「绝不上云」：用户开启敏感同步后那条断言会变成谎言，
    /// 所以胶囊文案随本开关在「仅本机」与「端到端加密跨端同步」之间切换。
    var isSensitiveSyncActive: Bool = false

    /// ⌃⏎ 脱敏粘贴（US1）：把本条目的敏感值换成语义占位符后粘贴
    var onScrubPaste: (() -> Void)? = nil
    /// ⌘P 钉在屏幕（US3）：把本条目钉成桌面置顶贴条
    var onPinToScreen: (() -> Void)? = nil
    /// 当前条目能否脱敏（排除非文本的图片/文件条目）
    var canScrubPaste: Bool = false
    /// ⌃⇧⏎ 还原粘贴：把当前条目里的占位符还原成真实值（US1 反向）
    var onRestoreScrub: (() -> Void)? = nil

    // MARK: US3 脱敏状态（data-model §3.2：明文态持续 ≤30s，离开明文态必清剪贴板）

    @State private var isRevealed = false
    @State private var revealedPlainText: String?
    @State private var countdownSeconds = 0
    @State private var revealTask: Task<Void, Never>?
    /// 脱敏预检的防抖任务（按住方向键连续换选中时只算最后一条）
    @State private var scrubHintTask: Task<Void, Never>?
    @State private var revealFailure: ClipboardItem.RevealFailure?
    /// 链接二维码展示状态（切换选中条目时重置）
    @State private var showQRCode = false
    /// 图片 OCR 扫描动画状态与实时阶段日志
    @State private var isScanningOCR = false
    @State private var ocrProgressStage: OCRProgressStage? = nil
    @State private var urlCopied = false
    @State private var asyncTotalSize: Int64? = nil
    @State private var asyncHasMissingPath = false
    /// 当前条目的完整实体（全文/OCR/metadata）：按 item.id 异步加载一次并缓存，
    /// 避免 body 每次求值都跨 FFI 同步查库（单帧曾触发 2~4 次查询）。
    @State private var loadedEntity: ClipboardItem?
    @State private var loadedEntityID: UUID?
    /// 当前条目的「含敏感信息」预检结果（nil = 无命中或尚未算完）。
    /// 只做存在性判断，**零副作用**：不分配占位符、不写会话池。
    @State private var scrubHint: ScrubScanOutcome?

    /// 「粘贴前提醒」开关，与 `ScrubService.DefaultsKey.pasteHintEnabled` 是同一个键。
    ///
    /// 视图侧必须用 `@AppStorage` 观察它而不是每次直接问服务：服务不是
    /// `@Observable`，用户在设置页关掉开关时，已经打开的预览区不会重新求值，
    /// 提示会一直挂在那里——看起来就像开关失效。
    @AppStorage(ScrubService.DefaultsKey.pasteHintEnabled) private var pasteHintEnabled = true

    private func entity(_ item: ClipboardRowModel) -> ClipboardItem? {
        guard loadedEntityID == item.id else { return nil }
        return loadedEntity
    }

    /// 切换条目时按需加载完整实体（截断摘要场景必须查库取全文）。
    /// 返回加载到的实体，供 `.task` 顺序读取（不再依赖异步回填后的状态）。
    /// 敏感条目不预取明文：缓存明文会让 30 秒租约形同虚设，
    /// 只保留列表已有的掩码摘要，明文仅经 revealPlainContent 按需解密。
    private func loadEntityIfNeeded(for item: ClipboardRowModel) async -> ClipboardItem? {
        if loadedEntityID == item.id {
            return loadedEntity
        }
        guard !item.isSensitive else {
            loadedEntityID = item.id
            loadedEntity = nil
            return nil
        }
        guard let provider = entityProvider else {
            loadedEntity = nil
            loadedEntityID = item.id
            return nil
        }
        loadedEntityID = item.id
        loadedEntity = nil
        let row = item
        let entity = await Task.detached(priority: .utility) {
            provider(row)
        }.value
        guard loadedEntityID == row.id else { return nil }
        loadedEntity = entity
        return entity
    }

    /// 释放缓存实体（含可能的长文本与 OCR 全文）
    private func releaseLoadedEntity() {
        loadedEntity = nil
        loadedEntityID = nil
    }

    /// 文本类条目全文（敏感条目为掩码形态，明文仅经 revealPlainContent）
    private func fullText(_ item: ClipboardRowModel) -> String {
        entity(item)?.summary ?? item.summary
    }

    /// 当前条目文本里「本会话内仍可还原」的占位符个数。
    /// 只有 > 0 才展示还原横幅；数量为 0 时整条横幅不存在，
    /// 避免常规文本也被这行提示污染视觉。
    private var restorablePlaceholderCount: Int {
        guard let item else { return 0 }
        let text = fullText(item)
        guard text.contains("<") else { return 0 }
        return ScrubService.shared.restorableCount(in: text)
    }

    /// 是否要显示「含敏感信息」提示。
    ///
    /// 三种情况不显示：开关关掉、当前条目不可脱敏（图片/文件/敏感条目）、
    /// 已经有还原横幅（同一块区域同时挂两条提示太挤，且还原是更紧急的动作）。
    private var shouldShowScrubHint: Bool {
        guard pasteHintEnabled, canScrubPaste, restorablePlaceholderCount == 0 else { return false }
        return scrubHint?.hasHits == true
    }

    /// 防抖后异步跑一次预检。
    ///
    /// 为什么需要防抖：`scan_text` 在 64KB 上约 1ms、256KB 约 4ms，单次可忽略，
    /// 但按住方向键连续换选中时，一秒钟能扫十几条大文本，累积起来就是掉帧。
    /// 延迟 120ms 足以滤掉连划，人眼又感觉不到。
    private func scheduleScrubHintScan(for item: ClipboardRowModel, entityItem: ClipboardItem?) {
        scrubHintTask?.cancel()
        guard pasteHintEnabled, canScrubPaste else {
            scrubHint = nil
            return
        }
        // 与 fullText 同源：优先实体全文，降级到行模型的摘要
        let text = entityItem?.summary ?? item.summary
        guard !text.isEmpty else {
            scrubHint = nil
            return
        }
        scrubHintTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let outcome = ScrubService.shared.scanForHint(text)
            guard !Task.isCancelled else { return }
            scrubHint = outcome
        }
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
                    onDelete: onDelete,
                    onEditTags: { onEditTags?(item.id) },
                    tags: tagsProvider?(item.id) ?? item.tags,
                    onSelectTag: { onSelectTag?($0) },
                    onRemoveTag: { tag in onRemoveTag?(item.id, tag) },
                    onRenameTag: onRenameTag,
                    onDeleteTag: onDeleteTag,
                    onScrubPaste: onScrubPaste,
                    onPinToScreen: onPinToScreen,
                    canScrubPaste: canScrubPaste
                )
                // 顶栏必须绘制在其下方内容之上：工具栏按钮的即时微气泡会向下偏移
                // 探入内容区（offset y≈25），若此栏与下方 ScrollView 同层，后者作为
                // 后声明兄弟会把气泡整块盖住（左侧列表列与下方卡片亦会遮挡）。
                // 仅抬升层级即可让气泡完整浮于所有内容之上。
                .zIndex(1)
                // 占位符还原横幅（US1）：当前条目含「本会话内仍可还原」的占位符时，
                // 在顶栏下方插入一条窄横幅。文案必须带上按键提示，
                // 否则用户不知道 ⌃⇧⏎ 的存在（发现性优先于界面纯净）
                if restorablePlaceholderCount > 0 {
                    RestorePlaceholderBanner(
                        count: restorablePlaceholderCount,
                        onRestore: onRestoreScrub
                    )
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .zIndex(1)
                } else if shouldShowScrubHint, let hint = scrubHint {
                    // 未脱敏但含敏感内容：给一行非阻断提示。
                    // 放在还原横幅的同一位置（二者互斥），视觉规格也保持一致，
                    // 避免同一块区域出现两种风格。
                    ScrubHintBanner(
                        hitCount: hint.hitCount,
                        ruleList: hint.localizedRuleList,
                        onScrubPaste: onScrubPaste
                    )
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .zIndex(1)
                }
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
            .onDisappear {
                scrubHintTask?.cancel()
                maskSensitive(clearClipboard: true, releaseEntity: true)
            }
            .onChange(of: item.id) { _, _ in
                // 切换选中：取消定时器并离开明文态（清剪贴板），收起二维码
                maskSensitive(clearClipboard: true, releaseEntity: true)
                revealFailure = nil
                showQRCode = false
                urlCopied = false
                asyncTotalSize = nil
                asyncHasMissingPath = false
                scrubHint = nil
                scrubHintTask?.cancel()
            }
            .task(id: item.id) {
                // 必须先 await 实体加载：此前的同步调用会让下方读到的 entity 恒为 nil，
                // 导致文件大小/缺失路径检测成为死代码。
                let entityItem = await loadEntityIfNeeded(for: item)
                scheduleScrubHintScan(for: item, entityItem: entityItem)
                if item.kind == .file, let entityItem {
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
            .onChange(of: pasteHintEnabled) { _, enabled in
                // 关掉时 shouldShowScrubHint 会立刻为 false，不需要处理；
                // 打开时要补扫一次，否则已打开的面板要等到下次换选中才出现提示
                guard enabled else { return }
                scheduleScrubHintScan(for: item, entityItem: entity(item))
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
                .searchHighlightRenderer()
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
                .searchHighlightRenderer()
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

                // 同步状态胶囊：文案随实际同步开关切换。敏感同步未生效时保持
                // 「纯本机 · 不同步 iCloud」的本地边界承诺；生效后该承诺已不成立，
                // 必须换成「端到端加密 · 跨端同步」，否则预览区会与设置页自相矛盾。
                Text(L10n.tr(Self.sensitiveSyncBadgeKey(isSensitiveSyncActive: isSensitiveSyncActive)))
                    .font(.nookClipBadge)
                    .foregroundStyle(NookClip.textSecondary)
                    .padding(.horizontal, 8)
                    .frame(height: 18)
                    .background(NookClip.bgRowOn, in: Capsule())
            }

            SensitiveMaskCard(
                maskedText: item.summary.isEmpty ? item.displayTitle : item.summary,
                revealedText: revealedPlainText,
                isRevealed: isRevealed,
                countdownSeconds: countdownSeconds,
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
                imageMetaRow(path: path, hasOcr: hasOcr, isScanning: isScanningOCR)
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
            let recognized = await trigger?(id) { stage in
                self.ocrProgressStage = stage
            }
            if recognized != nil, self.loadedEntityID == id, let row = self.item, row.id == id {
                self.loadedEntity = self.entityProvider?(row)
            }
            isScanningOCR = false
            ocrProgressStage = nil
        }
    }

    /// 图片元信息行（分辨率 / 格式 · 大小 · 识别状态，来自真实文件属性）
    ///
    /// 识别状态必须是真实状态。原先这里无条件打印"已离线识别"，
    /// 而同一屏下方的 OCR 卡片写着"尚未提取文字"——两个断言互相矛盾，
    /// 用户无法判断到底识别过没有。改为按 hasOcr / isScanning 三态渲染。
    private func imageMetaRow(path: String, hasOcr: Bool, isScanning: Bool) -> some View {
        let ext = (path as NSString).pathExtension.uppercased()
        let info = previewData.imageInfo(for: path)
        let ocrStateText: String = {
            if isScanning { return L10n.tr("preview.ocr.scanning") }
            return hasOcr ? L10n.tr("preview.image.ocr_badge") : L10n.tr("preview.image.ocr_pending")
        }()
        return HStack(spacing: 10) {
            if let dimensions = info?.dimensions, !dimensions.isEmpty {
                Text(dimensions)
                    .monospacedDigit()
            }
            if let fileSize = info?.fileSize {
                Text("\(ext.isEmpty ? L10n.tr("preview.image.fallback_type") : ext) · \(fileSize)")
                    .monospacedDigit()
            }
            Text(ocrStateText)
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

    /// 预览区同步状态胶囊的文案键：敏感条目跨端同步真正生效时不得再声称「绝不上云」。
    /// 抽成静态函数便于单测覆盖两种状态的绑定关系（避免再次出现写死的静态断言）。
    static func sensitiveSyncBadgeKey(isSensitiveSyncActive: Bool) -> String {
        isSensitiveSyncActive ? "preview.sensitive.e2ee_sync" : "preview.sensitive.local_only"
    }

    /// 解析敏感条目的明文（按需经 entityProvider 查库解密，不依赖预加载缓存 loadedEntity）
    static func resolveSensitivePlainText(
        for item: ClipboardRowModel,
        cachedEntity: ClipboardItem?,
        entityProvider: ((ClipboardRowModel) -> ClipboardItem?)?
    ) -> Result<String, ClipboardItem.RevealFailure> {
        let targetEntity = cachedEntity ?? entityProvider?(item)
        return targetEntity?.revealPlainContentResult() ?? .failure(.keyUnavailable)
    }

    private func toggleReveal(_ item: ClipboardRowModel) {
        if isRevealed {
            maskSensitive(clearClipboard: true)
        } else {
            // 敏感条目不在选中时预取，仅在用户主动点击查看时按需查库解密
            let result = Self.resolveSensitivePlainText(
                for: item,
                cachedEntity: entity(item),
                entityProvider: entityProvider
            )
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
        countdownSeconds = 30
        revealTask?.cancel()
        revealTask = Task {
            while countdownSeconds > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                countdownSeconds -= 1
            }
            maskSensitive(clearClipboard: true)
        }
    }

    private func maskSensitive(clearClipboard: Bool, releaseEntity: Bool = false) {
        revealTask?.cancel()
        revealTask = nil
        let plain = revealedPlainText
        isRevealed = false
        countdownSeconds = 0
        revealedPlainText = nil
        // 仅切换条目/视图消失时释放缓存实体；30 秒到期只回遮罩，
        // 不能清掉预览全文（否则正文区域会变成空）。
        if releaseEntity {
            releaseLoadedEntity()
        }
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

// MARK: - 占位符还原横幅（US1 · ⌃⇧⏎ 的发现性入口）

/// 预览区顶栏下方的窄横幅：提示「当前文本含 N 个可还原占位符」。
///
/// 设计取舍：不做成弹窗、不自动展开、不用警告色——它是一个「机会提示」
/// 而非「错误通知」。用低饱和的 `bgInset` 底 + 盾牌图标 + 一整行文案，
/// 视觉重量刻意低于顶栏按钮，不抢正文注意力。
private struct RestorePlaceholderBanner: View {
    let count: Int
    var onRestore: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: NookClipIcon.Sensitive.shieldOk)
                .font(.system(size: NookClipIconSize.compact, weight: .medium))
                .foregroundStyle(NookClip.colorSensitive)
            Text(L10n.tr("scrub.banner.detected", String(count)))
                .font(.nookClipMeta)
                .foregroundStyle(NookClip.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                onRestore?()
            } label: {
                HStack(spacing: 5) {
                    KbdView(text: "⌃\u{200A}⇧\u{200A}⏎", fontSize: 9)
                    Text(L10n.tr("scrub.banner.restore"))
                        .font(.nookClipMetaMedium)
                        .foregroundStyle(isHovered ? NookClip.accent : NookClip.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(NookClip.animHover) { isHovered = hovering }
            }
            .help(L10n.tr("scrub.banner.restore"))
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                .fill(NookClip.bgInset)
        }
        .overlay {
            RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                .strokeBorder(NookClip.borderHairline, lineWidth: 0.5)
        }
    }
}

/// 粘贴前的「这条内容含敏感信息」提示条（方案 A：非阻断，不弹窗不拦键）。
///
/// 与 `RestorePlaceholderBanner` 同视觉、同位置、互斥显示：一个是「已经脱敏了、
/// 可以还原」，一个是「还没脱敏、要不要脱敏」。对用户来说这是同一件事的两个阶段，
/// 长得一样才不会让人以为是两个功能。
private struct ScrubHintBanner: View {
    let hitCount: Int
    let ruleList: String
    var onScrubPaste: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: NookClipIcon.Sensitive.shieldOk)
                .font(.system(size: NookClipIconSize.compact, weight: .medium))
                .foregroundStyle(NookClip.colorSensitive)
            Text(L10n.tr("scrub.hint.detected", String(hitCount), ruleList))
                .font(.nookClipMeta)
                .foregroundStyle(NookClip.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button {
                onScrubPaste?()
            } label: {
                HStack(spacing: 5) {
                    KbdView(text: "⌃\u{200A}⏎", fontSize: 9)
                    Text(L10n.tr("scrub.hint.action"))
                        .font(.nookClipMetaMedium)
                        .foregroundStyle(isHovered ? NookClip.accent : NookClip.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(NookClip.animHover) { isHovered = hovering }
            }
            .help(L10n.tr("scrub.hint.action"))
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                .fill(NookClip.bgInset)
        }
        .overlay {
            RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                .strokeBorder(NookClip.borderHairline, lineWidth: 0.5)
        }
    }
}
