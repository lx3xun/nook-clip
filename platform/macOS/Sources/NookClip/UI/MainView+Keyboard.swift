import AppKit
import SwiftUI

// MARK: - 键盘主循环（contracts C3 全表 · 拆自 MainView）
//
// 面板内快捷键的键位分发改在 AppKit 层单一入口（DraggablePanel.
// dispatchKeyboardEvent，键位匹配的唯一事实来源），本文件提供动作表
// 实现：闭包捕获的 @State 经包装器存储读取，始终为当前值（与
// coordinator 钩子同一接线模式）。语义路由（过滤面板开合、批量/单条粘贴）
// 依赖视图状态，留在动作内部，两层职责不重叠。

extension MainView {
    var lifecycleHandlers: some View {
        rootContent
        .onAppear {
            wireCoordinatorHooks()
            installKeyActions?(panelKeyActions)
            listState.refresh(dataVersion: store.dataVersion)
            keyAnchorFocused = true
            accessibilityTrusted = PasteService.isAccessibilityTrusted
        }
        .onChange(of: searchFieldFocused) { _, focused in
            if focused {
                // 聚焦搜索框即展开过滤面板（Spotlight 式：点搜索框 / ⌘F）；搜索框非空时不展开
                if listState.searchText.isEmpty {
                    filterState.filterPanelOpen = true
                }
            } else if renamingItemID == nil {
                keyAnchorFocused = true
                filterState.filterPanelOpen = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickPopoverDidOpen)) { _ in
            resetSessionState()
            // 相对时间文案按分钟变化：面板每次呼出时重算行模型，
            // 避免长驻期间「刚刚」永不更新
            listState.rowCache.invalidate()
            listState.refreshLocalizedOutput()
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickPopoverDidClose)) { _ in
            phoneDropPresented = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityTrusted = PasteService.isAccessibilityTrusted
        }
        .onReceive(NotificationCenter.default.publisher(for: .languageDidChange)) { _ in
            listState.refreshLocalizedOutput()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSColor.systemColorsDidChangeNotification)) { _ in
            systemColorUpdateTrigger += 1
        }
        .onChange(of: store.dataVersion) { _, _ in
            listState.refresh(dataVersion: store.dataVersion, limit: max(listState.results.count, InMemoryHistoryStore.pageSize))
        }
    }
    // MARK: 键盘动作表（DraggablePanel 分发表 → 此处实现）

    var panelKeyActions: PanelKeyActions {
        PanelKeyActions(
            arrow: { step, extend in
                // 对比态下按 ↑/↓：保持基准条目不变，实时切换另一侧记录并更新右侧对比；
                // 按 ⇧↑/⇧↓ 则以当前游标行为新基准并切换相邻记录。块间跳转是 ⌥↑/⌥↓，互不冲突。
                if diffSession.isInSession {
                    moveDiffComparisonSelection(offset: step, changeAnchor: extend)
                    return
                }
                if extend {
                    extendSelection(offset: step)
                } else {
                    moveSelection(offset: step)
                }
            },
            toggleFilterPanel: { toggleFilterPanel() },
            confirm: { keepOpen, plainTextOnly in
                if let selectedApp = matchedApps.first(where: { $0.id == selectedAppID }) {
                    openApplication(selectedApp)
                } else if isBatchMode {
                    pasteBatch(keepOpen: keepOpen, plainTextOnly: plainTextOnly)
                } else {
                    pasteSelected(keepOpen: keepOpen, plainTextOnly: plainTextOnly)
                }
            },
            scrubConfirm: { scrubPasteSelected() },
            restoreScrubConfirm: { restoreScrubPaste() },
            startPasteStack: { startPasteStackFromSelection() },
            pinToScreen: { pinSelectedToScreen() },
            escape: { handleEscapeKey() },
            cycleCategory: { step in
                exitDiff()
                closeMenus()
                cycleCategory(step)
            },
            copySelection: { copyFromSelection() },
            beginRename: { beginRename() },
            beginTagEdit: { beginTagEdit() },
            toggleFavorite: {
                if let id = listState.selectedID { store.toggleFavorite(id) }
            },
            cycleTimeAnchor: { cycleTimeAnchor() },
            undoDelete: { undoDelete() },
            deleteSelection: {
                exitDiff()
                deleteSelection()
            },
            focusSearch: {
                exitDiff()
                searchFieldFocused = true
                filterState.filterPanelOpen = true
            },
            toggleDiff: { toggleDiff() },
            moveDiffHunk: { forward in
                guard diffSession.isActive else { return false }
                _ = diffSession.focusNextChangeHunk(forward: forward)
                return true
            },
            copyMergedDiff: { copyMergedDiff() },
            pasteMergedDiff: { pasteMergedDiff() },
            typeToSearch: { event in
                exitDiff()
                searchFieldFocused = true
                filterState.filterPanelOpen = false
                DispatchQueue.main.async { NSApp.sendEvent(event) }
            },
            removeLastFilterChip: { removeLastFilterChip() }
        )
    }

    /// ⌫（搜索框为空时）：删除最近一枚过滤条件胶囊（标签优先，其次分类）。
    /// 返回 true 表示消耗了本次按键。
    @discardableResult
    func removeLastFilterChip() -> Bool {
        guard listState.searchText.isEmpty else { return false }
        if listState.selectedTag != nil {
            listState.setSelectedTag(nil, dataVersion: store.dataVersion)
            return true
        }
        if effectiveCategory != 0 {
            listState.setCategorySelection(0, dataVersion: store.dataVersion)
            return true
        }
        return false
    }

    /// 开合过滤面板（点击搜索框 / ⌘↓）：聚焦搜索框并翻转展开态
    func toggleFilterPanel() {
        if filterState.filterPanelOpen {
            filterState.filterPanelOpen = false
        } else {
            filterState.filterPanelOpen = true
            searchFieldFocused = true
        }
    }

    func handleEscapeKey() {
        // 手机快传浮层优先关闭（同时触发面板 onDisappear → 立即释放监听端口）
        if phoneDropPresented { phoneDropPresented = false; return }
        // 标签编辑器/重命名浮层优先关闭
        if tagEditorAnchor != nil { closeTagEditor(); return }
        if tagRenameTarget != nil { cancelTagRename(); return }
        // 过滤面板展开态：Esc 先收起浮层（搜索框仍聚焦也不重新撑开——由 filterPanelOpen 驱动）
        if showsFilterPanel {
            filterState.filterPanelOpen = false
            return
        }
        // 对比态（含只显示了失败原因的情形）：Esc 先退出对比，回到常规预览；
        // 下方其余层级保持原语义。失败态也要能被 Esc 关掉，否则右列会一直卡着提示。
        if diffSession.isInSession {
            exitDiff()
            return
        }
        if isBatchMode { listState.selectionIDs.removeAll(); return }
        if !listState.searchText.isEmpty {
            listState.setSearchText("", dataVersion: store.dataVersion)
            searchFieldFocused = true
            return
        }
        // 内嵌条件胶囊：标签 → 分类，按 ⌫/Esc 逐层清除
        if listState.selectedTag != nil {
            listState.setSelectedTag(nil, dataVersion: store.dataVersion)
            searchFieldFocused = true
            return
        }
        if effectiveCategory != 0 {
            listState.setCategorySelection(0, dataVersion: store.dataVersion)
            searchFieldFocused = true
            return
        }
        if filterState.timeSelection != nil { resetTimeAnchor(); return }
        onClose()
    }
}
