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
        /// 回收站分类槽（当前为占位：无回收站计数，恒按空态置灰渲染）
        static let trash = "trash.fill"
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
        /// 脱敏粘贴（⌃⏎）：盾牌 + 占位符遮罩，语义是「把敏感值换成令牌」
        static let scrub = "shield.lefthalf.filled"
        /// 钉在屏幕（⌘P）：贴条/便签语义
        static let pin = "pin"
        static let pinFilled = "pin.fill"
        /// 顺序粘贴栈（⌥⏎）：层叠+向下箭头的流水意象
        static let pasteStack = "square.stack.3d.down.right"
        /// 标签（⌘L）：与预览工具栏同一个 `#` 符号，保持全应用一致
        static let tag = "number"
        /// 合并粘贴（⏎）：多选工具栏让位收起时的图标形态
        static let merge = "arrow.triangle.merge"
        /// 行内对比（⌘D）：上下两条线段的对照，比通用的 `rectangle.split.2x1`
        /// 更能表达「两段文本对齐后发现差异」
        static let diff = "arrow.left.arrow.right.square"
        /// 退出对比：复用「关闭」语义
        static let diffClose = "xmark.circle.fill"
        /// 差异块跳转（⌥↑ / ⌥↓）
        static let diffJump = "arrow.down.to.line"
        /// 手机快传（局域网扫码免安装双向快传）：手机语义
        static let phoneDrop = "iphone"
        /// 停止分享 / 关闭快传
        static let stop = "stop.circle"
        /// 关闭浮层（圆形叉）
        static let closeCircle = "xmark.circle.fill"
        /// 「更多」菜单（…）：把低频/类型动作收敛到一个入口
        static let more = "ellipsis"
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

    // MARK: - 粘完即焚（Auto-Burn Clipboard）
    //
    // 语义锚点就是「火」：贴完即焚的直觉是纸被烧掉，所以燃烧用火焰（flame）。
    // 验证码提纯与倒计时都落在「计时」上——一次性验证码天然有有效期，
    // 计时器（timer）比抽象的数字更让用户一眼明白「这条留不久」；
    // 完整倒计时的状态用带对勾的时钟（clock.badge.checkmark）收束，读作「到点就安全擦掉」。
    // 「已保留」用手掌（hand.raised）：抬起手把内容按住、不让它烧，动作与火焰相反。
    enum AutoBurn {
        /// 火焰：粘完即焚主符号
        static let burn = "flame"
        /// 实心火焰：需要强调「正在焚」的状态
        static let burnFilled = "flame.fill"
        /// 计时器：验证码自动提纯
        static let otp = "timer"
        /// 手掌：已保留、暂不焚毁
        static let keep = "hand.raised"
        /// 橡皮擦：清空剪贴板
        static let clear = "eraser"
        /// 带对勾的时钟：倒计时擦除
        static let countdown = "clock.badge.checkmark"
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
    //
    // 设置页侧栏用**线性**图标（16pt、约 1.5pt 描边、恒为次要色）：原先这里
    // 全是 .fill 变体，实心块在 208pt 的侧栏里视觉重量过重，会把「当前在哪一页」
    // 的层级从文字上抢走。
    enum Settings {
        static let general = "gearshape"
        static let appearance = "paintpalette"
        static let capture = "tray.and.arrow.down"
        static let history = "externaldrive"
        static let paste = "doc.on.clipboard"
        /// 脱敏（US1 设置页）：一页里放的是脱敏规则，用「看不见」的划眼比
        /// 原来的举手（隐私）更贴题。14pt 下 `text.redaction` 会糊成三条横线，
        /// 像列表图标，所以选轮廓更清楚的 `eye.slash`。
        static let privacy = "eye.slash"
        /// 折叠分组的展开箭头
        static let disclosure = "chevron.down"
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
        /// 局域网连接（手机快传面板：当前网卡地址）
        static let wifi = "wifi"
        /// 无局域网连接（手机快传面板：请先连 Wi-Fi）
        static let wifiSlash = "wifi.slash"
        /// 处理中（手机快传面板：启动中）
        static let loading = "hourglass"
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
        static let diff = "arrow.left.arrow.right.square"
    }
}
