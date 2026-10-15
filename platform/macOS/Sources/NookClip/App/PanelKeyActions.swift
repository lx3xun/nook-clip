import AppKit

// MARK: - 面板键盘动作表（AppKit 键位分发表 → SwiftUI 主视图动作）

/// 面板内快捷键的动作集：`DraggablePanel` 键盘分发表按物理键位 + 修饰符
/// 匹配后调用，`MainView` 在 onAppear 提供实现（闭包捕获的 @State 经包装器
/// 存储读取，始终为当前值——与 coordinator 钩子同一接线模式）。
/// 键位匹配归分发表（DraggablePanel），语义分派（下拉开合时 ↑↓ 移动高亮、
/// 批量/单条粘贴等依赖视图状态的路由）归动作实现，两层职责不重叠。
@MainActor
struct PanelKeyActions {
    /// ↑/↓（含按住重复）：分类下拉打开时移动高亮，否则移动/扩展（⇧）列表选中。
    /// 参数：步进（-1 上移 / +1 下移）、是否 ⇧ 扩展选区
    var arrow: (_ step: Int, _ extend: Bool) -> Void
    /// ⌘↓：开合分类下拉
    var toggleCategoryMenu: () -> Void
    /// ⏎（⌘ 保持面板打开 / ⌥ 纯文本）：下拉打开时选中高亮分类，否则粘贴选中
    var confirm: (_ keepOpen: Bool, _ plainTextOnly: Bool) -> Void
    /// Esc 分层清空：下拉 → 批量选区 → 关键词 → 分类 → 时间定位 → 收起面板
    var escape: () -> Void
    /// ⌘[ / ⌘]：分类循环（⌘[ 上一个，⌘] 下一个）
    var cycleCategory: (_ step: Int) -> Void
    /// ⌘C：拷贝选中（仅列表态分发，搜索态 ⌘C 归输入框复制文本）
    var copySelection: () -> Void
    /// ⌘R：重命名选中条目（仅列表态分发）
    var beginRename: () -> Void
    /// ⌘S：收藏/取消收藏选中条目
    var toggleFavorite: () -> Void
    /// ⌘T：循环定位下一个时间分组
    var cycleTimeAnchor: () -> Void
    /// ⌘Z：撤销最近一次删除
    var undoDelete: () -> Void
    /// ⌘⌫：删除选中条目
    var deleteSelection: () -> Void
    /// ⌘F：聚焦搜索框
    var focusSearch: () -> Void
    /// 列表态打字即搜索（Spotlight 式）：聚焦搜索框并把该字符事件重投递进输入框
    var typeToSearch: (_ event: NSEvent) -> Void
}
