import SwiftUI

// MARK: - 剪贴列表与滚动（组头吸顶 · ↑↓ 联动滚动 · 拆自 MainView）

extension MainView {
    /// 定位到时间分组：滚动使该组首行贴齐纯列表视口顶部，并把选中落到该组首行
    /// （否则选中停留在原分组，随后 ↑↓ 联动滚动会把视图拉回原锚点）。
    /// 组未被分页加载时先扩前缀拉入（全量分组计数推算覆盖行数），
    /// 结果应用后由 consumePendingGroupScroll 补滚动与选中落点。
    func scrollToGroup(_ groupID: String) {
        if let group = groups.first(where: { $0.id == groupID }), let first = group.items.first {
            selectionCoordinator.selectedID = first.id
            filterState.updateStickyGroup(group.id)
            scrollToWithRetry(first.id, anchor: .top)
            return
        }
        guard let covering = queryCoordinator.rowLimitCoveringGroup(groupID) else { return }
        pendingScrollGroupID = groupID
        listState.refresh(dataVersion: store.dataVersion, limit: max(covering, queryCoordinator.results.count))
    }

    /// 扩页定位补滚动：待定位组已进入结果后滚到该组首行；
    /// 被其他查询取代/同键短路（组未进入结果）时放弃，不留陈旧跳转
    func consumePendingGroupScroll() {
        guard let groupID = pendingScrollGroupID else { return }
        guard groups.contains(where: { $0.id == groupID }) else {
            pendingScrollGroupID = nil
            return
        }
        pendingScrollGroupID = nil
        if let group = groups.first(where: { $0.id == groupID }), let first = group.items.first {
            selectionCoordinator.selectedID = first.id
            filterState.updateStickyGroup(group.id)
            scrollToWithRetry(first.id, anchor: .top)
        }
    }

    /// LazyVStack 远距离 scrollTo 可能被前一个滚动打断/吞掉，或先落在估算
    /// 位置再修正：立即执行一次，150ms 后复执一次兜底
    func scrollToWithRetry<ID: Hashable>(_ id: ID, anchor: UnitPoint? = nil) {
        scrollProxy?.scrollTo(id, anchor: anchor)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            scrollProxy?.scrollTo(id, anchor: anchor)
        }
    }

    /// 底部悬浮横幅（删除撤销 UndoToast / 辅助功能引导横幅）当前占用的高度
    var activeBottomBannerInset: CGFloat {
        (!deletionWorkflow.pendingUndoIDs.isEmpty || !accessibilityTrusted)
            ? NookClip.heightListBottomBanner
            : 0
    }

    /// 列表内容有效可视区顶/底 Y（列表列坐标系）：
    /// - 顶边：纯剪贴板 ScrollView 的实时顶沿（无应用结果时为 102pt，有顶部固定应用区时自动下移）
    /// - 底边：ScrollView 底沿扣除底部悬浮横幅高度（底栏 HintsFooterView / BatchBar 固定在 ScrollView 下方）
    var listContentSafeBoundsY: (top: CGFloat, bottom: CGFloat) {
        let top = listScrollAreaFrame.height > 0 ? listScrollAreaFrame.minY : NookClip.listContentTopY
        let scrollHeight = listScrollAreaFrame.height > 0
            ? listScrollAreaFrame.height
            : (PanelGeometry.minHeight - NookClip.listContentTopY - NookClip.heightFooter)
        let bottom = max(top + NookClip.heightRowList, top + scrollHeight - activeBottomBannerInset)
        return (top, bottom)
    }

    /// 计算让目标行完整贴在「底部提示栏/悬浮横幅正上方」的 UnitPoint 锚点
    var bottomAboveFooterAnchor: UnitPoint {
        let scrollHeight = listScrollAreaFrame.height > 0
            ? listScrollAreaFrame.height
            : (PanelGeometry.minHeight - NookClip.listContentTopY - NookClip.heightFooter)
        let denom = max(scrollHeight - NookClip.heightRowList, 1)
        let y = min(max((scrollHeight - activeBottomBannerInset - NookClip.heightRowList) / denom, 0), 1)
        return UnitPoint(x: 0.5, y: y)
    }

    /// 确保目标行完整落在纯列表视口内（top = 102pt ~ bottom = 602pt/603pt），绝不露半截
    func scrollRowIntoSafeContentArea<ID: Hashable>(
        scrollID: ID,
        frameKey: String,
        isAbsoluteFirstRow: Bool,
        movingUp: Bool,
        proxy: ScrollViewProxy
    ) {
        scrollReconcileTask?.cancel()
        if isAbsoluteFirstRow {
            scrollToWithRetry("nook.topScrollAnchor", anchor: .top)
            return
        }
        let bounds = listContentSafeBoundsY
        let tolerance: CGFloat = 1.0
        if let rect = rowFramesBox.frame(forKey: frameKey) {
            if rect.minY < bounds.top - tolerance {
                proxy.scrollTo(scrollID, anchor: .top)
            } else if rect.maxY > bounds.bottom + tolerance {
                proxy.scrollTo(scrollID, anchor: bottomAboveFooterAnchor)
            }
        } else {
            let anchor: UnitPoint = movingUp ? .top : bottomAboveFooterAnchor
            proxy.scrollTo(scrollID, anchor: anchor)
            scrollReconcileTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 25_000_000)
                guard !Task.isCancelled else { return }
                let latestBounds = listContentSafeBoundsY
                if let rect = rowFramesBox.frame(forKey: frameKey) {
                    if rect.minY < latestBounds.top - tolerance {
                        scrollProxy?.scrollTo(scrollID, anchor: .top)
                    } else if rect.maxY > latestBounds.bottom + tolerance {
                        scrollProxy?.scrollTo(scrollID, anchor: bottomAboveFooterAnchor)
                    }
                } else {
                    scrollProxy?.scrollTo(scrollID, anchor: anchor)
                }
            }
        }
    }

    /// 顶部独立固定的「应用程序」结果区（最多 3 条，不进入下方剪贴板 ScrollView，物理分层清晰）
    @ViewBuilder
    var matchedAppsFixedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupHeaderView(
                groupID: "apps",
                title: L10n.tr("app.section_title"),
                count: matchedApps.count,
                allGroups: nil,
                onSelectGroup: nil
            )
            ForEach(matchedApps) { app in
                AppRowView(
                    app: app,
                    isSelected: selectedAppID == app.id,
                    selectionNamespace: rowSelectionNamespace,
                    highlightKeywords: activeSearchKeywords,
                    onTap: {
                        selectedAppID = app.id
                        selectionCoordinator.selectedID = nil
                    },
                    onDoubleTap: {
                        openApplication(app)
                    }
                )
                .id("app.\(app.id)")
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(NookClip.separator)
                .frame(height: 0.5)
        }
    }

    /// 独立在剪贴板 ScrollView 上方的固定时间分组状态栏（24pt）：
    /// 仅展示剪贴板数据的时间分组，不随选中上方应用而跳变文字，也不参与 ScrollView 内部滚动
    @ViewBuilder
    var activeListHeaderBar: some View {
        if let currentGroup = groups.first(where: { $0.id == filterState.stickyGroupID }) ?? groups.first {
            let railCount = timelineRailItems.first(where: { $0.id == currentGroup.id })?.count ?? currentGroup.items.count
            GroupHeaderView(
                groupID: currentGroup.id,
                title: currentGroup.title,
                count: railCount,
                allGroups: timelineJumpMode == .groupHeaderMenu ? timelineRailItems : nil,
                onSelectGroup: timelineJumpMode == .groupHeaderMenu ? { scrollToGroup($0) } : nil
            )
        }
    }

    /// 根据可见行坐标实时同步顶部所属时间分组（供独立顶部组头栏与右侧时间刻度轨同步显示）
    func updateActiveStickyGroupFromVisibleRows(_ frames: [String: CGRect]) {
        if let resolved = MainViewFilterState.resolveStickyGroupID(
            groups: groups,
            frames: frames,
            bounds: listContentSafeBoundsY,
            selectedID: selectionCoordinator.selectedID
        ) {
            filterState.updateStickyGroup(resolved)
        } else if groups.isEmpty {
            filterState.updateStickyGroup(nil)
        }
    }

    /// 吸顶组节流刷新：行坐标每帧变化时调用，保证滚动期间每 ~60ms 至少刷新一次。
    /// 注意必须用节流而非防抖：防抖会在连续滚动时不停取消定时器，
    /// 导致吸顶组在整个滚动过程中完全停更、直到停下才跳变。
    func scheduleStickyGroupRefresh() {
        // 已有在途刷新任务：本帧跳过，等它在 60ms 后统一读取最新快照
        guard stickyRefreshTask == nil else { return }
        stickyRefreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            stickyRefreshTask = nil
            updateActiveStickyGroupFromVisibleRows(rowFramesBox.snapshot)
        }
    }

    /// 行视图构造（拆出 ForEach 闭包：参数增多后内联构造触发类型检查超时）
    func rowView(for item: ClipboardRowModel) -> some View {
        ClipboardRowView(
            item: item,
            isSelected: item.id == selectionCoordinator.selectedID,
            selectionNamespace: rowSelectionNamespace,
            // 悬停态已下沉到 ClipboardRowView 行内自持（FR-007），不再传参
            style: isBatchMode
                ? .batch(isChecked: selectionCoordinator.selectionIDs.contains(item.id), isRemoving: false)
                : .single,
            highlightKeywords: activeSearchKeywords,
            onTap: { handleRowTap(item) },
            onDoubleTap: { handleRowDoubleTap(item) },
            isRenaming: item.id == renamingItemID,
            onRenameCommit: { commitRename($0, for: item.id) },
            onRenameCancel: { cancelRename(for: item.id) }
        )
        // 右键选择同步先于菜单弹出（Finder 语义），菜单动作恒作用于当前选区
        .background(RightClickObserver { handleRowRightClick(item) })
        .contextMenu { rowContextMenu(item) }
    }

    /// 右键选择同步：点在勾选集内 → 保留多选；集外/单选态点其他行 → 收敛为
    /// 单选该行。菜单里的粘贴/收藏/删除作用于整个选区，重命名仅单选可用
    func handleRowRightClick(_ item: ClipboardRowModel) {
        searchFieldFocused = false
        if isBatchMode, selectionCoordinator.selectionIDs.contains(item.id) { return }
        selectionCoordinator.selectionIDs = []
        selectionCoordinator.selectedID = item.id
    }

    /// 行右键菜单：拷贝 / 粘贴 / 重命名 / 收藏切换 / 删除（删除走 10s 撤销体系）
    @ViewBuilder
    func rowContextMenu(_ item: ClipboardRowModel) -> some View {
        let renaming = renamingItemID != nil
        Button {
            copyFromSelection()
        } label: {
            Label(L10n.tr("hints.copy"), systemImage: NookClipIcon.Context.copy)
        }
        .disabled(renaming)
        Button {
            pasteFromSelection()
        } label: {
            Label(L10n.tr("hints.paste"), systemImage: NookClipIcon.Context.paste)
        }
        .disabled(renaming)
        Button {
            beginRename()
        } label: {
            Label(L10n.tr("context.rename"), systemImage: NookClipIcon.Context.rename)
        }
        .disabled(renaming || !canRenameSelection)
        Button {
            toggleFavoriteSelection()
        } label: {
            Label(
                L10n.tr(item.isFavorite ? "context.unfavorite" : "hints.favorite"),
                systemImage: item.isFavorite ? NookClipIcon.Context.favoriteFilled : NookClipIcon.Context.favorite
            )
        }
        .disabled(renaming)
        Button {
            toggleSensitiveSelection()
        } label: {
            Label(
                L10n.tr(item.isSensitive ? "context.unmark_sensitive" : "context.mark_sensitive"),
                systemImage: item.isSensitive ? NookClipIcon.Context.unmarkSensitive : NookClipIcon.Context.markSensitive
            )
        }
        .disabled(renaming)
        Divider()
        Button(role: .destructive) {
            deleteSelection()
        } label: {
            Label(L10n.tr("hints.delete"), systemImage: NookClipIcon.Context.delete)
        }
        .disabled(renaming)
    }

    // MARK: 剪贴列表（多级时间线分组 · 组头吸顶 · ↑↓ 联动滚动）

    @ViewBuilder
    var itemList: some View {
        if groups.isEmpty && matchedApps.isEmpty {
            emptyState
        } else if groups.isEmpty {
            // 仅命中应用程序、无匹配的剪贴板历史时，下方留空填充以保持底栏贴底
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // 顶部 1pt 锚点：配平 PanelGeometry.minHeight (625 = 78 + 24 + 1 + 10×50 + 22)
                        Color.clear
                            .frame(height: 1)
                            .id("nook.topScrollAnchor")
                        ForEach(flatRows) { item in
                            rowView(for: item)
                                .id(item.id)
                                .background {
                                    GeometryReader { geo in
                                        Color.clear.preference(
                                            key: RowFramesPreferenceKey.self,
                                            value: [item.id.uuidString: geo.frame(in: .named("nookListColumn"))]
                                        )
                                    }
                                }
                        }
                        // 分页哨兵：滚动到底自动加载下一页（替换式增长前缀）
                        if queryCoordinator.hasMore {
                            HStack {
                                Spacer()
                                ProgressView()
                                    .controlSize(.small)
                                Spacer()
                            }
                            .frame(height: 40)
                            .onAppear { loadMoreQueryResults() }
                        }
                        // 底部安全留白：当悬浮横幅（UndoToast / 权限横幅）出现时，滚到底部也能完整露出末行
                        if activeBottomBannerInset > 0 {
                            Color.clear
                                .frame(height: activeBottomBannerInset)
                        }
                    }
                }
                .clipped()
                .background {
                    GeometryReader { geo in
                        let frame = geo.frame(in: .named("nookListColumn"))
                        Color.clear
                            .onAppear { listScrollAreaFrame = frame }
                            .onChange(of: frame) { _, newFrame in
                                listScrollAreaFrame = newFrame
                            }
                    }
                }
                .onPreferenceChange(RowFramesPreferenceKey.self) { frames in
                    // 滚动期帧率高：行坐标写入引用容器，不触发整树重求值；
                    // 吸顶组经节流合并为一次性状态更新。
                    rowFramesBox.update(frames)
                    scheduleStickyGroupRefresh()
                }
                .onAppear { scrollProxy = proxy }
                .onChange(of: selectionCoordinator.selectedID) { oldID, id in
                    guard let id else { return }
                    if let group = groups.first(where: { grp in grp.items.contains { $0.id == id } }) {
                        filterState.updateStickyGroup(group.id)
                    }
                    guard let idx = flatRows.firstIndex(where: { $0.id == id }) else {
                        proxy.scrollTo(id)
                        return
                    }
                    let movingUp: Bool
                    if let oldID, let oldIdx = flatRows.firstIndex(where: { $0.id == oldID }) {
                        movingUp = idx < oldIdx
                    } else {
                        movingUp = true
                    }
                    scrollRowIntoSafeContentArea(
                        scrollID: id,
                        frameKey: id.uuidString,
                        isAbsoluteFirstRow: idx == 0,
                        movingUp: movingUp,
                        proxy: proxy
                    )
                }
            }
        }
    }

    /// 行点击分发（标准列表交互，鼠标/键盘双覆盖）：
    /// - ⇧点击：从锚点（当前选中行）到点击行整段勾选（Finder 肌肉记忆，单选模式也可直接进入多选）
    /// - ⌘点击 / 批量模式点击：切换单行勾选
    /// - 单选模式普通点击：设为选中行（⇧点击的锚点）
    /// 勾选不包动画——与 extendSelection 同理，高频操作要即时反馈
    func handleRowTap(_ item: ClipboardRowModel) {
        searchFieldFocused = false
        let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        withAnimation(NookClip.animSelection) {
            selectionCoordinator.handleTap(
                item,
                rows: flatRows,
                shiftHeld: modifiers.contains(.shift),
                commandHeld: modifiers.contains(.command)
            )
        }
    }

    /// 行双击 = 粘贴，与 ⏎ 一致：单选模式粘贴该项，批量模式合并粘贴勾选项
    func handleRowDoubleTap(_ item: ClipboardRowModel) {
        if !isBatchMode { selectionCoordinator.selectedID = item.id }
        if isBatchMode {
            pasteBatch(keepOpen: false, plainTextOnly: false)
        } else {
            pasteSelected(keepOpen: false, plainTextOnly: false)
        }
    }

    /// 无结果空态（查询失败与「无匹配」区分显示，不把 FTS 故障伪装成空历史）。
    /// 交集语义下把全部生效条件说出来（关键词 + 分类），并提供一键清除
    /// （等价于分层 Esc 的终点）
    var emptyState: some View {
        VStack(spacing: 8) {
            if queryCoordinator.failed {
                Image(systemName: NookClipIcon.Feedback.warning)
                    .font(.system(size: NookClipIconSize.titleLarge))
                    .foregroundStyle(NookClip.textTertiary)
                Text(L10n.tr("search.index_unavailable"))
                    .font(.nookClipBody)
                    .foregroundStyle(NookClip.textSecondary)
            } else if queryCoordinator.isRunning && queryCoordinator.results.isEmpty {
                // 首次查询进行中：不闪「无匹配记录」
                ProgressView()
                    .controlSize(.small)
            } else if !hasSearchText && effectiveCategory == 0 {
                // 库内尚无任何历史记录（首次打开或清空后）
                Image(systemName: NookClipIcon.Empty.clipboard)
                    .font(.system(size: NookClipIconSize.titleLarge + 4, weight: .light))
                    .foregroundStyle(NookClip.accent.opacity(0.8))
                    .padding(.bottom, 4)
                Text(L10n.tr("empty.welcome_title"))
                    .font(.nookClipBodyMedium)
                    .foregroundStyle(NookClip.textPrimary)
                Text(L10n.tr("empty.welcome_subtitle"))
                    .font(.nookClipMeta)
                    .foregroundStyle(NookClip.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                
                // 快捷键友好提示
                Text(L10n.tr("launch.welcome_banner", hotkeyDisplay))
                    .font(.nookClipMeta)
                    .foregroundStyle(NookClip.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(NookClip.bgChipSelected, in: RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous))
                    .padding(.top, 8)
            } else {
                Image(systemName: NookClipIcon.Empty.search)
                    .font(.system(size: NookClipIconSize.titleLarge, weight: .regular))
                    .foregroundStyle(NookClip.textTertiary)
                    .padding(.bottom, 2)
                Text(L10n.tr("empty.no_match"))
                    .font(.nookClipBodyMedium)
                    .foregroundStyle(NookClip.textSecondary)
                let trimmed = queryText.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    Text("“\(trimmed)”")
                        .font(.nookClipMeta)
                        .foregroundStyle(NookClip.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 16)
                }
                if effectiveCategory != 0,
                   let category = pipelineOutput.categories.first(where: { $0.id == effectiveCategory }) {
                    Text(category.name)
                        .font(.nookClipMeta)
                        .foregroundStyle(NookClip.textTertiary)
                }
                Button {
                    listState.clearFilters(dataVersion: store.dataVersion)
                    resetTimeAnchor()
                } label: {
                    Text(L10n.tr("empty.clear_filters"))
                        .font(.nookClipSubheadMedium)
                        .foregroundStyle(NookClip.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(NookClip.bgChipSelected, in: RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous))
                }
                .buttonStyle(.plain)
                .focusable(false)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
