import SwiftUI

// MARK: - 分类条与搜索过滤接线（T037/T038 · 拆自 MainView，纯移动）
// 分类状态机本体见 CategoryBarCoordinator（契约 R10）；
// 本扩展承接 MainView 侧的视图接线（分类条 chip / 第 4 槽下拉 / 键盘循环 /
// 搜索建议与筛选菜单），数据源仍由 MainView 持有。

extension MainView {
    // MARK: 分类条派生（转发协调器；输入 = 管线输出的分类计数集）

    /// 手动序（nil = 自动数量序）
    var customCategoryOrder: [Int]? {
        categoryBar.customCategoryOrder
    }

    /// 手动序生效时的全量分类（「全部」首位 + 手动序）；自动序为 nil
    var manuallyOrderedCategories: [SidebarCategory]? {
        categoryBar.manuallyOrderedCategories(pipelineOutput.categories)
    }

    /// 筛选条固定展示的分类（全部/收藏常驻 + 数量前 1；手动序取前 3 位）
    var fixedCategories: [SidebarCategory] {
        categoryBar.fixedCategories(in: pipelineOutput.categories)
    }

    /// 可经第 4 槽动态切换的分类
    var switchableCategories: [SidebarCategory] {
        categoryBar.switchableCategories(in: pipelineOutput.categories)
    }

    /// 第 4 槽占位类目
    var slot5Category: SidebarCategory? {
        categoryBar.slot5Category(in: pipelineOutput.categories, effective: effectiveCategory)
    }

    /// 第 4 槽下拉项（切换入口 + 排序面；「全部」不入列）
    var categoryMenuCategories: [SidebarCategory] {
        categoryBar.categoryMenuCategories(in: pipelineOutput.categories)
    }

    /// 键盘循环序（⌘[ / ⌘]）
    var orderedCategoryIDs: [Int] {
        categoryBar.orderedCategoryIDs(in: pipelineOutput.categories)
    }

    /// ⌘[ / ⌘] 在分类间循环，序与筛选条同一 id 空间
    func cycleCategory(_ step: Int) {
        if let next = categoryBar.cycledCategory(
            selection: categorySelection, step: step, in: pipelineOutput.categories
        ) {
            categorySelection = next
        }
    }

    var categoryMenuOptions: [DropdownOption<Int>] {
        categoryMenuCategories.map { category in
            DropdownOption(
                id: category.id,
                title: category.name,
                symbol: category.symbol,
                count: category.count,
                isSelected: category.id == effectiveCategory
            )
        }
    }

    /// 下拉内拖拽重排；选中类目被挤出可见条时过滤回落「全部」（语义见协调器注释）
    func reorderCategory(_ dragging: Int, before target: Int) {
        if categoryBar.reorderCategory(
            dragging, before: target, in: pipelineOutput.categories, selection: categorySelection
        ) {
            categorySelection = 0
        }
    }

    /// 右键「上移/下移」：可见序内相邻项换算为完整序插入
    func nudgeCategory(_ id: Int, offset: Int) {
        if categoryBar.nudgeCategory(id, offset: offset, in: pipelineOutput.categories, selection: categorySelection) {
            categorySelection = 0
        }
    }

    /// 清除手动序，回到自动数量序
    func resetCategoryOrder() {
        categoryBar.resetCategoryOrder()
    }

    func toggleCategoryMenu() {
        guard !categoryMenuCategories.isEmpty else { return }
        filterState.toggleCategoryMenu(initialHighlight: categoryMenuCategories.first?.id)
    }

    func moveCategoryMenuHighlight(_ offset: Int) {
        filterState.moveCategoryMenuHighlight(offset, ids: categoryMenuCategories.map(\.id))
    }

}
