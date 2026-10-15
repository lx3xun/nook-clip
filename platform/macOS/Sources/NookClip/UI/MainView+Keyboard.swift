import AppKit
import SwiftUI

// MARK: - 键盘主循环（contracts C3 全表 · 拆自 MainView）
//
// 面板内快捷键的键位分发改在 AppKit 层单一入口（DraggablePanel.
// dispatchKeyboardEvent，键位匹配的唯一事实来源），本文件提供动作表
// 实现：闭包捕获的 @State 经包装器存储读取，始终为当前值（与
// coordinator 钩子同一接线模式）。语义路由（分类下拉开合时 ↑↓ 移动
// 高亮、批量/单条粘贴）依赖视图状态，留在动作内部，两层职责不重叠。

extension MainView {
    var lifecycleHandlers: some View {
        rootContent
        .onAppear {
            wireCoordinatorHooks()
            installKeyActions?(panelKeyActions)
            AppSearchService.shared.warmUp()
            listState.refresh(dataVersion: store.dataVersion)
            keyAnchorFocused = true
            accessibilityTrusted = PasteService.isAccessibilityTrusted
        }
        .onChange(of: searchFieldFocused) { _, focused in
            if !focused, renamingItemID == nil { keyAnchorFocused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickPopoverDidOpen)) { _ in
            resetSessionState()
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
                if filterState.categoryMenuOpen {
                    moveCategoryMenuHighlight(step)
                } else if extend {
                    extendSelection(offset: step)
                } else {
                    moveSelection(offset: step)
                }
            },
            toggleCategoryMenu: { toggleCategoryMenu() },
            confirm: { keepOpen, plainTextOnly in
                if let id = filterState.categoryMenuHighlight, filterState.categoryMenuOpen {
                    filterState.selectCategory(id)
                } else if let selectedApp = matchedApps.first(where: { $0.id == selectedAppID }) {
                    openApplication(selectedApp)
                } else if isBatchMode {
                    pasteBatch(keepOpen: keepOpen, plainTextOnly: plainTextOnly)
                } else {
                    pasteSelected(keepOpen: keepOpen, plainTextOnly: plainTextOnly)
                }
            },
            escape: { handleEscapeKey() },
            cycleCategory: { step in
                closeMenus()
                cycleCategory(step)
            },
            copySelection: { copyFromSelection() },
            beginRename: { beginRename() },
            toggleFavorite: {
                if let id = listState.selectedID { store.toggleFavorite(id) }
            },
            cycleTimeAnchor: { cycleTimeAnchor() },
            undoDelete: { undoDelete() },
            deleteSelection: { deleteSelection() },
            focusSearch: { searchFieldFocused = true },
            typeToSearch: { event in
                searchFieldFocused = true
                DispatchQueue.main.async { NSApp.sendEvent(event) }
            }
        )
    }

    func handleEscapeKey() {
        if filterState.categoryMenuOpen { closeMenus(); return }
        if isBatchMode { listState.selectionIDs.removeAll(); return }
        if !listState.searchText.isEmpty {
            listState.setSearchText("", dataVersion: store.dataVersion)
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

