import AppKit
import SwiftUI
// MARK: - NookClip 设计令牌（nook-DESIGN.md · Phase 2）
// 基调: Default (Neutral Modern) + macOS 14 (Sonoma) 原生语言
// 映射规则: HTML/CSS rgba 令牌 → SwiftUI Color；px = pt 1:1

enum NookClip {

    // MARK: - 动态色彩工厂 (支持浅色 / 深色外观自适应)
    static func dynamicColor(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            return match == .darkAqua ? dark : light
        })
    }

    /// 动态系统强调色（跟随 macOS 系统设置 Accent Color，并按深浅模式分配透明度）
    static func dynamicAccentColor(lightAlpha: CGFloat, darkAlpha: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            let alpha = (match == .darkAqua) ? darkAlpha : lightAlpha
            return NSColor.controlAccentColor.withAlphaComponent(alpha)
        })
    }

    /// 动态 NSColor（AppKit 侧着色用）：与 dynamicColor 同一套外观切换
    private static func dynamicNSColor(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            return match == .darkAqua ? nsColorHex(dark) : nsColorHex(light)
        }
    }

    private static func dynamicNSColor(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            return match == .darkAqua ? dark : light
        }
    }

    private static func dynamicRGBA(
        lr: CGFloat, lg: CGFloat, lb: CGFloat, la: CGFloat,
        dr: CGFloat, dg: CGFloat, db: CGFloat, da: CGFloat
    ) -> Color {
        dynamicColor(
            light: NSColor(srgbRed: lr / 255.0, green: lg / 255.0, blue: lb / 255.0, alpha: la),
            dark: NSColor(srgbRed: dr / 255.0, green: dg / 255.0, blue: db / 255.0, alpha: da)
        )
    }

    private static func dynamicHex(
        light: UInt32, lightAlpha: CGFloat = 1.0,
        dark: UInt32, darkAlpha: CGFloat = 1.0
    ) -> Color {
        dynamicColor(
            light: nsColorHex(light, alpha: lightAlpha),
            dark: nsColorHex(dark, alpha: darkAlpha)
        )
    }

    private static func nsColorHex(_ hex: UInt32, alpha: CGFloat = 1.0) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: alpha
        )
    }

    // MARK: 2.1 面板与背景（三层材质进深 + SwiftUI Material 组合 · 自适应深浅）
    /// 主面板毛玻璃底层：浅色 rgba(242,242,247,0.88) · 深色 rgba(26,26,29,0.88)
    static let bgPanel = dynamicRGBA(lr: 242, lg: 242, lb: 247, la: 0.88, dr: 26, dg: 26, db: 29, da: 0.88)
    /// 列表内容区与设置分组卡片（清晰分层）：浅色 rgba(255,255,255,0.88) · 深色 rgba(38,38,42,0.84)
    static let bgContent = dynamicRGBA(lr: 255, lg: 255, lb: 255, la: 0.88, dr: 38, dg: 38, db: 42, da: 0.84)
    /// 预览区底色（高保真实底）：浅色 rgba(255,255,255,0.96) · 深色 rgba(22,22,25,0.97)
    static let bgPreview = dynamicRGBA(lr: 255, lg: 255, lb: 255, la: 0.96, dr: 22, dg: 22, db: 25, da: 0.97)
    /// Popover 级材质：浅色 rgba(252,252,254,0.96) · 深色 rgba(42,42,47,0.97)
    static let bgPopover = dynamicRGBA(lr: 252, lg: 252, lb: 254, la: 0.96, dr: 42, dg: 42, db: 47, da: 0.97)
    /// 列表行悬停：浅色 rgba(0,0,0,0.045) · 深色 rgba(255,255,255,0.065)
    static let bgRowHover = dynamicColor(
        light: NSColor(white: 0.0, alpha: 0.045),
        dark: NSColor(white: 1.0, alpha: 0.065)
    )
    /// 列表行选中：浅色系统强调色 15% · 深色系统强调色 24%
    static var bgRowSelected: Color {
        dynamicAccentColor(lightAlpha: 0.15, darkAlpha: 0.24)
    }
    /// 列表行选中胶囊边框：浅色系统强调色 26% · 深色系统强调色 36%
    static var borderRowSelected: Color {
        dynamicAccentColor(lightAlpha: 0.26, darkAlpha: 0.36)
    }
    /// 列表行选中微底（现代柔和微底模式）：浅色系统强调色 11% · 深色系统强调色 18%
    static var bgRowSelectedSubtle: Color {
        dynamicAccentColor(lightAlpha: 0.11, darkAlpha: 0.18)
    }
    /// 列表行选中微底边框：浅色系统强调色 18% · 深色系统强调色 26%
    static var borderRowSelectedSubtle: Color {
        dynamicAccentColor(lightAlpha: 0.18, darkAlpha: 0.26)
    }
    /// 多选批量模式选中行：浅色系统强调色 18% · 深色系统强调色 30%
    static var bgRowSelectedStrong: Color {
        dynamicAccentColor(lightAlpha: 0.18, darkAlpha: 0.30)
    }
    /// 分类 chip 选中底：浅色系统强调色 12% · 深色系统强调色 20%
    static var bgChipSelected: Color {
        dynamicAccentColor(lightAlpha: 0.12, darkAlpha: 0.20)
    }
    /// 强调色微底（设置页统计徽标、录制态等共用）：浅色 10% · 深色 20%
    static var bgAccentSubtle: Color {
        dynamicAccentColor(lightAlpha: 0.10, darkAlpha: 0.20)
    }
    /// 搜索框/工具栏/卡片内嵌底：浅色 rgba(0,0,0,0.065) · 深色 rgba(255,255,255,0.065)
    static let bgInset = dynamicColor(
        light: NSColor(white: 0.0, alpha: 0.065),
        dark: NSColor(white: 1.0, alpha: 0.065)
    )
    /// 搜索框聚焦底：浅色半透明白 0.72 · 深色半透明白 0.12
    static let bgSearchFocused = dynamicColor(
        light: NSColor(white: 1.0, alpha: 0.72),
        dark: NSColor(white: 1.0, alpha: 0.12)
    )
    /// 控件/分段选中滑块底（JSON 预览分段、快捷键录制常态等）
    static let bgControlElevated = dynamicColor(
        light: NSColor(white: 1.0, alpha: 0.94),
        dark: NSColor(white: 1.0, alpha: 0.16)
    )
    /// 键盘键帽 Kbd 底色
    static let bgKbd = dynamicColor(
        light: NSColor(white: 1.0, alpha: 0.75),
        dark: NSColor(white: 1.0, alpha: 0.11)
    )
    /// 搜索框内嵌键帽底色
    static let bgSearchKeycap = dynamicColor(
        light: NSColor(white: 0.0, alpha: 0.048),
        dark: NSColor(white: 1.0, alpha: 0.10)
    )
    /// 时间锚点轨胶囊底色
    static func bgTimeRail(isActive: Bool) -> Color {
        dynamicColor(
            light: NSColor(white: 0.0, alpha: isActive ? 0.08 : 0.045),
            dark: NSColor(white: 1.0, alpha: isActive ? 0.15 : 0.09)
        )
    }
    /// 行内输入控件不透明底板（重命名输入框等）
    static var bgInputControl: Color {
        Color(nsColor: .controlBackgroundColor)
    }
    /// 二维码承载画布（深浅模式下均需高对比浅底保证扫码识别率）
    static let bgQRCodeCanvas = dynamicHex(light: 0xFFFFFF, dark: 0xFAFAFC)
    /// 二维码说明卡片底色
    static let bgCardElevated = dynamicRGBA(lr: 255, lg: 255, lb: 255, la: 0.85, dr: 36, dg: 36, db: 40, da: 0.85)
    /// 代码预览区底：浅色 rgba(236,236,241,0.96) · 深色 rgba(34,34,38,0.95)
    /// NSColor 为事实来源（横向滚动渐隐遮罩用）
    static let nsBgCode = dynamicNSColor(
        light: NSColor(srgbRed: 236 / 255.0, green: 236 / 255.0, blue: 241 / 255.0, alpha: 0.96),
        dark: NSColor(srgbRed: 34 / 255.0, green: 34 / 255.0, blue: 38 / 255.0, alpha: 0.95)
    )
    static let bgCode = Color(nsColor: nsBgCode)
    /// 代码预览整行悬浮高亮（与列表行悬停同强度）
    static let nsCodeLineHover = dynamicNSColor(
        light: NSColor(white: 0.0, alpha: 0.042),
        dark: NSColor(white: 1.0, alpha: 0.055)
    )
    /// 菜单高亮/悬停行圆角块
    static let bgRowOn = dynamicColor(
        light: NSColor(white: 0.0, alpha: 0.055),
        dark: NSColor(white: 1.0, alpha: 0.085)
    )
    /// 控件按下态反馈底色
    static let bgControlPressed = dynamicColor(
        light: NSColor(white: 0.0, alpha: 0.095),
        dark: NSColor(white: 1.0, alpha: 0.14)
    )
    /// 底部操作指引栏：浅色 rgba(242,242,247,0.76) · 深色 rgba(30,30,34,0.84)
    static let bgFooter = dynamicRGBA(lr: 242, lg: 242, lb: 247, la: 0.76, dr: 30, dg: 30, db: 34, da: 0.84)

    // MARK: 2.2 文字层级（对比度符合 WCAG AA）
    /// 主文字：浅色 #1D1D1F · 深色 #F5F5F7
    static let textPrimary = dynamicHex(light: 0x1D1D1F, dark: 0xF5F5F7)
    /// 次要文字：浅色 rgba(60,60,67,0.76) · 深色 rgba(235,235,245,0.72)
    static let textSecondary = dynamicRGBA(lr: 60, lg: 60, lb: 67, la: 0.76, dr: 235, dg: 235, db: 245, da: 0.72)
    /// 辅助/元数据文字：浅色 rgba(60,60,67,0.54) · 深色 rgba(235,235,245,0.48)
    static let textTertiary = dynamicRGBA(lr: 60, lg: 60, lb: 67, la: 0.54, dr: 235, dg: 235, db: 245, da: 0.48)
    /// 禁用态文字：浅色 rgba(60,60,67,0.28) · 深色 rgba(235,235,245,0.26)
    static let textDisabled = dynamicRGBA(lr: 60, lg: 60, lb: 67, la: 0.28, dr: 235, dg: 235, db: 245, da: 0.26)
    static let textOnAccent = Color.white
    /// 列表行选中反白次级文本（纯白 88%）
    static let textOnAccentSecondary = Color.white.opacity(0.88)
    /// 列表行选中反白三级文本（纯白 76%）
    static let textOnAccentTertiary = Color.white.opacity(0.76)
    /// 列表行选中反白胶囊底色（纯白 22%）
    static let bgPillOnAccent = Color.white.opacity(0.22)
    /// 经典系统强调色实色行底下的搜索命中高亮色：
    /// 默认荧光亮黄（#FFE633，在蓝/灰/紫等实底上极高对比度）；
    /// 若系统强调色本身为黄/橙色系，自适应防撞色切换为深炭黑（#1A1A1A）。
    private static let highlightFluorescentYellow = Color(hex: 0xFFE633)
    private static let highlightCharcoalDark = Color(hex: 0x1A1A1A)
    static var searchHighlightOnSolidAccent: Color {
        isWarmAccentColor ? highlightCharcoalDark : highlightFluorescentYellow
    }
    /// 搜索命中关键词黄底（#FFE633，经典明亮黄底）
    static let searchHighlightBackground = Color(hex: 0xFFE633)
    /// 搜索命中关键词文字颜色（#1A1A1A，深炭黑字色）
    static let searchHighlightForeground = Color(hex: 0x1A1A1A)
    /// 判断当前系统强调色是否为黄色或橙色系（防撞色检测）
    static var isWarmAccentColor: Bool {
        if let appleAccent = UserDefaults.standard.object(forKey: "AppleAccentColor") as? Int,
           appleAccent == 1 || appleAccent == 2 {
            return true
        }
        guard let srgb = NSColor.controlAccentColor.usingColorSpace(.sRGB) else { return false }
        return srgb.redComponent > 0.75 && srgb.greenComponent > 0.45 && srgb.blueComponent < 0.35
    }

    // MARK: 2.3 强调与语义色
    /// 系统强调色（跟随 macOS 系统外观设置：蓝/紫/粉/红/橙/黄/绿/石墨）
    static var accent: Color {
        Color(nsColor: .controlAccentColor)
    }
    /// 聚焦外环
    static var focusRing: Color {
        dynamicAccentColor(lightAlpha: 0.35, darkAlpha: 0.45)
    }
    /// 敏感项语义橙
    static let colorSensitive = dynamicHex(light: 0xC75000, dark: 0xFF9F0A)
    /// 敏感行背景微橙
    static let bgSensitiveRow = dynamicRGBA(lr: 255, lg: 149, lb: 0, la: 0.08, dr: 255, dg: 159, db: 10, da: 0.14)
    /// 收藏星标金黄（明亮温润金黄 · 解决浅色下绿褐偏色与低对比度）
    static let colorFavorite = dynamicHex(light: 0xF59E0B, dark: 0xFFD60A)
    static let colorDanger = dynamicHex(light: 0xD70015, dark: 0xFF453A)
    static let colorSuccess = dynamicHex(light: 0x248A3D, dark: 0x30D158)

    // MARK: 2.3b 内容分类与来源 App 专属语义色 Token（浅/深双模和谐饱和度）
    static let tintCategoryText = dynamicHex(light: 0x007AFF, dark: 0x0A84FF)
    static let tintCategoryImage = dynamicHex(light: 0xAF52DE, dark: 0xBF5AF2)
    static let tintCategoryFile = dynamicHex(light: 0xD97706, dark: 0xFF9F0A)
    static let tintCategoryURL = dynamicHex(light: 0x059669, dark: 0x30D158)
    static let tintCategoryCode = dynamicHex(light: 0x5856D6, dark: 0x5E5CE6)
    static let tintCategoryJSON = dynamicHex(light: 0x0284C7, dark: 0x40C8E0)
    static let tintCategoryColor = dynamicHex(light: 0xDB2777, dark: 0xFF6482)

    /// 来源 App 兜底色板 Token
    static let appColorSafariBg = dynamicHex(light: 0xF5F5F7, dark: 0x2C2C2E)
    static let appColorSafariFg = dynamicHex(light: 0x007AFF, dark: 0x0A84FF)
    static let appColorXcode = dynamicHex(light: 0x3B82F6, dark: 0x4A90E2)
    static let appColorWeChat = dynamicHex(light: 0x07C160, dark: 0x10B981)
    static let appColorFigma = dynamicHex(light: 0x8B5CF6, dark: 0xA259FF)
    static let appColorFinder = dynamicHex(light: 0x1B7BE8, dark: 0x3B82F6)
    static let appColorTerminal = dynamicHex(light: 0x1D1D1F, dark: 0x3A3A3C)
    static let appColorNotes = dynamicHex(light: 0xEAB308, dark: 0xFACC15)
    static let appColorNeutral = dynamicHex(light: 0x8E8E93, dark: 0x636366)
    /// 收藏激活态文字色（浅色模式下高对比度温润暖色，解决纯黄文字在浅底看不清）
    static let textFavoriteActive = dynamicHex(light: 0x92400E, dark: 0xFFD60A)
    /// 收藏激活背景底色
    static let bgFavoriteActive = dynamicColor(
        light: nsColorHex(0xF59E0B, alpha: 0.12),
        dark: nsColorHex(0xFFD60A, alpha: 0.18)
    )
    static let bgFavoriteActiveHover = dynamicColor(
        light: nsColorHex(0xF59E0B, alpha: 0.18),
        dark: nsColorHex(0xFFD60A, alpha: 0.26)
    )
    /// 收藏激活边框
    static let borderFavoriteActive = dynamicColor(
        light: nsColorHex(0xF59E0B, alpha: 0.28),
        dark: nsColorHex(0xFFD60A, alpha: 0.34)
    )
    static let borderFavoriteActiveHover = dynamicColor(
        light: nsColorHex(0xF59E0B, alpha: 0.40),
        dark: nsColorHex(0xFFD60A, alpha: 0.46)
    )
    /// 危险操作微底与悬停底色
    static let bgDangerSubtle = dynamicColor(
        light: nsColorHex(0xD70015, alpha: 0.08),
        dark: nsColorHex(0xFF453A, alpha: 0.14)
    )
    static let bgDangerHover = dynamicColor(
        light: nsColorHex(0xD70015, alpha: 0.11),
        dark: nsColorHex(0xFF453A, alpha: 0.18)
    )
    /// 危险操作悬停边框
    static let borderDangerHover = dynamicColor(
        light: nsColorHex(0xD70015, alpha: 0.24),
        dark: nsColorHex(0xFF453A, alpha: 0.32)
    )
    // MARK: 2.4 分隔线与描边
    static let separator = dynamicRGBA(lr: 60, lg: 60, lb: 67, la: 0.12, dr: 255, dg: 255, db: 255, da: 0.12)
    /// 面板发丝边
    static let hairline = dynamicColor(
        light: NSColor(white: 0.0, alpha: 0.16),
        dark: NSColor(white: 1.0, alpha: 0.15)
    )
    /// 细节描边（图标/色点/缩略图内描边）
    static let borderHairline = dynamicColor(
        light: NSColor(white: 0.0, alpha: 0.09),
        dark: NSColor(white: 1.0, alpha: 0.12)
    )
    /// 多选框未勾选描边
    static let borderCheckboxIdle = dynamicRGBA(lr: 60, lg: 60, lb: 67, la: 0.42, dr: 235, dg: 235, db: 245, da: 0.42)
    /// kbd 键帽描边
    static let borderKbd = dynamicColor(
        light: NSColor(white: 0.0, alpha: 0.12),
        dark: NSColor(white: 1.0, alpha: 0.16)
    )
    /// 右下角缩放手柄渐变色
    static let colorResizeGrip = dynamicRGBA(lr: 60, lg: 60, lb: 67, la: 0.28, dr: 235, dg: 235, db: 245, da: 0.28)

    // MARK: 2.5 代码语法高亮（Xcode Default 对齐）
    // NSColor 为事实来源（AppKit 代码文本视图着色），SwiftUI Color 由其派生
    static let nsCodeText = dynamicNSColor(light: 0x1D1D1F, dark: 0xF5F5F7)
    static let nsCodeKeyword = dynamicNSColor(light: 0xAD3DA4, dark: 0xFF7AB2)
    static let nsCodeString = dynamicNSColor(light: 0xC41A16, dark: 0xFF6A5E)
    static let nsCodeNumber = dynamicNSColor(light: 0x1C00CF, dark: 0xD0BFFF)
    static let nsCodeComment = dynamicNSColor(
        light: NSColor(srgbRed: 0x70 / 255.0, green: 0x7F / 255.0, blue: 0x8C / 255.0, alpha: 1.0),
        dark: NSColor(srgbRed: 235 / 255.0, green: 235 / 255.0, blue: 245 / 255.0, alpha: 0.50)
    )
    static let nsCodeLineNumber = dynamicNSColor(
        light: NSColor(srgbRed: 60 / 255.0, green: 60 / 255.0, blue: 67 / 255.0, alpha: 0.35),
        dark: NSColor(srgbRed: 235 / 255.0, green: 235 / 255.0, blue: 245 / 255.0, alpha: 0.38)
    )
    static let codeText = Color(nsColor: nsCodeText)
    static let codeKeyword = Color(nsColor: nsCodeKeyword)
    static let codeString = Color(nsColor: nsCodeString)
    static let codeNumber = Color(nsColor: nsCodeNumber)
    static let codeComment = Color(nsColor: nsCodeComment)
    static let codeLineNumber = Color(nsColor: nsCodeLineNumber)

    // MARK: 4.1 间距标尺（4pt 基准网格）
    static let spaceXXS: CGFloat = 4
    static let spaceXS: CGFloat = 8
    static let spaceS: CGFloat = 12
    static let spaceM: CGFloat = 16
    static let spaceL: CGFloat = 24

    // MARK: 4.2 圆角阶梯（4pt 阶梯）
    static let radiusThumb: CGFloat = 4
    static let radiusControl: CGFloat = 6
    static let radiusCard: CGFloat = 8
    static let radiusPanel: CGFloat = 10

    // MARK: 4.2b 动效规范（克制、迅捷的原生反馈）
    static let animHover = Animation.easeInOut(duration: 0.12)
    static let animSelection = Animation.spring(response: 0.22, dampingFraction: 0.84)
    static let animSpring = Animation.spring(response: 0.26, dampingFraction: 0.80)
    // MARK: 4.3 关键尺寸
    static let heightRowList: CGFloat = 50
    static let heightSearch: CGFloat = 42
    static let heightToolbar: CGFloat = 42
    static let heightFooter: CGFloat = 22
    static let widthListCol: CGFloat = 310
    static let indicatorWidth: CGFloat = 3

    // MARK: 4.4 列表列纵向布局（搜索框 → 分类筛选条 → 列表 → 底栏）
    /// 搜索框顶部让位（无边框顶顶贴边，0pt）
    static let searchTopInset: CGFloat = 0
    /// 搜索内容左侧安全缩进（与分类/列表统一 14pt 左对齐基准线）
    static let searchContentLeadingPadding: CGFloat = 14
    /// 搜索框与分类筛选条间的间距
    static let searchBottomGap: CGFloat = 6
    /// 分类筛选条高（内部 chip 垂直居中）
    static let heightCategoryBar: CGFloat = 24
    /// 分类筛选条与列表间的间距
    static let categoryBarBottomGap: CGFloat = 6
    /// 列表滚动视口顶在列表列坐标系内的 Y（吸顶判定基准；
    /// ScrollView 自身 background 的偏好对其外层不可见，无法运行时测量，只能常量推导）
    static let listViewportTopY: CGFloat = searchTopInset + heightSearch + searchBottomGap + heightCategoryBar + categoryBarBottomGap
    /// 列表组头高（非紧凑态；紧凑态 20 见 GroupHeaderView）
    static let heightGroupHeader: CGFloat = 24
    /// 列表内容有效可视区顶 Y（吸顶组头 24pt 不算作列表内容可视区，行顶安全边界 = listViewportTopY + heightGroupHeader）
    static let listContentTopY: CGFloat = listViewportTopY + heightGroupHeader
    /// 列表底部悬浮横幅（删除撤销 UndoToast / 辅助功能引导横幅）占用高度（32pt 卡片 + 8pt 底距）
    static let heightListBottomBanner: CGFloat = 40

    // MARK: 4.4b 面板交互热区（T039 · D8 热区同源 / 契约 R11）
    // 锚点：DraggablePanel.isInteractiveArea / isSearchBarArea 与
    // QuickPopoverController.collapsedTargetWidth 引用本组常量做命中判定；
    // 改动任一侧必须同步另一侧（面板创建时有 debug 断言兜底：
    // DraggablePanel.debugAssertHotZoneCoverage）

    /// 顶部控件热区高（右上角预览切换按钮一带）
    static let hotZoneTopControlHeight: CGFloat = 36
    /// 顶部控件热区宽（按钮向左延伸的命中带）
    static let hotZoneTopControlWidth: CGFloat = 40
    /// 搜索栏热区上缘内缩（= searchTopInset + heightSearch + 4：搜索框带 + 余量）
    static let hotZoneSearchBarTopInset: CGFloat = searchTopInset + heightSearch + 4
    /// 搜索栏热区下缘内缩（须 ≤ searchTopInset，罩住搜索框带下沿）
    static let hotZoneSearchBarBottomInset: CGFloat = 0
    /// 搜索栏热区左缘（顶格贴左）
    static let hotZoneSearchBarLeading: CGFloat = 0
    /// 预览工具栏热区高（= heightToolbar + 8：复制/收藏/删除按钮带 + 余量）
    static let hotZonePreviewToolbarHeight: CGFloat = heightToolbar + 8
    /// 时间轨热区宽（列表列右缘命中带）
    static let hotZoneTimeRailWidth: CGFloat = 28

    // MARK: 4.5 时间锚点条（列表右缘 · 极简刻度点轨）
    /// 锚点条常态宽（极致纤细 8pt，静止不遮挡行尾时间文字）
    static let widthTimeRail: CGFloat = 8
    /// 锚点条交互感应热区宽（24pt）
    static let hitWidthTimeRail: CGFloat = 24
    /// 列表行尾文字避让安全边距（16pt）
    static let rowTrailingMargin: CGFloat = 16
    /// 锚点条悬停加宽（12pt，向左展开，右侧紧贴安全边距）
    static let widthTimeRailExpanded: CGFloat = 12
    /// 刻度点间距上限（组少时舒适间距）
    static let heightTimeRailRow: CGFloat = 22
    /// 刻度点间距下限（组多时压缩保可点性）
    static let heightTimeRailRowMin: CGFloat = 10
    /// 静止淡显不透明度（悬停/拖动时 1.0，0.15s 平滑过渡）
    static let timeRailIdleOpacity: CGFloat = 0.75

    // MARK: 6.6 胶囊色（文本灰 / 代码蓝 / 图片紫）
}

// MARK: - 便捷初始化

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

extension Font {
    /// NookClip 无衬线（SF Pro Text / PingFang SC）
    static func nookClip(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    /// NookClip 等宽（SF Mono）
    static func nookClipMono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    /// NookClip 圆角数字/键帽字体（SF Pro Rounded）
    static func nookClipRounded(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    // MARK: 语义化字阶 Token (Design System 2.0 §4)
    /// 详情区大标题 (18pt Semibold · 方案 B 海报级层级)
    static let nookClipTitle = Font.nookClip(18, .semibold)
    /// 详情区等宽大标题 (18pt Semibold Mono)
    static let nookClipTitleMono = Font.nookClipMono(18, .semibold)
    /// 分组标题 / 卡片小标题 (13pt Semibold)
    static let nookClipSectionTitle = Font.nookClip(13, .semibold)
    /// 列表行主标题 / 正文 / 按钮文案 (13pt Regular)
    static let nookClipBody = Font.nookClip(13, .regular)
    /// 列表行强调主标题 / 按钮强调文案 (13pt Medium)
    static let nookClipBodyMedium = Font.nookClip(13, .medium)
    /// 次级说明 / 辅助按钮文案 (12pt Regular)
    static let nookClipSubhead = Font.nookClip(12, .regular)
    /// 次级强调文案 (12pt Medium)
    static let nookClipSubheadMedium = Font.nookClip(12, .medium)
    /// 代码与路径正文 (12pt Mono)
    static let nookClipCode = Font.nookClipMono(12, .regular)
    /// 元数据 / 副行来源 / 时间戳 / 底栏提示 (11pt Regular)
    static let nookClipMeta = Font.nookClip(11, .regular)
    /// 元数据强调 / 吸顶时间组头 (11pt Medium)
    static let nookClipMetaMedium = Font.nookClip(11, .medium)
    /// 胶囊徽标 / 计数 / 辅助微说明 (10pt Medium)
    static let nookClipBadge = Font.nookClip(10, .medium)
    /// 辅助微说明 (10pt Regular)
    static let nookClipCaption = Font.nookClip(10, .regular)
    /// 键帽符号 (10pt Medium Mono)
    static let nookClipKeycap = Font.nookClipMono(10, .medium)
}
// MARK: - 毛玻璃面板材质（半透明底色 + Material 组合，DESIGN.md §5.1/§10.1）

extension View {
    /// 毛玻璃表面：Material / NSVisualEffectView 打底 + 令牌半透明色叠加 + 发丝边 + 多级阴影
    func nookClipSurface(
        tint: Color,
        radius: CGFloat = NookClip.radiusPanel,
        hairline: Color = NookClip.hairline,
        popover: Bool = false,
        enableTranslucency: Bool = true,
        material: NSVisualEffectView.Material = .popover
    ) -> some View {
        self
            .background {
                if enableTranslucency {
                    VisualEffectBackground(
                        material: material,
                        blendingMode: .behindWindow,
                        state: .active,
                        cornerRadius: radius
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: radius).fill(tint)
                    }
                } else {
                    RoundedRectangle(cornerRadius: radius)
                        .fill(tint)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(hairline, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(popover ? 0.22 : 0.16), radius: popover ? 25 : 17, x: 0, y: popover ? 18 : 12)
            .shadow(color: .black.opacity(popover ? 0.12 : 0.10), radius: popover ? 7 : 5, x: 0, y: popover ? 4 : 3)
    }
}
