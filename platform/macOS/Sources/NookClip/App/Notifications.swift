import Foundation

extension Notification.Name {
    static let openQuickPopover = Notification.Name("NookClip.openQuickPopover")
    static let quickPopoverDidOpen = Notification.Name("NookClip.quickPopoverDidOpen")
    static let openSettings = Notification.Name("NookClip.openSettings")
    static let hotKeyDidChange = Notification.Name("NookClip.hotKeyDidChange")
    static let quickPopoverPreviewStateDidChange = Notification.Name("NookClip.quickPopoverPreviewStateDidChange")
    static let quickPopoverPreserveWindow = Notification.Name("NookClip.quickPopoverPreserveWindow")
    static let languageDidChange = Notification.Name("NookClip.languageDidChange")
    static let appearanceDidChange = Notification.Name("NookClip.appearanceDidChange")
    /// 预览复制等动作后归还面板键盘焦点（脱离可选中文本视图；
    /// DraggablePanel 监听并执行 restoreKeyboardFocus）
    static let restoreKeyboardFocus = Notification.Name("NookClip.restoreKeyboardFocus")
}
