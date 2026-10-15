import SwiftUI

// MARK: - NookClip 界面图标与符号规范 (Design System 2.0 §6)

/// 图标标准尺寸阶梯 (Icon Sizing Scale §6.2)
enum NookClipIconSize {
    /// 8~9pt / Semibold：微标、下拉微三角、时间指示、多选勾选框、加密盾牌微标
    static let micro: CGFloat = 9
    static let microSmall: CGFloat = 8
    static let microChevron: CGFloat = 7

    /// 11~12pt / Medium 或 Regular：搜索栏、工具栏按钮、卡片行内快捷动作、快捷键录制
    static let compact: CGFloat = 11
    static let compactMedium: CGFloat = 12

    /// 13.5~14pt / Semibold 或 Medium：列表行内容类型主卡片符号、设置单选状态勾选
    static let regular: CGFloat = 13.5
    static let regularMedium: CGFloat = 14

    /// 17~20pt / Medium 或 Semibold：设置 Tab 导航大标、系统权限授权大标
    static let title: CGFloat = 17
    static let titleLarge: CGFloat = 20
    static let titleDisplay: CGFloat = 21

    /// 28~40pt / Regular 或 Light：主窗口空白占位、排除列表空状态、二维码大卡片
    static let hero: CGFloat = 28
    static let heroMedium: CGFloat = 30
    static let heroLarge: CGFloat = 40
}

/// NookClip 全局图标 SF Symbol 字符串常量契约 (Iconography Contract §6.9)
enum NookClipIcon {
    // MARK: - 模块一：系统框架与全局入口 (§6.3)
    enum Frame {
        static let sidebarTrailing = "sidebar.trailing"
        static let sidebarLeading = "sidebar.leading"
    }

    // MARK: - 模块二：搜索与导航过滤 (§6.4)
    enum Search {
        static let magnify = "magnifyingglass"
        static let clear = "xmark.circle.fill"
    }

    enum Nav {
        static let all = "square.grid.2x2"
        static let chevronDown = "chevron.down"
        static let chevronUpDown = "chevron.up.chevron.down"
        static let checkmark = "checkmark"
        static let reorder = "line.3.horizontal"
        static let arrowUp = "arrow.up"
        static let arrowDown = "arrow.down"
        static let resetOrder = "arrow.triangle.2.circlepath"
        static let clock = "clock"
        static let help = "questionmark.circle"
    }

    // MARK: - 模块三：内容类型符号与来源 App 兜底矩阵 (§6.5)
    enum Category {
        static let text = "doc.text"
        static let code = "chevron.left.forwardslash.chevron.right"
        static let json = "curlybraces.square.fill"
        static let url = "globe.americas.fill"
        static let file = "doc.fill"
        static let image = "photo.fill"
        static let color = "paintpalette.fill"
        static let sensitive = "lock.shield.fill"
    }

    enum SourceAppFallback {
        static let safari = "safari"
        static let xcode = "chevron.left.forwardslash.chevron.right"
        static let wechat = "message.fill"
        static let figma = "paintbrush.pointed"
        static let finder = "smiley"
        static let terminal = "terminal"
        static let notes = "text.alignleft"
        static let screenshot = "viewfinder"
        static let fallback = "app"
    }

    // MARK: - 模块四：详情画布与交互卡片动作 (§6.6)
    enum Action {
        static let favorite = "star"
        static let favoriteFilled = "star.fill"
        static let delete = "trash"
        static let deleteFilled = "trash.fill"
        static let openExternal = "arrow.up.right.square"
        static let revealInFinder = "folder"
        static let qrcode = "qrcode"
        static let copy = "doc.on.doc"
        static let copied = "checkmark"
        static let ocr = "text.viewfinder"
    }

    enum Badge {
        static let favorite = "star.fill"
    }

    enum Sensitive {
        static let lock = "lock"
        static let shieldOk = "checkmark.shield"
        static let reveal = "eye"
        static let remask = "eye.slash"
    }

    enum Feedback {
        static let warning = "exclamationmark.triangle.fill"
        static let link = "link"
        static let doc = "doc"
    }

    enum Empty {
        static let clipboard = "clipboard"
        static let preview = "rectangle.on.rectangle"
        static let search = "magnifyingglass"
        static let qrcode = "qrcode"
        static let excluded = "shield.slash"
    }

    // MARK: - 模块五：偏好设置与系统状态指示 (§6.7)
    enum Settings {
        static let general = "gearshape.fill"
        static let appearance = "paintpalette.fill"
        static let capture = "tray.and.arrow.down.fill"
        static let history = "externaldrive.fill"
        static let paste = "doc.on.clipboard.fill"
    }

    enum Excluded {
        static let empty = "shield.slash"
        static let addRunning = "plus.app"
        static let chooseFinder = "folder"
        static let remove = "xmark.circle.fill"
    }

    enum Status {
        static let tray = "tray.fill"
        static let success = "checkmark.circle.fill"
        static let error = "exclamationmark.triangle.fill"
        static let sensitiveSync = "shield.checkered"
        static let tombstoneSync = "clock.arrow.circlepath"
        static let plaintextNotice = "lock.open"
    }
    enum TCC {
        static let trusted = "checkmark.circle.fill"
        static let untrusted = "lock.shield.fill"
    }

    enum Control {
        static let radioSelected = "checkmark.circle.fill"
        static let checkmark = "checkmark"
        static let keyboard = "keyboard"
        static let resetHotkey = "arrow.counterclockwise"
    }

    // MARK: - 列表行快捷菜单 (§6.8)
    enum Context {
        static let copy = "doc.on.doc"
        static let rename = "pencil"
        static let paste = "doc.on.clipboard"
        static let favorite = "star"
        static let favoriteFilled = "star.fill"
        static let markSensitive = "lock"
        static let unmarkSensitive = "lock.open"
        static let delete = "trash"
    }
}
