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
        self.clipboardWriter = clipboardWriter
        previewData = PreviewDataProvider(fileStore: .shared, clipboardWriter: clipboardWriter)
    }

    /// 剪贴板写入出口（与 pasteWorkflow / previewData 共用同一注入实例）。
    /// 脱敏粘贴（⌃⏎）与还原粘贴（⌃⇧⏎）的入参是「变换后的文本」而非条目本身，
    /// 无法走 ClipboardWorkflow 的条目级 API，故在此保留协议出口直写文本。
    let clipboardWriter: any ClipboardWriter

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
    /// 全局呼出快捷键展示文本（默认 ⌘ ⇧ V）
    @AppStorage(UserDefaultsKey.hotkeyDisplay.rawValue) var hotkeyDisplay = "⌘ ⇧ V"
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
    /// 展开过滤面板的实测高度（用于绘制「搜索框 + 面板」单张整体背景与其外围阴影）
    @State var filterPanelHeight: CGFloat = 0
    /// 导航滚动下一帧复核任务（连发 ↑/↓ 时取消前一次复核，防止过期目标把滚动位置拉乱）
    @State var scrollReconcileTask: Task<Void, Never>?
    /// 吸顶组节流任务：行坐标帧率变化合并为 ~60ms 一次状态更新
    @State var stickyRefreshTask: Task<Void, Never>?
    /// 待定位的时间分组（组头尚未被分页加载时先扩页，结果应用后补滚动）
    @State var pendingScrollGroupID: String?
    /// 鼠标拖拽多选的锚点行（nil = 未在拖拽）
    @State var dragSelectionAnchorID: UUID?
    /// 拖拽开始前的勾选基线（⇧ 拖拽追加用；普通拖拽为空集）
    @State var dragSelectionBaseline: Set<UUID> = []
    /// 拖拽结束时刻（用于吞掉松手瞬间仍会派发的那次单击）
    @State var dragSelectionEndedAt: Date?
    /// 拖拽期指针纵向位置（边缘自动滚动循环读最新值，引用容器不触发视图刷新）
    @State var dragPointerBox = DragPointerBox()
    /// 拖拽边缘自动滚动任务（指针越出列表上下边缘时持续滚动）
    @State var dragAutoScrollTask: Task<Void, Never>?
    /// 方向键在末尾触底下翻时记录待推进步长，下一页结果应用后补推进选中项
    @State var pendingAdvanceOffset: Int?
    @State var pendingAdvanceExtend = false
    // hoveredID 已移除（FR-007）：悬停态下沉到 ClipboardRowView 行内 @State，
    // 鼠标扫过列表不再触发 MainView 整树重求值（审查 Perf-1）
    /// 行内重命名目标（nil = 非编辑态）：⌘R / 右键「设置别名」进入。
    /// ⏎/失焦提交、Esc 放弃，提交走 store.updateTitle（空串 = title 置空）
    @State var renamingItemID: UUID?
    /// 标签编辑器浮层锚定视图（弹 popover 用）
    @State var tagEditorAnchor: TagEditorAnchor?
    /// 标签重命名草稿（弹输入框）
    @State var tagRenameTarget: String?
    @State var tagRenameDraft: String = ""
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
    /// 脱敏/还原/贴条等「即时动作」的短暂反馈文案（nil = 不显示）。
    /// 与 staleFileMessage 的 alert 形态区分：这些动作多为成功反馈，用 toast 更轻
    @State var scrubFeedbackMessage: String?
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
        .ignoresSafeArea()
        .overlay {
            Color.clear
                .frame(width: 1, height: 1)
                .focusable()
                .focusEffectDisabled()
                .focused($keyAnchorFocused)
        }
        // 标签编辑器浮层（中央轻量浮层；点击外部/Esc 关闭）
        .overlay {
            if let anchor = tagEditorAnchor {
                tagEditorOverlay(anchor)
            }
        }
        // 标签重命名输入浮层
        .overlay {
            if tagRenameTarget != nil {
                tagRenameOverlay
            }
        }
    }

    /// 标签编辑器浮层（半透明遮罩 + 居中卡片）
    @ViewBuilder
    private func tagEditorOverlay(_ anchor: TagEditorAnchor) -> some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture { closeTagEditor() }
            TagEditorPopover(
                target: anchor.target,
                knownTags: tagStats,
                stateForTag: { tag in tagState(tag, for: anchor.target) },
                appliedTags: commonTags(for: anchor.target),
                onSelectTag: { tag in applyTagToggle(tag, target: anchor.target, on: true) },
                onRemoveTag: { tag in applyTagToggle(tag, target: anchor.target, on: false) },
                onAddNewTag: { tag in addNewTag(tag, target: anchor.target) },
                onClose: { closeTagEditor() }
            )
            .padding(.top, 40)
        }
    }

    /// 标签重命名浮层（居中输入卡）
    private var tagRenameOverlay: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture { cancelTagRename() }
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("tag.rename"))
                    .font(.nookClipSubheadMedium)
                    .foregroundStyle(NookClip.textPrimary)
                HStack(spacing: 6) {
                    Text("#")
                        .font(.nookClipBody)
                        .foregroundStyle(NookClip.textTertiary)
                    TextField(L10n.tr("tag.rename_placeholder"), text: $tagRenameDraft)
                        .textFieldStyle(.plain)
                        .font(.nookClipBody)
                        .onSubmit { commitTagRename() }
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background {
                    RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                        .fill(NookClip.bgRowOn)
                        .overlay {
                            RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                                .strokeBorder(NookClip.separator, lineWidth: 0.5)
                        }
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button(L10n.tr("common.cancel")) { cancelTagRename() }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .font(.nookClipMeta)
                        .foregroundStyle(NookClip.textSecondary)
                    Button(L10n.tr("common.confirm")) { commitTagRename() }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .font(.nookClipMetaMedium)
                        .foregroundStyle(NookClip.accent)
                }
            }
            .padding(14)
            .frame(width: 240)
            .background {
                RoundedRectangle(cornerRadius: NookClip.radiusCard, style: .continuous)
                    .fill(NookClip.bgPopover)
                    .overlay {
                        RoundedRectangle(cornerRadius: NookClip.radiusCard, style: .continuous)
                            .strokeBorder(NookClip.separator, lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
            }
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

    /// 锚点条条目：全量时间分组（今天 / 昨天 / 本周 / 月份 / 年份；空桶不出现）。
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
                // 搜索框 + 展开过滤面板合成同一张卡：两块内容均透明背景，由下方**同一张**
                // 背景形状（贯穿搜索框+面板的整体轮廓）统一绘制底色并施加**一层**整体阴影。
                // 这样不会出现两个不透明面互相投影、接缝处被邻居阴影压暗/割裂的问题。
                ZStack(alignment: .top) {
                    NookClipSearchField(
                        text: Binding(
                            get: { listState.searchText },
                            set: { listState.setSearchText($0, dataVersion: store.dataVersion) }
                        ),
                        isFocused: $searchFieldFocused,
                        chips: embeddedFilterChips,
                        showsShortcutHint: true,
                        isIntegratedWithPanel: showsFilterPanel
                    )
                    .padding(EdgeInsets(top: NookClip.searchTopInset, leading: 0, bottom: NookClip.searchBottomGap, trailing: 0))
                    // 点击搜索框（面板未展开时）即聚焦并展开过滤面板：
                    // 命中层在面板收起时常驻，保证 Esc 收起后再次点击仍能重新展开
                    .overlay {
                        if !showsFilterPanel {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    searchFieldFocused = true
                                    filterState.filterPanelOpen = true
                                }
                        }
                    }

                    if showsFilterPanel {
                        CategoryFilterPanel(
                            categories: filterGridCategories,
                            selectedCategoryID: effectiveCategory,
                            tags: tagStats,
                            selectedTag: listState.selectedTag,
                            drawsBackground: false,
                            onSelectCategory: { id in
                                filterState.selectCategory(id)
                                searchFieldFocused = true
                            },
                            onSelectTag: { tag in
                                selectFilterTag(tag)
                            }
                        )
                        // 与搜索框一体：等宽铺满左列（x=0），上沿严丝合缝贴在搜索框下沿
                        .offset(x: 0, y: NookClip.searchTopInset + NookClip.heightSearch)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
                // 单张整体背景（搜索框 + 面板轮廓），并只在此背景上施加一层整体阴影
                .background(alignment: .top) {
                    if showsFilterPanel {
                        UnevenRoundedRectangle(
                            topLeadingRadius: NookClip.radiusCard,
                            bottomLeadingRadius: NookClip.radiusCard,
                            bottomTrailingRadius: NookClip.radiusCard,
                            topTrailingRadius: NookClip.radiusCard,
                            style: .continuous
                        )
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .overlay {
                            UnevenRoundedRectangle(
                                topLeadingRadius: NookClip.radiusCard,
                                bottomLeadingRadius: NookClip.radiusCard,
                                bottomTrailingRadius: NookClip.radiusCard,
                                topTrailingRadius: NookClip.radiusCard,
                                style: .continuous
                            )
                            .fill(NookClip.bgPopover)
                        }
                        .overlay {
                            UnevenRoundedRectangle(
                                topLeadingRadius: NookClip.radiusCard,
                                bottomLeadingRadius: NookClip.radiusCard,
                                bottomTrailingRadius: NookClip.radiusCard,
                                topTrailingRadius: NookClip.radiusCard,
                                style: .continuous
                            )
                            .strokeBorder(NookClip.separator, lineWidth: 0.5)
                        }
                        .frame(height: NookClip.searchTopInset + NookClip.heightSearch + filterPanelHeight)
                        .shadow(color: .black.opacity(0.14), radius: 12, y: 5)
                    }
                }
                .zIndex(100)
                .onPreferenceChange(FilterPanelHeightKey.self) { h in
                    filterPanelHeight = h
                }

                // 分类/标签不再常驻：统一由搜索框展开面板承载（见下方 overlay）
                if !matchedApps.isEmpty {
                    matchedAppsFixedSection
                }
                if !groups.isEmpty {
                    // 时间定位只依赖这条吸顶组头：组名 + 计数随滚动实时表达「现在在哪」，
                    // 右侧下拉菜单表达「跳到哪」（纯排印，无额外色块/刻度轨带来的视觉噪音）。
                    activeListHeaderBar
                }
                ZStack(alignment: .bottom) {
                    itemList
                    if let scrubFeedbackMessage {
                        // 脱敏/还原/钉住的轻量确认：非阻断，2 秒自动消失，
                        // 优先级高于撤销条与权限提示（它刚由用户主动触发）
                        ActionToast(
                            systemImage: NookClipIcon.Sensitive.shieldOk,
                            message: scrubFeedbackMessage
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else if !deletionWorkflow.pendingUndoIDs.isEmpty {
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
                        onStartPasteStack: {
                            // 顺序粘贴栈：把当前多选按列表序装进栈并逐条粘贴（US2）
                            _ = startPasteStackFromSelection()
                        },
                        onDelete: { deleteSelection() },
                        onEditTags: { beginTagEditForBatch() }
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
                            // 鼠标拖拽框选：与 ⇧↑↓ 同属「多选」，无键帽、纯文字说明手势
                            .init(kbds: [], label: L10n.tr("hints.drag_multi")),
                            .init(kbds: ["⌘\u{200A}C"], label: L10n.tr("hints.copy")),
                            .init(kbds: ["⌘\u{200A}F"], label: L10n.tr("hints.search")),
                            .init(kbds: ["⌥\u{200A}⏎"], label: L10n.tr("hints.paste_plain")),
                            .init(kbds: ["⌘\u{200A}⏎"], label: L10n.tr("hints.paste_keep")),
                            .init(kbds: ["⌘\u{200A}T"], label: L10n.tr("hints.time_jump")),
                            .init(kbds: ["⌘\u{200A}R"], label: L10n.tr("hints.rename")),
                            .init(kbds: ["Esc"], label: L10n.tr("hints.dismiss"))
                        ]
                    )
                }
            }
            .frame(width: NookClip.widthListCol)
            // 搜索框下方浮层（整列顶层 overlay，确保盖在列表之上）：
            // `#` 标签候选下拉：只要搜索词里存在未完成的 `#片段` 就展示（补全/清空后自然消失）。
            // （展开过滤面板已上移至搜索框同层 ZStack，与搜索框共用一层整体阴影）
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    if let suggestions = searchTagSuggestions, !suggestions.isEmpty {
                        tagSuggestionDropdown(suggestions)
                            .offset(
                                x: 12,
                                y: NookClip.searchTopInset + NookClip.heightSearch + NookClip.searchBottomGap - 2
                            )
                    }
                }
                .zIndex(100)
            }
            // 列底色 + 顶部薄雾（同一层叠：先底色后环境光，见 nookClipAuroraBackground）
            .nookClipAuroraBackground(base: {
                if enableTranslucency {
                    Rectangle().fill(NookClip.bgContent.opacity(1 - min(max(backgroundTransparency, 0), 0.5)))
                } else {
                    Rectangle().fill(NookClip.bgContent)
                }
            }, previewGlow: false)
            .overlay(alignment: .trailing) {
                Rectangle().fill(NookClip.separator).frame(width: 0.5)
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
                        previewData: previewData,
                        tagsProvider: { id in store.item(withID: id)?.tags ?? [] },
                        onSelectTag: { tag in
                            if listState.selectedTag == tag { listState.setSelectedTag(nil, dataVersion: store.dataVersion) }
                            else { listState.setSelectedTag(tag, dataVersion: store.dataVersion) }
                        },
                        onRemoveTag: { id, tag in store.removeTag(tag, from: id) },
                        onEditTags: { id in beginTagEdit(for: id) },
                        onRenameTag: { tag in beginTagRename(tag) },
                        onDeleteTag: { tag in store.deleteTag(name: tag) },
                        isSensitiveSyncActive: store.syncEngine.isE2EESensitiveSyncActive,
                        onScrubPaste: { scrubPasteSelected() },
                        onPinToScreen: { pinSelectedToScreen() },
                        canScrubPaste: selectedRow.map { $0.kind != .image && $0.kind != .file } ?? false,
                        onRestoreScrub: { restoreScrubPaste() }
                    )
                }
            }
            .frame(maxWidth: .infinity)
                // 右列底色 + 右缘冷暖双光 + 顶部薄雾（同一层叠）
                .nookClipAuroraBackground(base: {
                    if enableTranslucency {
                        Rectangle().fill(NookClip.bgPreview.opacity(min(max((1 - backgroundTransparency) * 0.95, 0.45), 1.0)))
                    } else {
                        Rectangle().fill(NookClip.bgPreview)
                    }
                }, previewGlow: true)
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
        switch outcome {
        case .staleFile(let message):
            staleFileMessage = message
        case .pastedWithNote(let message):
            // 终端护栏的轻提示：面板可能已关，交给系统级悬浮提示，
            // 否则这条反馈会随着面板一起消失，用户根本看不到发生了什么
            TerminalSafePasteNotifier.shared.show(message)
        case .pasted, .itemMissing, .cancelled:
            break
        }
    }

    /// 批量合并粘贴：按列表显示顺序以 \n 连接（BatchPaste.joinTexts），经 ClipboardWorkflow
    func pasteBatch(keepOpen: Bool, plainTextOnly: Bool) {
        let ordered = flatRows.filter { selectionCoordinator.selectionIDs.contains($0.id) }
        guard !ordered.isEmpty else { return }
        let pasted = pasteWorkflow.pasteBatch(
            entries: ordered.map { row in
                ClipboardWorkflow.BatchEntry(id: row.id, summary: row.summary, isSensitive: row.isSensitive)
            },
            targetApplication: getTargetApplication(),
            closePanel: keepOpen ? nil : onClose
        )
        // 取消（终端确认弹窗里点了取消）时保留选区现场，用户可改选其它条目
        if pasted {
            selectionCoordinator.selectionIDs.removeAll()
        }
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

    // MARK: - 标签（⌘L / 右键「标签…」/ 预览区 + 胶囊）

    /// 全部标签统计（按 count DESC, name ASC；随 store.dataVersion 刷新）
    var tagStats: [TagStat] { store.tagStats }

    /// 搜索框中正在输入的 `#` 片段对应的标签候选（nil = 未在输入标签）。
    /// 取最后一个 `#` 到行尾作为前缀；`#` 后含空格则视为已完成，不再提示。
    var searchTagSuggestions: [String]? {
        let text = listState.searchText
        guard let hashIdx = text.lastIndex(of: "#") else { return nil }
        let fragment = text[text.index(after: hashIdx)...]
        // 片段中若已含空白，说明标签词已结束，收起候选
        if fragment.contains(where: { $0.isWhitespace }) { return nil }
        let prefix = fragment.lowercased()
        let all = tagStats.map(\.name)
        if prefix.isEmpty {
            return Array(all.prefix(8))
        }
        return Array(all.filter { $0.lowercased().hasPrefix(prefix) }.prefix(8))
    }

    /// 把搜索框中末尾的 `#前缀` 补全为完整标签（保留其它搜索词，追加尾随空格）
    func completeSearchTag(_ tag: String) {
        var text = listState.searchText
        if let hashIdx = text.lastIndex(of: "#") {
            text = String(text[..<hashIdx])
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let rebuilt = trimmed.isEmpty ? "#\(tag) " : "\(trimmed) #\(tag) "
        listState.setSearchText(rebuilt, dataVersion: store.dataVersion)
        searchFieldFocused = true
    }

    /// 搜索框下方的标签候选下拉（紧凑、单行滚动，点选补全）。
    /// 背景必须**不透明**：面板本身是半透明材质，若下拉也用半透明色会与下方分类栏叠色看不清。
    /// 这里用「原生不透明底 + 主题 tint + 描边 + 阴影」组合，确保浮层清晰独立。
    @ViewBuilder
    private func tagSuggestionDropdown(_ suggestions: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(suggestions, id: \.self) { tag in
                    TagChipView(tag: tag, size: .compact, onTap: { completeSearchTag(tag) })
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(maxWidth: 320, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                // 不透明底：windowBackgroundColor 为实色，保证浮层不透出下层分类栏
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                        .fill(NookClip.bgPopover)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                        .strokeBorder(NookClip.separator, lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
    }

    // MARK: 搜索框展开过滤面板 / 内嵌条件胶囊

    /// 展开过滤面板是否可见：显式展开 且 搜索框为空且未在输入 `#`。
    /// 由焦点事件置位（聚焦即展开），Esc/打字/选中条件后收起——因此「聚焦但已按 Esc
    /// 收起」不会被焦点本身重新撑开，避免出现「无法关闭」。
    var showsFilterPanel: Bool {
        guard filterState.filterPanelOpen else { return false }
        guard listState.searchText.isEmpty else { return false }
        guard searchTagSuggestions == nil || searchTagSuggestions?.isEmpty == true else { return false }
        return true
    }

    /// 嵌在搜索框左侧的过滤条件胶囊：分类（非「全部」）+ 标签，二者可并存（AND）。
    var embeddedFilterChips: [EmbeddedFilterChip] {
        var chips: [EmbeddedFilterChip] = []
        if let cat = activeCategoryObject {
            chips.append(EmbeddedFilterChip(
                kind: .category,
                symbol: cat.symbol,
                title: cat.name,
                tint: cat.tintColor,
                onRemove: {
                    listState.setCategorySelection(0, dataVersion: store.dataVersion)
                    searchFieldFocused = true
                }
            ))
        }
        if let tag = listState.selectedTag {
            chips.append(EmbeddedFilterChip(
                kind: .tag,
                symbol: nil,
                title: tag,
                tint: NookClip.accent,
                onRemove: {
                    listState.setSelectedTag(nil, dataVersion: store.dataVersion)
                    searchFieldFocused = true
                }
            ))
        }
        return chips
    }

    /// 点选标签胶囊：设为过滤条件（与当前相同则取消），收起浮层并聚焦搜索框
    func selectFilterTag(_ tag: String) {
        if listState.selectedTag?.caseInsensitiveCompare(tag) == .orderedSame {
            listState.setSelectedTag(nil, dataVersion: store.dataVersion)
        } else {
            listState.setSelectedTag(tag, dataVersion: store.dataVersion)
        }
        filterState.filterPanelOpen = false
        searchFieldFocused = true
    }

    /// 打开单选标签编辑器（作用于单条）
    func beginTagEdit(for id: UUID) {
        guard tagEditorAnchor == nil else { return }
        tagEditorAnchor = TagEditorAnchor(target: .single(id), anchorID: id)
    }

    /// 打开批量标签编辑器（作用于当前勾选集；无勾选时回退到当前选中单条）
    func beginTagEditForBatch() {
        guard tagEditorAnchor == nil else { return }
        let ids = Array(selectionCoordinator.selectionIDs)
        if ids.count >= 2 {
            tagEditorAnchor = TagEditorAnchor(target: .batch(ids), anchorID: ids.first)
        } else if let id = selectionCoordinator.selectedID {
            tagEditorAnchor = TagEditorAnchor(target: .single(id), anchorID: id)
        }
    }

    /// ⌘L 动作：批量态 → 批量编辑器；否则单条编辑器（当前选中）
    func beginTagEdit() {
        if isBatchMode {
            beginTagEditForBatch()
        } else if let id = selectionCoordinator.selectedID {
            beginTagEdit(for: id)
        }
    }

    func closeTagEditor() {
        tagEditorAnchor = nil
    }

    /// 单条编辑目标当前标签
    func tags(of id: UUID) -> [String] {
        store.item(withID: id)?.tags ?? []
    }

    /// 目标条目的「共有标签」：单条 = 该条全部标签；批量 = 所有条目都有的交集（升序稳定）
    func commonTags(for target: TagEditTarget) -> [String] {
        let idList = target.ids
        guard let first = idList.first else { return [] }
        var common = tags(of: first)
        for id in idList.dropFirst() {
            let set = Set(tags(of: id).map { $0.lowercased() })
            common = common.filter { set.contains($0.lowercased()) }
        }
        // 保留一次展示顺序（沿用 first 的顺序）
        return common
    }

    /// 目标条目的标签状态（all/partial/none）
    func tagState(_ tag: String, for target: TagEditTarget) -> TagCandidateState {
        let idList = target.ids
        var matched = 0
        for id in idList where tags(of: id).contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            matched += 1
        }
        if matched == 0 { return .none }
        if matched == idList.count { return .all }
        return .partial
    }

    /// 应用标签切换（浮层回调）：单条走 setTags 全量；批量按条目逐个 add/remove
    func applyTagToggle(_ tag: String, target: TagEditTarget, on: Bool) {
        for id in target.ids {
            let current = tags(of: id)
            let has = current.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
            if on, !has {
                var next = current
                next.append(tag)
                store.setTags(next, for: id)
            } else if !on, has {
                store.removeTag(tag, from: id)
            }
        }
    }

    /// 创建并应用新标签给全部目标
    func addNewTag(_ tag: String, target: TagEditTarget) {
        let normalized = tag.leadingHashesStripped
        guard !normalized.isEmpty else { return }
        for id in target.ids {
            var next = tags(of: id)
            if !next.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) {
                next.append(normalized)
                store.setTags(next, for: id)
            }
        }
    }

    // MARK: 标签重命名 / 删除（筛选条右键）

    func beginTagRename(_ tag: String) {
        tagRenameTarget = tag
        tagRenameDraft = tag
    }

    func commitTagRename() {
        guard let old = tagRenameTarget else { return }
        let new = tagRenameDraft.leadingHashesStripped
        tagRenameTarget = nil
        guard !new.isEmpty, new.caseInsensitiveCompare(old) != .orderedSame else { return }
        store.renameTag(old: old, new: new)
        // 若正在按旧标签过滤，跟随重命名为新名
        if listState.selectedTag?.caseInsensitiveCompare(old) == .orderedSame {
            listState.setSelectedTag(new, dataVersion: store.dataVersion)
        }
    }

    func cancelTagRename() {
        tagRenameTarget = nil
        tagRenameDraft = ""
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


/// 标签编辑器浮层的展示状态（target + 锚定条目 id，用于内容刷新判定）
struct TagEditorAnchor: Equatable {
    let target: TagEditTarget
    let anchorID: UUID?
}
