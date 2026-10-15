import SwiftUI

/// 分类条状态机（T037 · 契约 R10）：收编自 MainView 的
/// fixedCategories / switchableCategories / slot5Category / categoryMenuCategories /
/// orderedCategoryIDs / reorderCategory / nudgeCategory 及第 4 槽持久化逻辑。
/// 纯状态类 + 钩子注入，对齐 MainViewFilterState 既有模式：
/// 分类计数集、当前选中分类等输入经方法参数注入（View 层持有数据源），
/// 手动序与第 4 槽固定项持久化在协调器内直接读写 UserDefaults（key 见 UserDefaultsKey）。
/// 视图接线见 MainView+Category.swift；纯移动重构，行为零变化（宪法 IV）。
@MainActor
@Observable
final class CategoryBarCoordinator {
    /// 第 4 槽用户固定的占位类目 id（-1 = 未指定，取数量最高的可切换类目）
    var slot5PinnedID: Int {
        didSet { defaults.set(slot5PinnedID, forKey: UserDefaultsKey.filterSlot5CategoryID.rawValue) }
    }

    /// 分类手动序原始串（逗号分隔 id；空 = 自动数量序。解析/重排纯函数见 CategoryOrdering）
    var customCategoryOrderRaw: String {
        didSet { defaults.set(customCategoryOrderRaw, forKey: UserDefaultsKey.customCategoryOrder.rawValue) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // -1 = 未指定（与旧 @AppStorage 缺省一致）
        slot5PinnedID = defaults.object(forKey: UserDefaultsKey.filterSlot5CategoryID.rawValue) as? Int ?? -1
        customCategoryOrderRaw = defaults.string(forKey: UserDefaultsKey.customCategoryOrder.rawValue) ?? ""
    }

    // MARK: 派生（输入经参数注入，保持协调器不持有数据源）

    /// 手动序（nil = 自动数量序）
    var customCategoryOrder: [Int]? {
        CategoryOrdering.parse(customCategoryOrderRaw)
    }

    /// 手动序生效时的全量分类（「全部」首位 + 手动序）；自动序为 nil
    func manuallyOrderedCategories(_ categories: [SidebarCategory]) -> [SidebarCategory]? {
        guard let order = customCategoryOrder else { return nil }
        return CategoryOrdering.apply(order, to: categories)
    }

    /// 筛选条固定展示的分类。自动序：全部/收藏常驻 + 数量前 1 的类型类目；
    /// 手动序：生效序前 3 位（「全部」恒在首位）。
    /// 加第 4 槽动态占位共 4 个类目
    func fixedCategories(in categories: [SidebarCategory]) -> [SidebarCategory] {
        if let ordered = manuallyOrderedCategories(categories) {
            return Array(ordered.prefix(3))
        }
        let pinned = categories.filter { $0.id == 0 || $0.id == 8 }
        let rest = categories
            .filter { $0.id != 0 && $0.id != 8 }
            .sorted { $0.count > $1.count }
        return pinned + rest.prefix(1)
    }

    /// 可经第 4 槽动态切换的分类：生效序中未被固定 chip 占用的部分
    /// （自动序按数量降序，手动序按手动序）
    func switchableCategories(in categories: [SidebarCategory]) -> [SidebarCategory] {
        let fixedIDs = Set(fixedCategories(in: categories).map(\.id))
        if let ordered = manuallyOrderedCategories(categories) {
            return ordered.filter { !fixedIDs.contains($0.id) }
        }
        let rest = categories
            .filter { !fixedIDs.contains($0.id) }
            .sorted { $0.count > $1.count }
        if let pinnedIndex = rest.firstIndex(where: { $0.id == slot5PinnedID }) {
            var adjusted = rest
            let pinned = adjusted.remove(at: pinnedIndex)
            adjusted.insert(pinned, at: 0)
            return adjusted
        }
        return rest
    }

    /// 第 4 槽占位类目：生效分类在可切换集合内 → 它（选中项永远可见）；
    /// 否则自动序下取用户固定项（仍存在时）、再退数量最高者（默认态）；
    /// 手动序下忽略固定项，退生效序下一位
    func slot5Category(in categories: [SidebarCategory], effective: Int) -> SidebarCategory? {
        let rest = switchableCategories(in: categories)
        if let active = rest.first(where: { $0.id == effective }) { return active }
        if customCategoryOrder == nil, let pinned = rest.first(where: { $0.id == slot5PinnedID }) { return pinned }
        return rest.first
    }

    /// 第 4 槽下拉项：全部类目（含固定 chip 与当前占位）按生效序展示——
    /// 既是切换入口也是排序面（行拖拽/右键上移下移）；「全部」恒为首 chip 不入列
    func categoryMenuCategories(in categories: [SidebarCategory]) -> [SidebarCategory] {
        let ordered = manuallyOrderedCategories(categories)
            ?? (fixedCategories(in: categories) + switchableCategories(in: categories))
        return ordered.filter { $0.id != 0 }
    }

    /// 键盘循环序（⌘[ / ⌘]）：固定 chip 在前 + 可切换类目在后（自动数量序/手动序）。
    /// 序位稳定、不随占位/选中变化——占位类目会被选中态顶到第 4 槽展示，
    /// 但循环位置不变；否则选中项成为占位后下一步 → 落到下拉首项（常为原占位），
    /// 在两项间来回乒乓
    func orderedCategoryIDs(in categories: [SidebarCategory]) -> [Int] {
        fixedCategories(in: categories).map(\.id) + switchableCategories(in: categories).map(\.id)
    }

    /// ⌘[ / ⌘] 在分类间循环后的目标分类 id，序与筛选条同一 id 空间
    func cycledCategory(selection: Int, step: Int, in categories: [SidebarCategory]) -> Int? {
        let ids = orderedCategoryIDs(in: categories)
        guard ids.count > 1 else { return nil }
        let index = ids.firstIndex(of: selection) ?? 0
        return ids[(index + step + ids.count) % ids.count]
    }

    /// 当前生效的完整重排序（存储序 + 可见序补全 + 默认序兜底，含隐藏类目）
    func effectiveCategoryOrder(in categories: [SidebarCategory]) -> [Int] {
        CategoryOrdering.effectiveOrder(
            stored: customCategoryOrder,
            visible: categoryMenuCategories(in: categories).map(\.id)
        )
    }

    /// 下拉内拖拽重排（dragging 移到 target 前）；首次拖拽即从自动数量序切入手动序。
    /// 返回 true = 选中类目被此次重排挤出可见条（前 3 chip + 第 4 槽），
    /// 调用方须把过滤回落「全部」——否则「选中项占槽」规则会把被拖走的类目
    /// 继续钉在槽上，过滤与胶囊看起来都没变；原本就在条外的深位选中保持不受影响
    @discardableResult
    func reorderCategory(
        _ dragging: Int,
        before target: Int,
        in categories: [SidebarCategory],
        selection: Int
    ) -> Bool {
        let oldVisibleIDs = manuallyOrderedCategories(categories)?.map(\.id)
            ?? categoryMenuCategories(in: categories).map(\.id)
        let order = CategoryOrdering.reorder(effectiveCategoryOrder(in: categories), dragging: dragging, before: target)
        customCategoryOrderRaw = CategoryOrdering.serialize(order)
        return CategoryOrdering.selectionPushedOutOfBar(
            oldVisible: oldVisibleIDs,
            newVisible: CategoryOrdering.apply(order, to: categories).map(\.id),
            selected: selection
        )
    }

    /// 右键「上移/下移」：在可见序内找相邻项，换算为完整序上的插入
    /// （隐藏类目夹在中间时不参与让位，仅可见相对位置变化）。
    /// 返回值语义同 reorderCategory
    @discardableResult
    func nudgeCategory(_ id: Int, offset: Int, in categories: [SidebarCategory], selection: Int) -> Bool {
        let visible = categoryMenuCategories(in: categories).map(\.id)
        guard let index = visible.firstIndex(of: id) else { return false }
        let target = index + offset
        guard visible.indices.contains(target) else { return false }
        if offset < 0 {
            return reorderCategory(id, before: visible[target], in: categories, selection: selection)
        } else {
            return reorderCategory(visible[target], before: id, in: categories, selection: selection)
        }
    }

    /// 清除手动序，回到自动数量序（第 4 槽固定随之恢复生效）
    func resetCategoryOrder() {
        customCategoryOrderRaw = ""
    }
}
