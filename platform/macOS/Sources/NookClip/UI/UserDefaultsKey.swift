import Foundation

/// UserDefaults key 集中枚举（T042⑥）：跨文件裸字符串收敛为单一来源，
/// 拼写错误在编译期即暴露。新增持久化 key 必须登记在此。
enum UserDefaultsKey: String {
    // MARK: 面板几何（DraggablePanel 写入 / QuickPopoverController 读取）
    /// 展开态面板宽度（拖拽记录）
    case panelWidth
    /// 折叠态（纯列表）面板宽度（拖拽记录）
    case panelCollapsedWidth
    /// 用户自定义面板高度（拖拽记录）
    case panelCustomHeight

    // MARK: 预览区
    /// 预览区展开态（MainView @AppStorage 唯一事实来源）
    case showsPreview

    // MARK: 全局热键（HotKeyManager 写入 / PasteSettingsTab 展示）
    case hotkeyKeyCode = "hotkey_keyCode"
    case hotkeyModifiers = "hotkey_modifiers"
    case hotkeyDisplay = "hotkey_display"

    // MARK: 更新源（GeneralSettingsTab 选择 / UpdateService 读取）
    case updateSource

    // MARK: 分类条（T037 · CategoryBarCoordinator 持久化）
    /// 第 4 槽（动态槽）用户固定的占位类目 id（-1 = 未指定）
    case filterSlot5CategoryID = "filterSlot5CategoryID"
    /// 分类手动序（逗号分隔 id；空 = 自动数量序）
    case customCategoryOrder

    // MARK: 外观与交互定制（005-ui-ux-redesign）
    /// 选中行高亮风格（solidAccent / subtleAccent，缺省 solidAccent）
    case rowSelectionStyle
    /// 时间快速跳转模式（indexRail / groupHeaderMenu，缺省 indexRail）
    case timelineJumpMode

    // MARK: 首次启动引导
    /// 是否已经完成过首次启动引导（首启自动唤出面板 + 菜单栏提示）
    case hasLaunchedBefore
}
