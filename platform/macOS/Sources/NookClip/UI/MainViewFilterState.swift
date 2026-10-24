import SwiftUI

/// 搜索框展开过滤面板（类型网格 + 标签流式胶囊）与时间锚点定位的状态机。
/// 分类/标签统一收进搜索框展开面板后，原「第 4 槽下拉菜单开合/高亮」状态已移除；
/// 浮层开合仅作为「持久展开」标记（聚焦搜索框且未打字时由视图派生展示）。
/// 状态迁移集中在协调器；滚动、聚焦等宿主副作用经钩子注入（保持 View 层接线）。
@MainActor
@Observable
final class MainViewFilterState {
    /// 时间锚点「全部」项的哨兵 id（锚点条首项：取消定位并回列表顶部）
    static let timeAllOptionID = "nook.time.all"

    /// 时间锚点定位（选中的 TimeGroup id；nil = 未定位。定位不隐藏条目，仅滚动）
    var timeSelection: String?
    /// 过滤面板显式展开（点搜索框 / ⌘↓ 触发；聚焦且未打字时也派生展开）
    var filterPanelOpen = false
    var stickyGroupID: String?

    // MARK: 宿主副作用钩子（View 在 onAppear 接线）

    /// 分类被选中（网格/⌘[⌘]/胶囊清除）：View 负责 categorySelection 与聚焦
    var onCategorySelected: ((Int) -> Void)?
    /// 时间定位复位（「全部」/Esc 清筛选）：View 负责滚回列表顶部
    var onTimeAnchorReset: (() -> Void)?
    /// 定位到时间分组：View 负责滚动到组头
    var onSelectTimeGroup: ((String) -> Void)?

    /// 关闭菜单类浮层（保留接口语义；分类下拉已移除，无实际状态）
    func closeMenus() {
        filterPanelOpen = false
    }

    /// 开合过滤面板（点击搜索框 / ⌘↓）
    func toggleFilterPanel() {
        filterPanelOpen.toggle()
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
        filterPanelOpen = false
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
