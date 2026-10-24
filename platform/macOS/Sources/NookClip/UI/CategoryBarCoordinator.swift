import SwiftUI

/// 分类过滤状态机（收编自原分类条 CategoryBarCoordinator）。
/// 分类/标签已统一收进搜索框展开面板（Spotlight/Raycast 式）：
/// - 展开面板「按类型」为固定 4 列 × 2 行网格，8 个槽位平权且位置固定——
///   彻底移除原「第 4 槽下拉 + 拖拽排序 + 右键上下移」的复杂状态。
/// - 空分类（计数 0）置灰但仍占位，网格不跳动（由视图层按 count 渲染）。
/// - 「全部」为默认无筛选态，不占网格；⌘[ / ⌘] 在「全部 + 8 类型」间循环。
/// 纯状态类 + 派生函数，数据计数集经方法参数注入（View 层持有数据源）。
@MainActor
@Observable
final class CategoryBarCoordinator {
    init() {}

    /// 过滤网格固定槽位顺序（4 列 × 2 行，读序从左到右、从上到下）：
    /// 收藏、图片、文本、链接 / 代码、文件、颜色、回收站
    /// （回收站 id 7 为占位槽：当前模型无回收站计数，恒按空态置灰渲染）
    static let gridCategoryIDs: [Int] = [8, 2, 1, 4, 5, 3, 6, 7]

    /// 过滤网格的分类（按固定槽序；缺失分类以 count 0 的空槽补齐，保证网格永不塌缩）。
    /// `categories` 为管线输出的分类计数集（仅含计数 > 0 的类型 + 常驻类目）。
    func filterGridCategories(_ categories: [SidebarCategory]) -> [SidebarCategory] {
        let byID = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Self.gridCategoryIDs.map { id in
            byID[id] ?? SidebarCategory(id: id, name: Self.fallbackName(for: id), symbol: Self.fallbackSymbol(for: id), count: 0)
        }
    }

    /// ⌘[ / ⌘] 循环序：「全部」(0) 在首位 + 网格中有计数（非空）的类型槽。
    /// 空分类（如回收站占位）不进入循环，避免切到空列表；网格本身仍展示全部 8 槽。
    func orderedCategoryIDs(in categories: [SidebarCategory]) -> [Int] {
        [0] + filterGridCategories(categories).filter { $0.count > 0 }.map(\.id)
    }

    /// ⌘[ / ⌘] 在「全部 ↔ 类型」间循环后的目标分类 id（序与网格同一 id 空间）
    func cycledCategory(selection: Int, step: Int, in categories: [SidebarCategory]) -> Int? {
        let ids = orderedCategoryIDs(in: categories)
        guard ids.count > 1 else { return nil }
        let index = ids.firstIndex(of: selection) ?? 0
        return ids[(index + step + ids.count) % ids.count]
    }

    // MARK: - 空槽兜底元数据（计数 0 时缺分类定义）

    private static func fallbackName(for id: Int) -> String {
        switch id {
        case 0: return L10n.tr("category.all")
        case 1: return L10n.tr("category.text")
        case 2: return L10n.tr("category.image")
        case 3: return L10n.tr("category.file")
        case 4: return L10n.tr("category.link")
        case 5: return L10n.tr("category.code")
        case 6: return L10n.tr("category.color")
        case 7: return L10n.tr("category.trash")
        case 8: return L10n.tr("category.favorite")
        default: return ""
        }
    }

    private static func fallbackSymbol(for id: Int) -> String {
        switch id {
        case 0: return NookClipIcon.Nav.all
        case 1: return NookClipIcon.Category.text
        case 2: return NookClipIcon.Category.image
        case 3: return NookClipIcon.Category.file
        case 4: return NookClipIcon.Category.url
        case 5: return NookClipIcon.Category.code
        case 6: return NookClipIcon.Category.color
        case 7: return NookClipIcon.Category.trash
        case 8: return NookClipIcon.Action.favoriteFilled
        default: return "circle"
        }
    }
}
