import SwiftUI

/// 分类下拉菜单与时间锚点定位的状态机（第 4 槽菜单开合、高亮、时间锚点、吸顶组）。
/// 状态迁移集中在协调器；滚动、聚焦、槽固定等宿主副作用经钩子注入（保持 View 层接线）。
@MainActor
@Observable
final class MainViewFilterState {
    /// 时间锚点「全部」项的哨兵 id（锚点条首项：取消定位并回列表顶部）
    static let timeAllOptionID = "nook.time.all"

    /// 时间锚点定位（选中的 TimeGroup id；nil = 未定位。定位不隐藏条目，仅滚动）
    var timeSelection: String?
    /// 分类第 4 槽切换下拉菜单（槽尾 ▾ 入口；⌘↓ 或点击打开）
    var categoryMenuOpen = false
    var categoryMenuHighlight: Int?
    var stickyGroupID: String?

    // MARK: 宿主副作用钩子（View 在 onAppear 接线）

    /// 分类被选中（下拉/⌘数字/chip）：View 负责 categorySelection、第 4 槽固定与聚焦
    var onCategorySelected: ((Int) -> Void)?
    /// 时间定位复位（「全部」/Esc 清筛选）：View 负责滚回列表顶部
    var onTimeAnchorReset: (() -> Void)?
    /// 定位到时间分组：View 负责滚动到组头
    var onSelectTimeGroup: ((String) -> Void)?

    var isAnyMenuOpen: Bool { categoryMenuOpen }

    func closeMenus() {
        categoryMenuOpen = false
        categoryMenuHighlight = nil
    }

    /// 第 4 槽下拉开合（无可切换项时不打开）
    func toggleCategoryMenu(initialHighlight: Int?) {
        if categoryMenuOpen {
            closeMenus()
        } else {
            categoryMenuHighlight = initialHighlight
            categoryMenuOpen = true
        }
    }

    /// 菜单内 ↑↓ 高亮循环（ids 为当前菜单项 id 序列）
    func moveCategoryMenuHighlight(_ offset: Int, ids: [Int]) {
        guard !ids.isEmpty else { return }
        let currentIndex = categoryMenuHighlight.flatMap { ids.firstIndex(of: $0) } ?? (offset > 0 ? -1 : ids.count)
        let nextIndex = (currentIndex + offset + ids.count) % ids.count
        categoryMenuHighlight = ids[nextIndex]
    }

    /// 组头 frame 偏好判定出的吸顶组写入（仅变化时写入，滚动中不触发无效重渲染）
    func updateStickyGroup(_ id: String?) {
        guard stickyGroupID != id else { return }
        stickyGroupID = id
    }

    /// 根据可见行坐标与当前选中项计算顶部所属时间分组 ID：
    /// 1) 优先取剪贴板视口顶部第一条可见行所属分组（鼠标滚轮滚动时实时跟随视口顶部）
    /// 2) 仅当尚未上报任何可见行坐标（如初始布局首帧）时，回退到 selectedID 所属分组或首组
    static func resolveStickyGroupID<Item: TimelineItem>(
        groups: [TimeGroup<Item>],
        frames: [String: CGRect],
        bounds: (top: CGFloat, bottom: CGFloat),
        selectedID: UUID?
    ) -> String? where Item.ID == UUID {
        guard !groups.isEmpty else { return nil }
        let topVisibleCandidate = frames
            .filter { $0.value.maxY > bounds.top + 2 && $0.value.minY < bounds.bottom }
            .min { $0.value.minY < $1.value.minY }
        if let topKey = topVisibleCandidate?.key,
           let group = groups.first(where: { grp in grp.items.contains { $0.id.uuidString == topKey } }) {
            return group.id
        }
        if let selectedID,
           let selectedGroup = groups.first(where: { grp in grp.items.contains { $0.id == selectedID } }) {
            return selectedGroup.id
        }
        return groups.first?.id
    }

    // MARK: 选中动作（含钩子副作用）

    func selectCategory(_ id: Int) {
        closeMenus()
        onCategorySelected?(id)
    }

    /// 锚点条连续定位（点击/按住拖动经过即锚定，通讯录式）：
    /// 不做「再点当前项取消」切换语义——取消定位统一走「全部」项；
    /// 重复锚定同一组是无操作，拖动扫过不会反复触发滚动。
    func railScrub(to id: String) {
        if id == Self.timeAllOptionID {
            guard timeSelection != nil else { return }
            timeSelection = nil
            onTimeAnchorReset?()
        } else {
            guard timeSelection != id else { return }
            timeSelection = id
            onSelectTimeGroup?(id)
        }
    }

    /// 筛选条件（分类/关键词）变化或 Esc 清筛选时重置时间锚点回「全部」：
    /// 锚定的是旧过滤结果里的组，列表也不再位于锚定位。
    func resetTimeAnchor() {
        guard timeSelection != nil else { return }
        timeSelection = nil
        onTimeAnchorReset?()
    }
}
