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

    // MARK: 分类（分类已收进搜索框展开面板，固定 8 槽无手动序种子槽）
    /// 分类手动序（逗号分隔 id；空 = 自动数量序）——当前仅 CategoryOrdering 纯函数保留，UI 不再暴露排序
    case customCategoryOrder

    // MARK: 外观与交互定制（005-ui-ux-redesign）
    /// 选中行高亮风格（solidAccent / subtleAccent，缺省 solidAccent）
    case rowSelectionStyle

    // MARK: 首次启动引导
    /// 是否已经完成过首次启动引导（首启自动唤出面板 + 菜单栏提示）
    case hasLaunchedBefore

    // MARK: 表单拆解
    /// 复制表单内容时是否主动提示拆解（默认开启）
    case formBurstAutoSuggestEnabled

    // MARK: 终端安全粘贴（P0 · Terminal Safe-Paste）
    /// 往终端粘贴时是否启用防误触护栏（默认开启）
    case terminalSafePasteEnabled
    /// 是否同时保护 VS Code / Cursor / Xcode / JetBrains 等编辑器与 AI 工具的内置终端（默认开启）
    case terminalSafePasteIdeEnabled

    // MARK: 粘完即焚（Auto-Burn Clipboard）
    /// 复制验证码时自动提纯为纯数字（默认开启）
    case autoBurnOtpEnabled
    /// 敏感内容粘贴 1 次后立即清空系统剪贴板（默认开启；关闭则仅按 sensitiveClipboardTimeout 倒计时擦除）
    case autoBurnClearOnPaste
    /// 验证码类记录粘贴 5 秒后从历史彻底删除（默认关闭）
    case autoBurnHistoryBurnEnabled

    // MARK: 顺序粘贴栈（Paste Stack）
    /// 粘贴栈浮窗用户拖拽后的屏幕坐标（"x,y"）
    case pasteStackPanelOrigin = "pasteStack.panelOrigin"

    // MARK: 外观主题（设置页/主面板/快捷弹窗/贴条共用）
    /// 界面外观（system / light / dark）
    case appearance
    /// 材质半透明效果开关
    case enableTranslucency
    /// 背景不透明度（0~1，越小越透）
    case backgroundTransparency

    // MARK: 捕获与敏感保护
    /// 是否启用敏感信息检测与保护（默认开启）
    case enableSensitiveProtection
    /// 敏感内容在剪贴板的保留秒数（到期自动擦除；0 = 不擦除）
    case sensitiveClipboardTimeout

    // MARK: 历史与同步
    /// 历史最大保留条数
    case historyMaxItemCount
    /// 历史载荷磁盘占用上限（MB）
    case historyDiskLimitMB
    /// 是否启用 iCloud 同步
    case enableICloudSync

    // MARK: 通用设置
    /// 登录时自动启动
    case launchAtLogin
    /// Sparkle 自动检查更新（Sparkle 框架约定键名，保持原样）
    case sparkAutoCheck = "SUEnableAutomaticChecks"

    // MARK: 粘贴行为
    /// 粘贴成功提示音效
    case pasteSoundEnabled

    // MARK: 设备标识（iCloud 同步设备 ID，一次生成终身不变）
    case syncDeviceID = "nook.sync.deviceID"
}
