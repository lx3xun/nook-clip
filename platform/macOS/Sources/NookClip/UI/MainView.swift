import SwiftUI

/// 批量合并粘贴纯函数（specs/001 T029）：按传入顺序以 \n 连接
enum BatchPaste {
    static func joinTexts(_ texts: [String]) -> String {
        texts.joined(separator: "\n")
    }
}

/// 宿主为 NSHostingController（默认尺寸由外层 panel 控制），内部弹性填充不写死尺寸。
@MainActor
struct MainView: View {
    @Bindable var store: InMemoryHistoryStore

    // MARK: 宿主接线（US2 键盘主循环）

    /// 粘贴目标应用（呼出面板时的前台应用，由 QuickPopoverController 提供）
    var getTargetApplication: () -> NSRunningApplication? = { nil }
    /// 收起面板
    var onClose: () -> Void = {}
    /// 键盘主循环动作表安装口（QuickPopoverController 提供面板侧接线，
    /// onAppear 时注入 DraggablePanel.keyActions）
    var installKeyActions: ((PanelKeyActions) -> Void)?

    init(
        store: InMemoryHistoryStore,
        clipboardWriter: any ClipboardWriter,
        getTargetApplication: @escaping () -> NSRunningApplication? = { nil },
        onClose: @escaping () -> Void = {},
        installKeyActions: ((PanelKeyActions) -> Void)? = nil
    ) {
        self.store = store
        self.getTargetApplication = getTargetApplication
        self.onClose = onClose
        self.installKeyActions = installKeyActions
        _listState = State(initialValue: MainViewListState(store: store))
        // T040 (contracts R4/R5): clipboard writes are explicitly injected into UI workflows.
        _pasteWorkflow = State(initialValue: ClipboardWorkflow(store: store, clipboardWriter: clipboardWriter))
        _deletionWorkflow = State(initialValue: DeletionWorkflow(store: store))
        previewData = PreviewDataProvider(fileStore: .shared, clipboardWriter: clipboardWriter)
    }


    /// 预览数据出口（与 pasteWorkflow 共用同一注入的 ClipboardWriter）
    private let previewData: PreviewDataProvider

    /// 统一列表状态深模块（集中封装查询、管线缓存与选择状态，核心不变量自愈闭环）
    @State var listState: MainViewListState
    @Namespace var rowSelectionNamespace
    var queryCoordinator: MainViewListState { listState }
    var selectionCoordinator: MainViewListState { listState }
    var searchText: Binding<String> {
        Binding(
            get: { listState.searchText },
            set: { listState.setSearchText($0, dataVersion: store.dataVersion) }
        )
    }
    var categorySelection: Int {
        get { listState.categorySelection }
        nonmutating set { listState.setCategorySelection(newValue, dataVersion: store.dataVersion) }
    }
    /// 分类条状态机（T037 · 契约 R10）：手动序与第 4 槽持久化、
    /// chip/下拉/循环序派生；接线见 MainView+Category.swift
    @State var categoryBar = CategoryBarCoordinator()
    /// 外观模式（跟随系统 / 浅色 / 深色）
    @AppStorage("appearance") var appearance = "system"
    /// 毛玻璃与背景透明度
    @AppStorage("enableTranslucency") var enableTranslucency = true
    /// 背景透明度 0~0.5：越大背景越透明（默认 0.15）
    @AppStorage("backgroundTransparency") var backgroundTransparency: Double = 0.15
    /// 时间快速跳转模式（偏好设置驱动）
    @AppStorage(UserDefaultsKey.timelineJumpMode.rawValue) var timelineJumpModeRaw = TimelineJumpMode.indexRail.rawValue
    /// 全局呼出快捷键展示文本（默认 ⌘ ⇧ V）
    @AppStorage(UserDefaultsKey.hotkeyDisplay.rawValue) var hotkeyDisplay = "⌘ ⇧ V"

    var timelineJumpMode: TimelineJumpMode {
        TimelineJumpMode(rawValue: timelineJumpModeRaw) ?? .indexRail
    }
    /// 分类/时间菜单与时间定位状态机（滚动/聚焦/槽固定等宿主副作用经钩子接线）
    @State var filterState = MainViewFilterState()
    /// 列表滚动代理（⌘T / 时间定位滚动用；itemList onAppear 注入）
    @State var scrollProxy: ScrollViewProxy?
    /// 列表行实时坐标（列表列坐标系；key = 行 id 字符串）。
    /// 用引用容器承载而非 @State 字典：滚动时每帧变化，字典作为 @State 会以
    /// 帧率触发 MainView 整树重求值。容器写入不触发 view 刷新，
    /// 只在按键滚动定位（scrollRowIntoSafeContentArea）与节流后的吸顶组计算时读取。
    @State var rowFramesBox = RowFramesBox()
    /// 列表滚动容器（ScrollView）在列表列坐标系中的实时 frame（不含上方固定应用区、时间组头栏及下方底栏）
    @State var listScrollAreaFrame: CGRect = .zero
    /// 导航滚动下一帧复核任务（连发 ↑/↓ 时取消前一次复核，防止过期目标把滚动位置拉乱）
    @State var scrollReconcileTask: Task<Void, Never>?
    /// 吸顶组节流任务：行坐标帧率变化合并为 ~60ms 一次状态更新
    @State var stickyRefreshTask: Task<Void, Never>?
    /// 待定位的时间分组（组头尚未被分页加载时先扩页，结果应用后补滚动）
    @State var pendingScrollGroupID: String?
    /// 方向键在末尾触底下翻时记录待推进步长，下一页结果应用后补推进选中项
    @State var pendingAdvanceOffset: Int?
    @State var pendingAdvanceExtend = false
    // hoveredID 已移除（FR-007）：悬停态下沉到 ClipboardRowView 行内 @State，
    // 鼠标扫过列表不再触发 MainView 整树重求值（审查 Perf-1）
    /// 行内重命名目标（nil = 非编辑态）：⌘R / 右键「设置别名」进入。
    /// ⏎/失焦提交、Esc 放弃，提交走 store.updateTitle（空串 = title 置空）
    @State var renamingItemID: UUID?
    /// 搜索框焦点（⌘F 聚焦 / 列表态打字即搜索）
    @State var searchFieldFocused = false
    /// 默认键盘焦点锚点：接管默认焦点防止面板打开时自动聚焦搜索框
    @FocusState var keyAnchorFocused: Bool
    /// 粘贴用户流程（单条/批量粘贴：文件失效校验、剪贴板写入、markUsed 时机）
    @State var pasteWorkflow: ClipboardWorkflow
    /// 删除用户流程（撤销窗口状态与超时清理调度；窗口时长见 DeletionWorkflow.undoWindow）
    @State var deletionWorkflow: DeletionWorkflow
    /// 文件条目失效提示（原文件被移动/删除或磁盘未挂载时阻断粘贴/复制）
    @State var staleFileMessage: String?
    /// 辅助功能权限状态（未授权时在列表底部展示引导横幅，支持一键跳转系统设置）
    @State var accessibilityTrusted = PasteService.isAccessibilityTrusted

    /// 系统强调色/主题色彩变更响应计数器
    @State var systemColorUpdateTrigger: Int = 0
    /// 匹配到的本地已安装应用（通过 listState 集中调度）
    var matchedApps: [InstalledApp] { listState.matchedApps }
    /// 当前选中的应用 ID（非空时优先高亮并响应 ⏎ 打开）
    var selectedAppID: String? {
        get { listState.selectedAppID }
        nonmutating set { listState.selectedAppID = newValue }
    }
    var isBatchMode: Bool { selectionCoordinator.isBatchMode }

    // MARK: 过滤链（T012）：分类 ∩ 自然时间区间 ∩ 关键词 → 时间线分组
    // 时间锚点为定位语义（不隐藏条目），下拉选项即分组结果，空桶自然不出现

    var pipelineOutput: MainViewPipelineModel.Output {
        MainViewPipelineModel.Output(
            categories: listState.categories,
            effectiveCategory: listState.effectiveCategory,
            filtered: listState.flatRows,
            groups: listState.groups,
            flatRows: listState.flatRows
        )
    }

    var effectiveCategory: Int {
        listState.effectiveCategory
    }

    var groups: [TimeGroup<ClipboardRowModel>] {
        listState.groups
    }

    var flatRows: [ClipboardRowModel] {
        listState.flatRows
    }

    var selectedRow: ClipboardRowModel? {
        listState.selectedRow
    }

    var body: some View {
        let _ = systemColorUpdateTrigger
        return lifecycleHandlers
            .preferredColorScheme(preferredScheme)
    }

    var preferredScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    /// 根内容（双栏）
    var rootContent: some View {
        mainColumns
        // 把内容整体上提 28pt 标题栏区：nookClipSurface 铺满整窗（标题栏落在材质上），
        // 侧栏搜索框自带 28pt+ 顶部让位。无此修饰时材质从标题栏下才
        // 开始，标题栏悬在面板外的透明条上
        .ignoresSafeArea()
        .overlay {
            Color.clear
                .frame(width: 1, height: 1)
                .focusable()
                .focusEffectDisabled()
                .focused($keyAnchorFocused)
        }
    }

    // MARK: - 列表查询（FTS5，查询移出 body）

    var queryText: String { listState.queryText }

    var hasSearchText: Bool { listState.hasSearchText }

    var activeSearchKeywords: [String]? { listState.activeSearchKeywords }
    func loadMoreQueryResults() {
        guard listState.hasMore, !listState.isRunning else { return }
        listState.refresh(dataVersion: store.dataVersion, limit: listState.results.count + InMemoryHistoryStore.pageSize)
    }


    func wireCoordinatorHooks() {
        listState.onResultsApplied = {
            consumePendingGroupScroll()
            consumePendingAdvance()
        }
        filterState.onCategorySelected = { id in
            listState.setCategorySelection(id, dataVersion: store.dataVersion)
            if categoryBar.customCategoryOrder == nil,
               categoryBar.switchableCategories(in: pipelineOutput.categories).contains(where: { $0.id == id }) {
                categoryBar.slot5PinnedID = id
            }
            searchFieldFocused = true
        }
        filterState.onTimeAnchorReset = {
            scrollToWithRetry("nook.topScrollAnchor", anchor: .top)
        }
        filterState.onSelectTimeGroup = { groupID in
            scrollToGroup(groupID)
        }
    }
    /// 定位组已不在当前过滤结果的全量分组中时视为未定位（锚点条胶囊回落跟随吸顶组）
    var effectiveTimeSelection: String? {
        queryCoordinator.timeGroups.contains { $0.id == filterState.timeSelection } ? filterState.timeSelection : nil
    }

    /// 锚点条条目：全量时间分组（今天 / 昨天 / 本周 / 上周 / 月份等；空桶不出现）。
    /// 来自 Rust 全量时间戳聚合，分页前缀没加载的更早分组也在导航中展示
    var timelineRailItems: [TimelineRailItem] {
        queryCoordinator.timeGroups.map { group in
            TimelineRailItem(
                id: group.id,
                title: group.title,
                count: group.count
            )
        }
    }

    /// ⌘T：循环定位下一个时间分组（全部 → 今天 → … → 末组 → 全部/回顶部）
    func cycleTimeAnchor() {
        let ids = queryCoordinator.timeGroups.map(\.id)
        guard !ids.isEmpty else { return }
        let index = effectiveTimeSelection.flatMap { ids.firstIndex(of: $0) } ?? -1
        if index + 1 < ids.count {
            filterState.railScrub(to: ids[index + 1])
        } else {
            // 末组后复位回「全部」/列表顶部：选中同步回落首行，
            // 否则停留在末组行，随后 ↑↓ 联动滚动会拉回末组锚点
            filterState.resetTimeAnchor()
            selectionCoordinator.selectedID = flatRows.first?.id
        }
    }

    /// 筛选条件（分类/关键词）变化或 Esc 清筛选时重置时间锚点回「全部」
    /// （滚动复位经 filterState.onTimeAnchorReset 钩子执行）
    func resetTimeAnchor() {
        filterState.resetTimeAnchor()
    }

    func closeMenus() {
        filterState.closeMenus()
    }

    /// 双栏主体：列表列（搜索 + 分类筛选条 + 列表）+ 预览区。
    /// 原左侧分类/时间侧边栏已下沉：分类进搜索框下方筛选条，时间进列表右缘锚点条。
    var mainColumns: some View {
        HStack(spacing: 0) {
            // 左列：搜索 + 剪贴列表 + 列表级提示栏（顶部让位标题栏）
            VStack(spacing: 0) {
                NookClipSearchField(
                    text: Binding(
                        get: { listState.searchText },
                        set: { listState.setSearchText($0, dataVersion: store.dataVersion) }
                    ),
                    isFocused: $searchFieldFocused
                )
                .padding(EdgeInsets(top: NookClip.searchTopInset, leading: 0, bottom: NookClip.searchBottomGap, trailing: 0))

                // 分类筛选条：紧贴搜索栏下方
                CategoryFilterBar(
                    chips: fixedCategories,
                    slotCategory: slot5Category,
                    hasSlotMenu: !categoryMenuCategories.isEmpty,
                    selectedID: effectiveCategory,
                    isSlotMenuOpen: filterState.categoryMenuOpen,
                    onSelect: { filterState.selectCategory($0) },
                    onToggleSlotMenu: { toggleCategoryMenu() }
                )
                .padding(EdgeInsets(top: 0, leading: 12, bottom: NookClip.categoryBarBottomGap, trailing: 12))
                // 搜索时分类条保持清晰可用（FR-007 · 消除假禁用态感知）
                if !matchedApps.isEmpty {
                    matchedAppsFixedSection
                }
                if !groups.isEmpty {
                    activeListHeaderBar
                }
                ZStack(alignment: .bottom) {
                    itemList
                        // 时间锚点条：极简刻度点轨 + 浮动气泡 HUD（受 timelineJumpMode 控制）
                        .overlay(alignment: .trailing) {
                            if timelineJumpMode == .indexRail && !groups.isEmpty {
                                TimelineIndexRail(
                                    items: timelineRailItems,
                                    currentID: filterState.stickyGroupID ?? groups.first?.id,
                                    onScrub: { filterState.railScrub(to: $0) }
                                )
                                .padding(.vertical, 4)
                            }
                        }
                    if !deletionWorkflow.pendingUndoIDs.isEmpty {
                        // T038：撤销 toast 抽为 UndoToast 组件（纯移动）
                        UndoToast(
                            pendingCount: deletionWorkflow.pendingUndoIDs.count,
                            undoDeadline: deletionWorkflow.undoToastDeadline,
                            onUndo: { undoDelete() }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else if !accessibilityTrusted {
                        AccessibilityPermissionBanner {
                            PasteService.openAccessibilitySettings()
                            onClose()
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }

                // 列表级提示栏（列表列内）：条目级操作（收藏/删除）的提示在
                // 预览区工具栏；呼出/隐藏快捷键在菜单栏「打开 NookClip」菜单项上展示
                if isBatchMode {
                    // T038：批量工具栏抽为 BatchBar 组件（纯移动）
                    BatchBar(
                        selectedCount: selectionCoordinator.selectionIDs.count,
                        onMergePaste: { pasteBatch(keepOpen: false, plainTextOnly: false) },
                        onDelete: { deleteSelection() }
                    )
                } else {
                    // 底栏主循环高频三键：选择 → 粘贴 → 分类切换；
                    // 其余进阶快捷键（多选/反向分类/搜索/变体粘贴等）由 ? 帮助卡片渐进披露
                    HintsFooterView(
                        hints: [
                            .init(kbds: ["↑", "↓"], label: L10n.tr("hints.select")),
                            .init(kbds: ["⏎"], label: L10n.tr("hints.paste")),
                            .init(kbds: ["⌘\u{200A}[", "⌘\u{200A}]"], label: L10n.tr("hints.category")),
                        ],
                        moreHints: [
                            .init(kbds: ["⇧\u{200A}↓", "⇧\u{200A}v"], label: L10n.tr("hints.multi")),
                            .init(kbds: ["⌘\u{200A}C"], label: L10n.tr("hints.copy")),
                            .init(kbds: ["⌘\u{200A}F"], label: L10n.tr("hints.search")),
                            .init(kbds: ["⌥\u{200A}⏎"], label: L10n.tr("hints.paste_plain")),
                            .init(kbds: ["⌘\u{200A}⏎"], label: L10n.tr("hints.paste_keep")),
                            .init(kbds: ["⌘\u{200A}T"], label: L10n.tr("hints.time_jump")),
                            .init(kbds: ["⌘\u{200A}R"], label: L10n.tr("hints.rename"))
                        ]
                    )
                }
            }
            .frame(width: NookClip.widthListCol)
            .background {
                if enableTranslucency {
                    Rectangle().fill(NookClip.bgContent.opacity(1 - min(max(backgroundTransparency, 0), 0.5)))
                } else {
                    Rectangle().fill(NookClip.bgContent)
                }
            }
            .overlay(alignment: .trailing) {
                Rectangle().fill(NookClip.separator).frame(width: 0.5)
            }
            // 分类下拉卡片 + 点击外部关闭捕获层（列表列抬层，盖过后续兄弟列）
            .overlay(alignment: .topLeading) {
                if filterState.categoryMenuOpen {
                    ZStack(alignment: .topLeading) {
                        OutsideTapCatcher { closeMenus() }
                        NookClipDropdownMenu(
                            options: categoryMenuOptions,
                            highlightedID: filterState.categoryMenuHighlight,
                            onSelect: { filterState.selectCategory($0) },
                            onHover: { filterState.categoryMenuHighlight = $0 },
                            onReorder: { dragging, target in
                                reorderCategory(dragging, before: target)
                            },
                            onNudge: { id, offset in
                                nudgeCategory(id, offset: offset)
                            },
                            resetOrderLabel: customCategoryOrder == nil
                                ? nil
                                : L10n.tr("category.reset_order"),
                            onResetOrder: { resetCategoryOrder() }
                        )
                        .offset(
                            x: NookClip.widthListCol - 12 - NookClipDropdownLayout.menuWidth,
                            y: NookClip.searchTopInset + NookClip.heightSearch + NookClip.searchBottomGap + NookClip.heightCategoryBar + 4
                        )
                    }
                }
            }
            .coordinateSpace(name: "nookListColumn")
            .zIndex(10)

            // 右列：详细预览区（应用预览或条目级预览）
            Group {
                if let selectedApp = matchedApps.first(where: { $0.id == selectedAppID }) {
                    AppPreviewPane(app: selectedApp) {
                        openApplication(selectedApp)
                    }
                } else {
                    PreviewPane(
                        item: selectedRow,
                        onFavorite: {
                            if let id = selectionCoordinator.selectedID { store.toggleFavorite(id) }
                        },
                        onDelete: {
                            if let id = selectionCoordinator.selectedID {
                                deleteSingle(id)
                            }
                        },
                        onTriggerOCR: { id, onStageChange in
                            await store.performManualOCRWithProgress(for: id, onStageChange: onStageChange)
                        },
                        highlightKeywords: activeSearchKeywords,
                        entityProvider: { row in
                            store.item(withID: row.id)
                        },
                        previewData: previewData
                    )
                }
            }
            .frame(maxWidth: .infinity)
                .background {
                    if enableTranslucency {
                        Rectangle().fill(NookClip.bgPreview.opacity(min(max((1 - backgroundTransparency) * 0.95, 0.45), 1.0)))
                    } else {
                        Rectangle().fill(NookClip.bgPreview)
                    }
                }
                .transaction { $0.animation = nil }
        }
        .clipped()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .nookClipSurface(
            tint: enableTranslucency ? NookClip.bgPanel.opacity(min(max(1 - backgroundTransparency, 0.3), 1.0)) : NookClip.bgPanel,
            enableTranslucency: enableTranslucency
        )
        .overlay(alignment: .bottomTrailing) {
            resizeGrip
        }
        .alert(
            L10n.tr("file.missing.title"),
            isPresented: Binding(
                get: { staleFileMessage != nil },
                set: { if !$0 { staleFileMessage = nil } }
            )
        ) {
            Button(L10n.tr("common.confirm"), role: .cancel) {}
        } message: {
            Text(staleFileMessage ?? "")
        }
    }

    // MARK: 键盘动作（contracts C3 · PasteService 统一出入口）

    func openApplication(_ app: InstalledApp) {
        AppSearchService.shared.openApp(app)
        onClose()
    }

    func handleAppSelectionMove(offset: Int) -> Bool {
        listState.handleAppNavigation(offset: offset)
    }

    func moveSelection(offset: Int) {
        if handleAppSelectionMove(offset: offset) {
            return
        }
        if offset > 0 {
            triggerLoadMoreIfNeeded(offset: offset, extend: false)
        } else {
            pendingAdvanceOffset = nil
        }
        selectionCoordinator.move(offset: offset, rows: flatRows)
    }

    /// ⇧↑ / ⇧↓：从当前选中项扩展批量选择（协调器内不包动画：勾选高频变更）
    func extendSelection(offset: Int) {
        if offset > 0 {
            triggerLoadMoreIfNeeded(offset: offset, extend: true)
        } else {
            pendingAdvanceOffset = nil
        }
        selectionCoordinator.extend(offset: offset, rows: flatRows)
    }

    /// 方向键向下导航时预加载与触底推进：
    /// 接近末尾（默认 5 条）时触发后台预加载下一页；
    /// 停留在末尾按 ↓ 时记录待推进步长，待新结果到达后自动下移选中项
    private func triggerLoadMoreIfNeeded(offset: Int, extend: Bool) {
        guard listState.hasMore else { return }
        let currentIndex = selectionCoordinator.selectedID.flatMap { id in
            flatRows.firstIndex(where: { $0.id == id })
        } ?? -1
        let prefetchThreshold = 5
        let isNearEnd = currentIndex >= max(0, flatRows.count - prefetchThreshold)
        let isAtEnd = currentIndex >= flatRows.count - 1

        if isAtEnd {
            pendingAdvanceOffset = offset
            pendingAdvanceExtend = extend
        }
        if isNearEnd {
            loadMoreQueryResults()
        }
    }

    /// 新分页结果应用后补推进选中项
    func consumePendingAdvance() {
        guard let offset = pendingAdvanceOffset else { return }
        pendingAdvanceOffset = nil
        let extend = pendingAdvanceExtend
        pendingAdvanceExtend = false
        if extend {
            extendSelection(offset: offset)
        } else {
            moveSelection(offset: offset)
        }
    }

    func pasteSelected(keepOpen: Bool, plainTextOnly: Bool) {
        guard let id = selectionCoordinator.selectedID else { return }
        let outcome = pasteWorkflow.pasteSingle(
            id: id,
            targetApplication: getTargetApplication(),
            plainTextOnly: plainTextOnly,
            closePanel: keepOpen ? nil : onClose
        )
        if case .staleFile(let message) = outcome {
            staleFileMessage = message
        }
    }

    /// 批量合并粘贴：按列表显示顺序以 \n 连接（BatchPaste.joinTexts），经 ClipboardWorkflow
    func pasteBatch(keepOpen: Bool, plainTextOnly: Bool) {
        let ordered = flatRows.filter { selectionCoordinator.selectionIDs.contains($0.id) }
        guard !ordered.isEmpty else { return }
        pasteWorkflow.pasteBatch(
            entries: ordered.map { row in
                ClipboardWorkflow.BatchEntry(id: row.id, summary: row.summary, isSensitive: row.isSensitive)
            },
            targetApplication: getTargetApplication(),
            closePanel: keepOpen ? nil : onClose
        )
        selectionCoordinator.selectionIDs.removeAll()
    }

    /// ⌘C / 右键「拷贝」：写入系统剪贴板并收起面板，不向前台应用发送 ⌘V 粘贴事件
    func copyFromSelection() {
        if isBatchMode {
            copyBatch()
        } else if let id = selectionCoordinator.selectedID {
            copySingle(id)
        }
    }

    func copySingle(_ id: UUID) {
        let outcome = pasteWorkflow.copySingle(
            id: id,
            closePanel: onClose
        )
        if case .staleFile(let message) = outcome {
            staleFileMessage = message
        }
    }

    func copyBatch() {
        let ordered = flatRows.filter { selectionCoordinator.selectionIDs.contains($0.id) }
        guard !ordered.isEmpty else { return }
        pasteWorkflow.copyBatch(
            entries: ordered.map { row in
                ClipboardWorkflow.BatchEntry(id: row.id, summary: row.summary, isSensitive: row.isSensitive)
            },
            closePanel: onClose
        )
        selectionCoordinator.selectionIDs.removeAll()
    }

    /// ⌘⌫ / 预览区删除：软删除 + 打开撤销窗口（单选/批量同构）。
    /// 删后选中补位项而非置 nil：置 nil 会在结果刷新后经 syncWithFilter
    /// 回落首行，深处连续删除时每次跳回顶部，须重新定位
    func deleteSelection() {
        if isBatchMode {
            let ids = selectionCoordinator.selectionIDs
            let successor = selectionCoordinator.successorID(afterDeleting: ids, rows: flatRows)
            deletionWorkflow.delete(ids)
            selectionCoordinator.selectionIDs.removeAll()
            if let current = selectionCoordinator.selectedID, !ids.contains(current) {
                // 勾选集外的锚点未被本批删除，保留原选中
            } else {
                selectionCoordinator.selectedID = successor
            }
        } else if let id = selectionCoordinator.selectedID {
            deleteSingle(id)
        }
    }

    /// 预览区删除：仅删当前选中项（批量模式下不扩散到勾选集）
    func deleteSingle(_ id: UUID) {
        let successor = selectionCoordinator.successorID(afterDeleting: [id], rows: flatRows)
        deletionWorkflow.delete([id])
        selectionCoordinator.selectedID = successor
    }

    /// 撤销最近一次删除（toast 按钮 / ⌘Z）；恢复后选中回落到恢复条目（列表顶部）：
    /// 不更新时选中停留在删除时的补位项，违背「恢复后选中回落到恢复条目」的
    /// 契约（审计 BUG-049）
    func undoDelete() {
        guard let ids = deletionWorkflow.undoDelete() else { return }
        selectionCoordinator.selectedID = ids.first
    }

    // MARK: 行内重命名（⌘R / 右键菜单 · 后端 store.updateTitle 已有）

    /// 仅单选 + 列表态可重命名（多选置灰；搜索框聚焦时 ⌘R 忽略，见键盘主循环）
    var canRenameSelection: Bool {
        !isBatchMode && selectionCoordinator.selectedID != nil
    }

    func beginRename() {
        guard renamingItemID == nil, canRenameSelection else { return }
        renamingItemID = selectionCoordinator.selectedID
    }

    /// 提交重命名：先退出编辑态再落库（publishMutation 重渲染时输入框已移除）
    func commitRename(_ title: String, for id: UUID) {
        guard renamingItemID == id else { return }
        renamingItemID = nil
        store.updateTitle(title, for: id)
        keyAnchorFocused = true
    }

    func cancelRename(for id: UUID) {
        guard renamingItemID == id else { return }
        renamingItemID = nil
        keyAnchorFocused = true
    }

    /// 右键「粘贴」= 双击同源：单选粘贴选中项，批量合并粘贴勾选集
    func pasteFromSelection() {
        if isBatchMode {
            pasteBatch(keepOpen: false, plainTextOnly: false)
        } else {
            pasteSelected(keepOpen: false, plainTextOnly: false)
        }
    }

    /// 右键「收藏」：作用于整个选区（逐项切换，勾选集混合态各自翻转）
    func toggleFavoriteSelection() {
        let ids: [UUID] = isBatchMode
            ? Array(selectionCoordinator.selectionIDs)
            : [selectionCoordinator.selectedID].compactMap { $0 }
        for id in ids {
            store.toggleFavorite(id)
        }
    }

    /// 右键「敏感密钥」：作用于整个选区（逐项切换）
    func toggleSensitiveSelection() {
        let ids: [UUID] = isBatchMode
            ? Array(selectionCoordinator.selectionIDs)
            : [selectionCoordinator.selectedID].compactMap { $0 }
        for id in ids {
            store.toggleSensitive(id)
        }
    }

    /// 面板每次呼出重置会话态（沿旧 QuickPopoverView 行为）
    func resetSessionState() {
        let hadActiveSearch = hasSearchText
        accessibilityTrusted = PasteService.isAccessibilityTrusted
        listState.clearFilters(dataVersion: store.dataVersion)
        resetTimeAnchor()
        closeMenus()
        renamingItemID = nil
        if !hadActiveSearch {
            selectionCoordinator.selectedID = flatRows.first?.id
        }
        // 默认不聚焦搜索框（用户可通过 ⌘F 聚焦；焦点落入根锚点避免
        // 面板打开时自动将焦点送入输入框吞掉 ⌘C 等列表快捷键）
        searchFieldFocused = false
        keyAnchorFocused = true
    }

    func updateAppSearchResults(query: String) {
        listState.updateMatchedApps(query: query)
    }

    /// 右下角 Resize Grip 斜纹（纯装饰，不响应点击）
    var resizeGrip: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [.clear, NookClip.colorResizeGrip],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .frame(width: 12, height: 12)
            .opacity(0.6)
            .padding(5)
            .allowsHitTesting(false)
    }
}

/// 辅助功能权限引导横幅：当未获得 macOS 辅助功能权限时悬浮在列表底部，
/// 提示用户开启权限以支持 ⏎ 自动粘贴，并提供一键跳转系统设置入口。
struct AccessibilityPermissionBanner: View {
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: NookClipIcon.TCC.untrusted)
                .font(.system(size: NookClipIconSize.compactMedium, weight: .semibold))
                .foregroundStyle(NookClip.colorSensitive)
            Text(L10n.tr("launch.permission_tip"))
                .font(.nookClipMeta)
                .foregroundStyle(NookClip.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
            Button {
                onOpenSettings()
            } label: {
                Text(L10n.tr("launch.permission_action"))
                    .font(.nookClipMetaMedium)
                    .foregroundStyle(NookClip.accent)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background {
                        RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                            .fill(NookClip.bgChipSelected)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background {
            RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                .fill(NookClip.bgPopover)
                .overlay {
                    RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                        .strokeBorder(NookClip.separator, lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

