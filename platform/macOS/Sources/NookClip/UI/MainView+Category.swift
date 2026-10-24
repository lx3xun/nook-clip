import SwiftUI

// MARK: - 分类过滤面板与搜索过滤接线（收编自原分类条，纯移动 + 简化）
// 分类/标签统一收进搜索框展开面板（Spotlight/Raycast 式）：
// 原「第 4 槽下拉 / 拖拽重排 / 右键上下移」复杂状态已彻底移除，
// 「按类型」改为固定 4 列 × 2 行网格（8 槽平权、位置固定）。
// 状态机本体见 CategoryBarCoordinator（网格派生 + ⌘[⌘] 循环）；
// 本扩展承接 MainView 侧的视图接线，数据源仍由 MainView 持有。

extension MainView {
    // MARK: 网格派生（转发协调器；输入 = 管线输出的分类计数集）

    /// 8 个固定类型槽（空槽 count == 0，网格永不塌缩）
    var filterGridCategories: [SidebarCategory] {
        categoryBar.filterGridCategories(pipelineOutput.categories)
    }

    /// 键盘循环序（⌘[ / ⌘]）：「全部」+ 8 类型
    var orderedCategoryIDs: [Int] {
        categoryBar.orderedCategoryIDs(in: pipelineOutput.categories)
    }

    /// ⌘[ / ⌘] 在「全部 ↔ 类型」间循环
    func cycleCategory(_ step: Int) {
        if let next = categoryBar.cycledCategory(
            selection: categorySelection, step: step, in: pipelineOutput.categories
        ) {
            categorySelection = next
        }
    }

    /// 当前生效分类在网格中的分类对象（用于搜索框内嵌分类胶囊；id 0 = 无）
    var activeCategoryObject: SidebarCategory? {
        guard effectiveCategory != 0 else { return nil }
        return filterGridCategories.first { $0.id == effectiveCategory }
    }
}
