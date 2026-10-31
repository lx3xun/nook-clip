import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

// MARK: - 屏幕置顶贴条（specs/012-scrub-stack-pin · US3 · T011）
//
// 这一屏的东西不是「又一个窗口」，而是用户在工作流中途钉在屏幕上的**凭证纸**：
// 一边看着贴条上的取件码/接口地址/翻译文案，一边在别的应用里输入。所以三条铁律：
//   · 静止时像一张干净的纸——所有按钮默认隐身，鼠标进来才淡入，不抢视觉；
//   · 永远浮在最上层且跟手——跨 Space、压全屏应用、不随切应用消失；
//   · 必须能退出穿透——点击穿透后窗口收不到任何鼠标事件，因此留了三重出口：
//     Carbon 热键 ⌥⌘P（不需要辅助功能权限）、贴在卡片右上角的锁片（纯鼠标）、
//     菜单栏「全部取消点击穿透」。穿透前还有 1.5s 缓冲期（提示语同屏可见，期间点一下即可反悔）。
//
// 与 `PasteStackPillPanel` 同一套搭建方式（NSPanel + NSHostingView），差异在于：
// 贴条是常驻的、可拖拽/缩放/折叠的，还要承载编辑态。
//
// 全局只留一张：屏幕上的贴条是「当前手头这件事」的凭证，多张并存会让用户分不清
// 该看哪一张，也让桌角越堆越乱。再钉一条就顶掉旧的（位置与浓度沿用），
// 而不是拒绝——拒绝会让用户先手动关掉旧的，还看不出刚才为什么没反应。

// MARK: - 外观跟随

/// 把「设置里选的外观档位」翻译成 AppKit 窗口的 `appearance`。
///
/// 主面板是 SwiftUI 视图，`.preferredColorScheme` 一句话就能跟着设置走；贴条却是
/// 独立 `NSPanel`，不在这棵视图树里，`preferredColorScheme` 管不到它——结果就是
/// 用户把 App 切成深色，主面板变了、贴条还停在系统配色上。所以贴条窗口必须自己
/// 按同一个档位设 `appearance`（设置项和主面板共用 `UserDefaults` 的 "appearance"）。
enum PinnedAppearance {
    /// 与 `MainView` / `SettingsView` 的 `@AppStorage("appearance")` 同一个 key
    static let storageKey = "appearance"
    static let defaultValue = "system"

    /// 当前配置的外观档位（light / dark / system）
    static var currentMode: String {
        UserDefaults.standard.string(forKey: storageKey) ?? defaultValue
    }

    /// 档位 → NSAppearance。system 返回 nil，表示交还给系统（跟随显示器/系统外观自动切换）。
    static func appearance(for mode: String) -> NSAppearance? {
        switch mode {
        case "light": return NSAppearance(named: .aqua)
        case "dark": return NSAppearance(named: .darkAqua)
        default: return nil
        }
    }

    /// 把当前配置应用到某个窗口
    static func apply(to window: NSWindow) {
        window.appearance = appearance(for: currentMode)
    }
}

// MARK: - 数据模型

/// 一张贴条的内存态。字段按 data-model.md §3.1 实现，但观察机制用项目主流的
/// `@Observable`（不是 `ObservableObject`）——`InMemoryHistoryStore` /
/// `PasteStackController` / `LocalizationManager` 全是这一套，混用两套会让
/// SwiftUI 侧出现「有的改动能刷新有的不能」的玄学问题。
@MainActor
@Observable
final class PinnedNoteModel: Identifiable {
    let id: UUID
    /// 来源剪贴板条目 id（保存回历史时用于定位原始记录）
    let sourceItemId: String
    let itemType: ClipboardItemType
    let sourceAppName: String?
    let createdAt: Date
    /// 文本/代码贴条的可编辑正文（Scratchpad 草稿）：编辑即写，⌘⏎/失焦只是退出编辑态
    var editableText: String
    /// 原始文本（用于判断用户是否改过内容，暂不落库）
    let originalText: String
    /// 图片贴条的原始数据（`FileStore.load` 读出，未解码位图不缓存）
    let imageData: Data?
    /// 已解码的图片（避免 SwiftUI 每帧重复解码；图片贴条专用）
    let image: NSImage?
    /// 离线识别出的 OCR 文本（图片贴条可一键复制）
    let ocrText: String?
    /// 是否按代码排版（`persistedKind == "code"`：等宽字体 + 代码底色）
    let isCode: Bool
    /// 代码语言 id（`item.metadata.language`，如 swift/json）。nil = 交给 highlight.js 自动检测。
    /// 有了它，代码贴条才能和主面板渲染出同一套语法高亮，而不是只有等宽字体。
    let language: String?
    /// 来源条目是否为敏感凭证（用于贴条内点击复制时触发防窥标记与 30 秒自动擦除）
    let isSensitive: Bool
    /// 敏感条目明文解密失败、已降级为脱敏摘要展示的标记（用于 UI 弱提示）
    let isDegraded: Bool
    /// 窗口不透明度（0.20 ~ 1.00，默认 0.96）
    var opacity: Double = PinnedWindowManager.defaultOpacity
    /// 是否折叠为单行标题条
    var isCollapsed: Bool
    /// 是否开启点击穿透（对照描摹模式）
    var isClickThrough: Bool
    /// 是否处于文本编辑态
    var isEditing: Bool
    /// 最近一次「保存回历史」成功的时刻（卡片据此闪一条确认提示再淡出）
    var savedAt: Date?

    init(
        id: UUID = UUID(),
        sourceItemId: String,
        itemType: ClipboardItemType,
        sourceAppName: String?,
        createdAt: Date = .now,
        editableText: String,
        originalText: String,
        imageData: Data?,
        ocrText: String?,
        isCode: Bool,
        language: String? = nil,
        isSensitive: Bool = false,
        isDegraded: Bool
    ) {
        self.id = id
        self.sourceItemId = sourceItemId
        self.itemType = itemType
        self.sourceAppName = sourceAppName
        self.createdAt = createdAt
        self.editableText = editableText
        self.originalText = originalText
        self.imageData = imageData
        self.image = imageData.flatMap { NSImage(data: $0) }
        self.ocrText = ocrText
        self.isCode = isCode
        self.language = language
        self.isSensitive = isSensitive
        self.isDegraded = isDegraded
        self.isCollapsed = false
        self.isClickThrough = false
        self.isEditing = false
    }

    /// 折叠态单行摘要：取正文首行（空白行跳过），无正文时用图片/文件的兜底文案
    var summaryLine: String {
        let firstLine = editableText
            .split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        if let firstLine, !firstLine.isEmpty {
            return firstLine
        }
        return itemType == .image ? L10n.tr("item.type_image") : L10n.tr("pin.empty_text")
    }
}

// MARK: - 贴条面板

/// 无标题栏的置顶贴条窗。
///
/// 键盘分发与右下角缩放都在窗口层拦（同 `DraggablePanel` 的思路）：贴条内容
/// 常驻 `TextEditor`，若靠 SwiftUI 的按键回调，编辑态下 Esc/⌘W 会被文本视图
/// 先吃掉，用户会觉得「按了没反应」。
@MainActor
final class PinnedNotePanel: NSPanel {
    /// 卡片四周留给投影的透明边。
    ///
    /// 窗口是透明无边框的，`.shadow` 画在卡片外、却被窗口矩形硬裁——
    /// 于是四角留下笔直的黑色直角线（白底上最刺眼）。给阴影留出这圈空间后，
    /// 四角变成正常的渐隐弧线。所有尺寸常量都是「窗口尺寸」（含这圈边）。
    /// 取 16：投影 `radius 12` + 向下偏移 4，最远处正好探到 16pt 外，再多就浪费窗口面积。
    static let shadowInset: CGFloat = 16
    /// 投影的浓度 / 模糊半径 / 向下偏移。
    ///
    /// 原来 0.18 / 12 / 4 偏重：贴条是一张浮在桌面的纸，不是弹窗，阴影应该只在
    /// 边缘轻轻压一道，让纸「离桌面近一点」；压太重会像卡片被嵌在玻璃里，
    /// 白底上尤其明显（实测卡片下方最深亮度只有 226，白是 255）。
    /// 三者一起收才有用：只降浓度会变成「脏灰边」，只收模糊会变成硬边。
    static let shadowOpacity: Double = 0.10
    static let shadowBlurRadius: CGFloat = 8
    static let shadowOffsetY: CGFloat = 2.5
    /// 贴条尺寸下限（窗口尺寸）。宽度 200 → 232：头栏要同时放下来源应用名、类型徽标、
    /// 百分比与 4 个窗口控件，200pt 时来源名会被挤没，用户看不出这张纸从哪来。
    /// 加上 2×`shadowInset` 的投影边后，卡片本身仍是 232 宽。
    static let minSize = NSSize(width: 232 + shadowInset * 2, height: 120 + shadowInset * 2)
    /// 折叠态尺寸（只留一行头栏；同样是窗口尺寸）
    static let collapsedSize = NSSize(width: 240 + shadowInset * 2, height: 28 + shadowInset * 2)
    /// 缩放手柄热区边长。18 → 22：贴条常停在屏幕角落，18pt 的角很难精准压住
    static let resizeGripSize: CGFloat = 22
    /// 缩放抓取角。右下角是主入口；贴条贴在屏幕右侧或被别的窗口挡住右下角时，
    /// 用户会本能地去按左下角——只认一个角等于「这个角偶尔拖不动」。
    enum ResizeCorner {
        case bottomRight
        case bottomLeft
    }
    /// 图片贴条最大边长
    static let imageMaxSide: CGFloat = 480

    let note: PinnedNoteModel
    /// Esc / ⌘W / 关闭按钮
    var onClose: (() -> Void)?
    /// ⌘⏎：退出编辑态（正文本身是实时写入的，这里只做状态收尾）
    var onCommitEditing: (() -> Void)?
    /// 展开态尺寸（折叠后按它还原；用户手动缩放会更新它）
    var expandedSize: NSSize

    override var canBecomeKey: Bool { true }
    /// 贴条永不参与主窗口循环（否则菜单栏应用会把贴条当「主窗口」激活）
    override var canBecomeMain: Bool { false }

    /// 卡片本身占的矩形（窗口去掉四周那圈透明投影留白）。
    /// 视觉元素（描边、提示语、锁片）都该按它对齐，而不是窗口边界。
    var cardFrame: NSRect { frame.insetBy(dx: Self.shadowInset, dy: Self.shadowInset) }

    /// 只有编辑正文时才需要键盘焦点。
    ///
    /// 贴条的主场景是「一边看纸、一边在别的应用里打字」。若每次点一下贴条都把
    /// 键盘焦点抢过来，用户在文档里打的那半句话就断了——这是最让人恼火的一类打断。
    /// `becomesKeyOnlyIfNeeded` 正好表达这个语义：普通点击不夺焦，进了编辑态才夺。
    override var becomesKeyOnlyIfNeeded: Bool {
        get { !note.isEditing }
        set { super.becomesKeyOnlyIfNeeded = newValue }
    }

    init(note: PinnedNoteModel, contentSize: NSSize) {
        self.note = note
        self.expandedSize = contentSize
        super.init(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configure()
    }

    // MARK: 窗口行为

    private func configure() {
        isOpaque = false
        backgroundColor = .clear
        // 窗口阴影必须关掉。卡片填充是半透明的（`NookClip.bgPanel` alpha 0.88），系统阴影
        // 画在卡片下面会从半透明里透上来，在卡片内侧形成一圈 10pt 宽的暗边；浅色模式下那圈
        // 暗边叠上描边，看起来就是加了一圈厚边框（实测内侧亮度被压到 168，纯色是 242）。
        // 浮起感改由卡片自己画的 `ShadowRing` 提供——它只画外环，不会透进卡片内部。
        hasShadow = false
        isFloatingPanel = true
        // canJoinAllSpaces：切桌面贴条跟着走；fullScreenAuxiliary：全屏应用上也浮得住；
        // stationary：Mission Control 里贴条不跟着窗口流走，保持"贴在屏幕上"的语义
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        // 关闭系统窗口动画：显隐由业务自己控制，两套动画叠加会闪一下
        animationBehavior = .none
        minSize = Self.minSize
        // 独立窗口不在主面板那棵 SwiftUI 树里，`preferredColorScheme` 管不到它，
        // 必须自己按设置档位设 appearance，否则切成深色后贴条还是系统色。
        PinnedAppearance.apply(to: self)
    }

    /// Esc 的兜底通道（`sendEvent` 没拦到时 AppKit 走响应链到这里）。
    /// 必须和 `handleKeyDown` 保持同一套语义，否则编辑态按 Esc 仍会连纸一起销毁。
    override func cancelOperation(_ sender: Any?) {
        if note.isEditing {
            onCommitEditing?()
        } else {
            onClose?()
        }
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            if handleKeyDown(event) { return }
        case .leftMouseDown:
            // 点一下就提到最前：贴条可能被别的窗口压住，点它时得先露出来
            if !isKeyWindow { orderFrontRegardless() }
            // 下沿两个角都能拉伸：只在手柄热区内接管，其余点击照常交给 SwiftUI
            if let corner = resizeCorner(at: event.locationInWindow) {
                handleResize(startEvent: event, corner: corner)
                return
            }
        default:
            break
        }
        super.sendEvent(event)
    }

    /// 贴条级按键：Esc / ⌘W 关闭，⌘⏎ 退出编辑态。
    /// 带其它修饰符的组合一律放行——那是系统或用户自己的快捷键。
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        // 输入法组字态（中文拼音候选等）不拦：否则打不出字
        if let client = firstResponder as? (any NSTextInputClient), client.hasMarkedText() {
            return false
        }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let keyCode = Int(event.keyCode)

        if keyCode == kVK_Escape, modifiers.isEmpty {
            // 编辑态下 Esc 只退出编辑，绝不销毁贴条：用户按 Esc 的本意几乎总是
            // 「我不想改了」，若连同整张纸一起关掉，刚敲的草稿就没了。
            if note.isEditing {
                onCommitEditing?()
            } else {
                onClose?()
            }
            return true
        }
        if modifiers == .command, keyCode == kVK_ANSI_W {
            onClose?()
            return true
        }
        if modifiers == .command, keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter {
            onCommitEditing?()
            return true
        }
        return false
    }

    /// 命中判定：这个点落在下沿哪个角的缩放手柄里？
    ///
    /// 抽成纯函数是为了两件事能对齐：热区判定（这里）与视觉提示
    /// （`resizeGripIndicator`）用同一份尺寸；边界情况能直接写单测。
    ///
    /// 注意坐标系是**窗口**的，而卡片四周还有一圈投影留白（`shadowInset`）。
    /// 热区从卡片角往外一直延伸到窗口边，既盖住用户看得见的那个角，
    /// 也把外圈看不见的留白一并算进去——贴条停在屏幕角落时，贴边那一侧更好抓。
    func resizeCorner(at point: NSPoint) -> ResizeCorner? {
        guard !note.isCollapsed else { return nil }
        let reach = Self.resizeGripSize + Self.shadowInset
        guard point.y <= reach else { return nil }
        if point.x >= frame.width - reach { return .bottomRight }
        if point.x <= reach { return .bottomLeft }
        return nil
    }

    /// 下沿拖拽缩放：顶边锚定（贴条贴在屏幕上方，用户下拉底线时上沿不该跟着动）。
    /// 左下角抓取时，右边界也要锚定，否则「拉左边」会顺手把整张纸右移。
    ///
    /// 几何计算抽到 `resizedFrame(...)` 里，是因为「往哪边拖该变宽」这种符号问题
    /// 光看代码很容易写反（第一版就写反了），抽出来才能直接单测钉住。
    private func handleResize(startEvent: NSEvent, corner: ResizeCorner) {
        let startFrame = frame
        let startMouse = NSEvent.mouseLocation
        let screenMax = (screen ?? NSScreen.main)?.visibleFrame.size
            ?? NSSize(width: 4096, height: 4096)
        let maxSize = NSSize(
            width: max(Self.minSize.width, screenMax.width),
            height: max(Self.minSize.height, screenMax.height)
        )

        while true {
            guard let next = nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) else { break }
            if next.type == .leftMouseUp { break }

            let current = NSEvent.mouseLocation
            let delta = NSSize(
                width: current.x - startMouse.x,
                // 鼠标上移（deltaY > 0）= 把下沿往上收 = 高度变小
                height: current.y - startMouse.y
            )
            setFrame(
                Self.resizedFrame(
                    from: startFrame,
                    mouseDelta: delta,
                    corner: corner,
                    minSize: Self.minSize,
                    maxSize: maxSize
                ),
                display: true
            )
        }

        // 记住用户手改后的尺寸，折叠再展开时按这个还原
        expandedSize = NSSize(width: frame.width, height: frame.height)
    }

    /// 拖下沿缩放的几何：纯函数，方便单测覆盖左右两个方向。
    static func resizedFrame(
        from startFrame: NSRect,
        mouseDelta delta: NSSize,
        corner: ResizeCorner,
        minSize: NSSize,
        maxSize: NSSize
    ) -> NSRect {
        // 右下角往右拖（delta.width > 0）变宽；左下角往左拖（delta.width < 0）才是变宽，
        // 所以两边的宽度增量符号相反。写反了会出现「往左拖反而变窄」。
        let widthDelta = corner == .bottomLeft ? -delta.width : delta.width
        let width = min(max(startFrame.width + widthDelta, minSize.width), maxSize.width)
        let height = min(max(startFrame.height - delta.height, minSize.height), maxSize.height)

        var frame = startFrame
        frame.size = NSSize(width: width, height: height)
        // 顶边不动
        frame.origin.y = startFrame.maxY - height
        // 左边抓住：右边界钉住，宽度变化体现为左边移动
        if corner == .bottomLeft {
            frame.origin.x = startFrame.maxX - width
        }
        return frame
    }
}

// MARK: - 锁片（穿透后的解锁入口）

/// 贴条被点了穿透之后，只剩这个可点的小锁片能把它救回来。
///
/// 为什么必须单独开一个窗口：穿透 = `ignoresMouseEvents = true`，原窗口连
/// `mouseDown` 都收不到，画在它里面的任何按钮都是死像素。用户报的「锁上之后
/// 无法解锁」正是这么来的——原来的唯一出口 ⌥⌘P 既藏在快捷键里，又走
/// `NSEvent.addGlobalMonitorForEvents`（要辅助功能权限，没授权就静默失效）。
/// 现在两重保险：进程内 Carbon 热键 ⌥⌘P（无需任何权限）+ 这个看得见、点得到的锁片。
@MainActor
final class LockedNoteChipPanel: NSPanel {
    /// 尺寸与内缩这几个常量必须 `nonisolated`：`origin(...)` 的默认参数是
    /// 在**非隔离上下文**里求值的，读主线程隔离的静态属性会报
    /// 「main actor-isolated static property can not be referenced from a
    /// nonisolated context」，在 Swift 6 语言模式下这是错误而不是警告。
    /// 它们都是不可变的 NSSize / CGFloat，跨线程读没有安全问题。

    /// 基准尺寸：锁图标 + 中文「取消穿透」。中文字宽固定，据此定底线；
    /// 英文文案更长，实际宽度按内容量出来（见 `chipSize`），不做截断。
    nonisolated static let size = NSSize(width: 74, height: 20)
    /// 宽度上限：再宽就会盖住贴条正文，宁可换行也不霸屏
    nonisolated static let maxWidth: CGFloat = 168
    /// 离贴条右上角的内缩：贴在角上，用户才不会以为它是另一个应用
    nonisolated static let inset: CGFloat = 6

    /// 实际尺寸（按当前语言的文案量出来）；`attach` 定位用它
    private(set) var chipSize = LockedNoteChipPanel.size

    /// 点一下锁片：解除这一张的穿透
    var onClick: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configure()
    }

    /// 锁片只接受鼠标、永不成为键盘焦点窗口——
    /// 解锁是「点一下」的动作，绝不能顺手把用户正在打字的应用焦点抢走。
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private func configure() {
        isOpaque = false
        backgroundColor = .clear
        // 和贴条同一个理由：系统窗口阴影会从半透明填充里透成内侧暗边，
        // 浮起感交给 `ShadowRing` 自己画。
        hasShadow = false
        isFloatingPanel = true
        // 比贴条再高一层：贴条本身就在 .floating，同层会被后建的窗口盖住
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none

        // 英文「Stop click-through」比中文长，写死 74pt 会被截成「Stop clic…」。
        // 让宿主视图自己量一次再定窗口宽度，只是别超过上限。
        let host = NSHostingView(rootView: LockedChipLabel().nookClipLocalized())
        let fitting = host.fittingSize
        chipSize = NSSize(
            width: min(Self.maxWidth, max(Self.size.width, fitting.width.rounded(.up))),
            height: Self.size.height
        )
        host.frame = NSRect(origin: .zero, size: chipSize)
        contentView = host
        // 锁片也是独立窗口：不跟着设置档位设 appearance，深色模式下会冒出一块浅色小胶囊。
        PinnedAppearance.apply(to: self)
    }

    /// 整窗接管左键：不依赖 SwiftUI 的命中测试。
    /// `.nonactivatingPanel` 保证本 App 在后台时点击也照常投递到这里，
    /// 不会只是「把应用激活一下」——锁片是救命入口，不能有点不动的可能。
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            onClick?()
            return
        }
        super.sendEvent(event)
    }

    /// 贴在贴条右上角内侧。贴条一旦被锁住就不会再移动（它收不到拖动事件），
    /// 所以位置只在显示时算一次。
    func attach(to noteFrame: NSRect) {
        let visible = (NSScreen.screens.first { $0.frame.intersects(noteFrame) } ?? NSScreen.main)?
            .visibleFrame ?? noteFrame
        setFrame(
            NSRect(origin: Self.origin(forNoteFrame: noteFrame, in: visible, size: chipSize), size: chipSize),
            display: true
        )
    }

    /// 锁片原点（AppKit 坐标）。抽成纯函数是为了能直接对边界情况写单测：
    /// 贴条常停在屏幕边缘，锁片必须自己滑回可视区，否则「点得到的入口」又没了。
    static func origin(
        forNoteFrame noteFrame: NSRect,
        in visible: NSRect,
        size chipSize: NSSize = LockedNoteChipPanel.size
    ) -> NSPoint {
        var x = noteFrame.maxX - chipSize.width - inset
        var y = noteFrame.maxY - chipSize.height - inset
        x = min(max(x, visible.minX + 4), visible.maxX - chipSize.width - 4)
        y = min(max(y, visible.minY + 4), visible.maxY - chipSize.height - 4)
        return NSPoint(x: x, y: y)
    }
}

/// 锁片外观：一枚锁 + 「取消穿透」。静止低调，悬停才提亮——
/// 它只在贴条被锁住时出现，所以不需要像常规按钮那样长期隐身。
private struct LockedChipLabel: View {
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: NookClipIcon.Sensitive.lock)
                .font(.system(size: NookClipIconSize.microSmall, weight: .semibold))
            Text(L10n.tr("pin.unlock"))
                .font(.nookClipCaption)
                .lineLimit(1)
        }
        .foregroundStyle(isHovering ? NookClip.textPrimary : NookClip.textSecondary)
        .padding(.horizontal, 7)
        // 宽度交给内容自己决定（由 `fittingSize` 量），只锁高度；
        // 写死宽度会让英文文案被截断，那正是「点不到也看不懂」的另一半问题
        .frame(height: LockedNoteChipPanel.size.height)
        .fixedSize(horizontal: true, vertical: false)
        .background(
            Capsule(style: .continuous)
                .fill(isHovering ? NookClip.bgInset : NookClip.bgPanel)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(NookClip.borderHairline, lineWidth: 0.5)
                )
        )
        .contentShape(Capsule(style: .continuous))
        .onHover { isHovering = $0 }
        .help(L10n.tr("pin.locked_hint"))
    }
}

// MARK: - 管理器

/// 贴条总线：创建 / 排布 / 收起，以及窗口级的全局监听（⌥⌘P 与 ⌥+滚轮）。
///
/// 为什么把手势放到管理器而不是各面板里：`NSEvent` 本地监听是全进程唯一的
/// 分发口，放面板里会出现「多个监听器互相抢事件」。管理器只有一份。
@MainActor
@Observable
final class PinnedWindowManager {
    static let shared = PinnedWindowManager()

    /// 同时钉住的上限：全局只留一张。
    /// 屏幕上的贴条是「当前手头这件事」的凭证，多张并存会让人分不清该看哪一张；
    /// 再钉一条时直接顶掉旧的（见 `pin(item:)`），不弹上限提示。
    static let maxPinnedNotes = 1
    /// 文本/代码贴条默认尺寸（窗口尺寸，含 2×16 投影边；卡片本身仍是 320×220）
    static let defaultSize = NSSize(
        width: 320 + PinnedNotePanel.shadowInset * 2,
        height: 220 + PinnedNotePanel.shadowInset * 2
    )
    /// 默认不透明度（留 4% 透底，让用户感知到这是浮层而非文档）
    static let defaultOpacity: Double = 0.96
    /// 不透明度下限 / 上限
    static let minOpacity: Double = 0.20
    static let maxOpacity: Double = 1.0
    /// ⌥+滚轮每档步进
    static let opacityStep: Double = 0.05
    /// 首次钉条时距屏幕可视区右上角的留白
    static let cornerInset: CGFloat = 24
    /// 穿透前的缓冲期：提示语同屏可见，期间点一下还能反悔
    static let lockedHintDuration: TimeInterval = 1.5
    /// 进编辑态抢键盘焦点的重试次数与间隔。
    ///
    /// `NSApp.activate` 是异步生效的：紧接着调 `makeKey` 时窗口往往还不是 key，
    /// 输入法上下文就没挂上，中文打不进去。每隔一帧确认一次，通常第 1 次就成功，
    /// 留到 6 次是给「App 刚从后台唤醒、窗口还没上屏」这类慢路径兜底。
    static let focusAcquireAttempts = 6
    static let focusAcquireInterval: TimeInterval = 1.0 / 60.0
    /// 贴条内容内边距（正文四周；图片贴条也按它留白）
    static let contentPadding: CGFloat = 12
    /// 单行头栏高度
    static let headerHeight: CGFloat = 28
    /// 头栏图标按钮边长与间距（卡片视图与热区判定共用同一份数值）
    static let headerControlButton: CGFloat = 18
    static let headerControlSpacing: CGFloat = 2
    /// 不透明度胶囊宽度（替代原来常驻的 52pt 滑块）
    static let opacityCapsuleWidth: CGFloat = 34

    /// 活跃贴条。上限是一张（`maxPinnedNotes`），保留数组是为了兼容既有的
    /// 「全部收起 / 是否有穿透贴条」这类批量语义，调用方不必区分单张与多张。
    private(set) var notes: [PinnedNoteModel] = []

    /// 上一张被调过的不透明度。新贴条沿用它：
    /// 用户调到 60% 多半是「我屏幕上就想要这个浓度」，下一张又从 96% 开始等于每次都要重调一遍。
    /// 只在本次运行内记忆（贴条本身按 spec 是会话级工具，不落盘）。
    @ObservationIgnored private var lastUsedOpacity: Double = defaultOpacity

    /// 新贴条将要沿用的初始不透明度（只读，供测试与调试观察记忆值）
    var currentUsedOpacity: Double { lastUsedOpacity }

    /// 保存回历史的回调钩子。返回 true 表示真的落库成功——
    /// 贴条据此才闪「已保存」，接不上或写失败就什么都不说，
    /// 绝不出现「点了有反馈但其实没存」的假成功。
    var onSaveToHistory: ((PinnedNoteModel) -> Bool)?

    /// id → 面板（不参与观察：面板是包装层，快照比对无意义）
    @ObservationIgnored private var panels: [UUID: PinnedNotePanel] = [:]
    /// 待生效的穿透任务（穿透前 1.5s 缓冲；恢复交互时取消）
    @ObservationIgnored private var pendingClickThrough: [UUID: DispatchWorkItem] = [:]
    /// ⌥⌘P（本地：本 App 在前台时命中）
    @ObservationIgnored private var keyMonitor: Any?
    /// ⌥+滚轮调不透明度
    @ObservationIgnored private var scrollMonitor: Any?
    /// id → 锁片（贴条穿透后唯一还能点的东西；穿透时创建，恢复交互时销毁）
    @ObservationIgnored private var lockedChips: [UUID: LockedNoteChipPanel] = [:]

    var pinnedCount: Int { notes.count }
    /// 是否已经有贴条。全局只留一张，接线层想问的是「按下去会不会顶掉现有那张」。
    var hasPinnedNote: Bool { !notes.isEmpty }

    /// 当前挂着的锁片数量（应恒等于「已真正穿透」的贴条数）。
    /// 直接读面板状态算，不额外存一份会漂移的计数。
    var lockedChipCount: Int { lockedChips.count }

    /// 当前贴条窗口的 frame（没有贴条时为 nil）。
    /// 面板本身是私有的，留这个只读出口给测试与调试观察落点是否沿用。
    var pinnedNoteFrame: NSRect? { panels.values.first?.frame }

    /// 外观通知的观察者凭据。
    /// 用闭包式 API 而不是 `#selector`：本类是纯 Swift 类型（不是 `NSObject`），
    /// `#selector` 那套 selector 机制在这里用不了。
    @ObservationIgnored private var appearanceObserver: NSObjectProtocol?
    @ObservationIgnored private var screenParametersObserver: NSObjectProtocol?

    /// 进编辑态之前，用户正在用的那个应用。
    /// 退出编辑时把它激活回来——`NSApp.deactivate()` 并不会把前台还给别人，
    /// 它只是把「激活请求」撤掉，前台会留在本 App 上（实测确认）。
    @ObservationIgnored private var appToRestore: NSRunningApplication?

    private init() {
        // 设置里换外观档位时，已经开着的贴条要立刻跟着变。
        // 主面板靠 SwiftUI 重绘自动跟随，贴条是独立窗口，必须自己接这条通知。
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .appearanceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshAppearance()
            }
        }
        // 拔掉外接显示器或调低分辨率时，自动把屏幕外的贴条与锁片收回可见屏幕内
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.clampAllPanelsToVisibleScreen()
            }
        }
    }

    deinit {
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
    }

    /// 把当前外观档位重新套到所有已打开的贴条与锁片上。
    /// 顺手调一次 `needsDisplay`：动态色（`NookClip.bgPanel` 等）是 NSColor 的
    /// `dynamicProvider`，窗口 appearance 变了之后要重绘才会取到新档位的值。
    func refreshAppearance() {
        for panel in panels.values {
            PinnedAppearance.apply(to: panel)
            panel.contentView?.needsDisplay = true
        }
        for chip in lockedChips.values {
            PinnedAppearance.apply(to: chip)
            chip.contentView?.needsDisplay = true
        }
    }

    /// 显示器分辨率变化或拔掉外接屏时，把所有贴条及锁片钳回可见屏幕内。
    func clampAllPanelsToVisibleScreen() {
        for (id, panel) in panels {
            let visible = visibleFrame(for: panel.frame)
            let size = clampedSize(panel.frame.size, in: visible)
            let origin = clampedOrigin(panel.frame.origin, size: size, in: visible)
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
            if lockedChips[id] != nil {
                attachLockChip(for: panel.note)
            }
        }
    }

    // MARK: - 编辑态焦点

    /// 进入编辑态：切状态 + 把键盘焦点真正拿到手。
    ///
    /// 只调 `makeKey()` 是不够的：贴条是 `.nonactivatingPanel`，本 App 又常驻后台
    /// （`LSUIElement`）。用户在别的应用里点铅笔时 App 不在前台，`makeKey()` 会静默
    /// 失败——窗口不是 key window，输入法上下文就不激活，中文一个字也打不出来
    /// （ASCII 有时能凑巧进去，所以症状看起来像「只有中文不行」）。
    /// 必须先 `activate` 再 `makeKey`，顺序反了同样无效。
    func beginEditing(_ note: PinnedNoteModel) {
        guard let panel = panels[note.id] else { return }
        note.isEditing = true
        // 先把用户原来在用的应用记下来，退出编辑时好还回去。
        // 只在真的抢了前台时才记：本来就在前台就不用还。
        if !NSApp.isActive {
            appToRestore = NSWorkspace.shared.frontmostApplication
        }
        acquireEditorFocus(panel: panel, attempt: 0)
    }

    /// 把键盘焦点抢到贴条上。
    ///
    /// 为什么要重试：`.nonactivatingPanel` 在 App 没激活时 `makeKey` 会**静默失败**
    /// （窗口不会成为 key window，输入法上下文因此不挂载，中文一个字也打不出来）。
    /// 而 `NSApp.activate` 是异步生效的，`makeKeyAndOrderFront` 紧随其后那一帧
    /// 窗口还不是 key —— 实测点完铅笔后 `isKey` 仍是 false。只做一次等于没做，
    /// 必须跨几帧反复确认，直到真的拿到 key 为止。
    private func acquireEditorFocus(panel: PinnedNotePanel, attempt: Int) {
        guard panel.note.isEditing else { return }
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        if !panel.isKeyWindow {
            panel.makeKeyAndOrderFront(nil)
        }
        guard !panel.isKeyWindow, attempt < Self.focusAcquireAttempts else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.focusAcquireInterval) { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.acquireEditorFocus(panel: panel, attempt: attempt + 1)
        }
    }

    /// 退出编辑态：切状态 + 把前台还给用户原来在用的应用。
    ///
    /// 进编辑态时抢了前台，退出后不还回去，用户就得自己点回去——那比不抢更烦。
    func endEditing(_ note: PinnedNoteModel) {
        note.isEditing = false
        releaseEditorFocus()
    }

    /// 是否有待归还的前台（进了编辑态、还没退出）。测试用来确认状态不会残留。
    var hasPendingFocusRestore: Bool { appToRestore != nil }

    /// 只在「前台是我们主动抢的」情况下才还回去。
    ///
    /// 不能只调 `NSApp.deactivate()`：那个方法只是撤掉本 App 的激活请求，
    /// 前台并不会回到用户原来那个应用（实测 `isActive` 仍是 true）。
    /// 必须把记下来的应用重新激活一次，用户才能接着在原来的窗口里打字。
    private func releaseEditorFocus() {
        guard let app = appToRestore else { return }
        appToRestore = nil
        // 用户可能已经把那个应用退了，退掉的不能再激活
        guard !app.isTerminated else { return }
        app.activate(options: [])
    }

    // MARK: - 创建 / 关闭

    /// 从剪贴板条目钉一张贴条。
    /// 全局只留一张：已有贴条时先收起旧的，再钉新的。
    /// 不拒绝、不弹提示——「钉第二条」的意图本来就是「换成这一条」，
    /// 让用户先手动关掉旧的纯属多余步骤。
    func pin(item: ClipboardItem) {
        installEventMonitors()

        let resolved = Self.resolveText(for: item)
        let imageData = item.type == .image
            ? item.payloadPath.flatMap { FileStore.shared.load(path: $0) }
            : nil

        // 顶掉旧贴条前先记下它的位置：新贴条落在原地，
        // 用户拖到顺手的位置之后，换内容不会又跳回屏幕角落。
        let replacedFrame = panels.values.first?.frame

        let note = PinnedNoteModel(
            sourceItemId: item.id.uuidString,
            itemType: item.type,
            sourceAppName: item.sourceAppName,
            editableText: resolved.text,
            originalText: resolved.text,
            imageData: imageData,
            ocrText: item.ocrText,
            isCode: item.persistedKind == "code",
            language: item.metadata.language,
            isSensitive: item.isSensitive,
            isDegraded: resolved.degraded
        )

        // 先拆旧的再建新的：顺序反了会短暂出现两张，也会让新贴条被旧贴条挤开位置
        unpinAll()

        let size = Self.initialNoteSize(for: note)
        let origin = pinOrigin(for: size, reusing: replacedFrame)
        let panel = PinnedNotePanel(note: note, contentSize: size)
        // 沿用上一张调好的浓度，用户不必每钉一张就重调一次
        note.opacity = min(Self.maxOpacity, max(Self.minOpacity, lastUsedOpacity))
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        panel.alphaValue = note.opacity
        wire(panel: panel, note: note)
        panel.orderFrontRegardless()

        panels[note.id] = panel
        notes.append(note)
    }

    /// 收起单张贴条。
    func unpin(id: UUID) {
        guard let panel = panels.removeValue(forKey: id) else { return }
        // 正在编辑的那张被关掉时，别把前台一起带走（用户还要回去打字）
        let wasEditing = panel.note.isEditing
        pendingClickThrough[id]?.cancel()
        pendingClickThrough[id] = nil
        detachLockChip(for: id)
        panel.orderOut(nil)
        panel.contentView = nil
        notes.removeAll { $0.id == id }
        syncPinnedRestoreHotKeyRegistration()
        if wasEditing { releaseEditorFocus() }
    }

    /// 收起全部贴条。
    func unpinAll() {
        for id in Array(panels.keys) {
            unpin(id: id)
        }
    }

    /// 接线层（MainView / AppDelegate）用的别名：语义上「关闭所有贴条」
    func closeAll() {
        unpinAll()
    }

    // MARK: - 交互状态

    /// 折叠 / 展开：窗口高度与宽度同步切换，顶边锚定（贴条贴在屏幕上方，折叠不该往上跳）
    func toggleCollapse(_ note: PinnedNoteModel) {
        guard let panel = panels[note.id] else { return }
        note.isCollapsed.toggle()

        var frame = panel.frame
        let visible = visibleFrame(for: frame)
        if note.isCollapsed {
            panel.expandedSize = frame.size
            frame.size = PinnedNotePanel.collapsedSize
        } else {
            // 折叠期间用户可能动过屏幕，还原时仍要卡在可视区内
            let target = NSSize(
                width: max(PinnedNotePanel.minSize.width, panel.expandedSize.width),
                height: max(PinnedNotePanel.minSize.height, panel.expandedSize.height)
            )
            frame.size = clampedSize(target, in: visible)
        }
        let topAnchorOrigin = NSPoint(x: frame.origin.x, y: panel.frame.maxY - frame.size.height)
        frame.origin = clampedOrigin(topAnchorOrigin, size: frame.size, in: visible)
        panel.setFrame(frame, display: true, animate: true)
    }

    /// 点击穿透开关。
    /// 开启时**不立刻**设 `ignoresMouseEvents`：先给 1.5s 缓冲，让「按 ⌥⌘P 恢复」
    /// 的提示同屏可见，用户误点时还能点回来；缓冲结束才真正穿透。
    ///
    /// 真正穿透的那一刻会挂上锁片：从这以后贴条本体再也收不到鼠标事件，
    /// 必须留一个能点的入口，否则用户就只能强退应用。
    func toggleClickThrough(_ note: PinnedNoteModel) {
        guard let panel = panels[note.id] else { return }

        if note.isClickThrough {
            cancelPendingClickThrough(note.id)
            note.isClickThrough = false
            panel.ignoresMouseEvents = false
            detachLockChip(for: note.id)
            syncPinnedRestoreHotKeyRegistration()
            return
        }

        note.isClickThrough = true
        syncPinnedRestoreHotKeyRegistration()
        cancelPendingClickThrough(note.id)
        let work = DispatchWorkItem { [weak self, weak panel] in
            guard let self, let panel, panel.note.isClickThrough else { return }
            panel.ignoresMouseEvents = true
            self.pendingClickThrough[note.id] = nil
            // 缓冲结束、真正穿透的同一刻挂上锁片（提前挂会遮住贴条自己的按钮）
            self.attachLockChip(for: note)
        }
        pendingClickThrough[note.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lockedHintDuration, execute: work)
    }

    /// 恢复所有穿透贴条为可交互（⌥⌘P / 菜单栏 / 锁片共用）。
    /// 穿透后贴条收不到任何鼠标事件，所以这条路必须存在且尽量难断：
    /// Carbon 热键（无需权限）+ 锁片（纯鼠标）+ 菜单栏，三重兜底。
    func restoreAllClickThrough() {
        for (id, panel) in panels {
            cancelPendingClickThrough(id)
            panel.note.isClickThrough = false
            panel.ignoresMouseEvents = false
            detachLockChip(for: id)
        }
        syncPinnedRestoreHotKeyRegistration()
    }

    /// 按需动态注册/注销 ⌥⌘P 全局救回热键：没有贴条处于点击穿透态时绝不占用系统热键
    private func syncPinnedRestoreHotKeyRegistration() {
        let hasClickThrough = notes.contains { $0.isClickThrough }
        if hasClickThrough {
            HotKeyManager.shared.registerPinnedRestoreHotKey()
        } else {
            HotKeyManager.shared.unregisterPinnedRestoreHotKey()
        }
    }

    // MARK: - 锁片

    /// 给某张贴条挂上「取消穿透」锁片（贴在卡片右上角内侧）。
    private func attachLockChip(for note: PinnedNoteModel) {
        guard let panel = panels[note.id] else { return }
        detachLockChip(for: note.id)

        let chip = LockedNoteChipPanel()
        chip.onClick = { [weak self] in
            self?.toggleClickThrough(note)
        }
        // 贴到「卡片」而不是「窗口」：窗口四周还留着一圈透明投影边，
        // 直接贴窗口角会让小锁离卡片边远出一截，看着像飘在外面。
        chip.attach(to: panel.cardFrame)
        chip.orderFrontRegardless()
        lockedChips[note.id] = chip
    }

    private func detachLockChip(for id: UUID) {
        guard let chip = lockedChips.removeValue(forKey: id) else { return }
        chip.orderOut(nil)
        // 点锁片解锁时，这一句还在锁片自己的 `sendEvent` 事件栈上：当场拆宿主视图
        // 等于在事件派发途中销毁接收者。异步块既推迟了拆除，又顺带强引用住
        // chip 直到本轮 runloop 结束，避免它在事件栈里被 ARC 释放。
        DispatchQueue.main.async { chip.contentView = nil }
    }

    /// 不透明度（滑块 / ⌥+滚轮共用；钳制在 20%~100%）
    func setOpacity(_ note: PinnedNoteModel, to value: Double) {
        let clamped = min(Self.maxOpacity, max(Self.minOpacity, value))
        note.opacity = clamped
        panels[note.id]?.alphaValue = clamped
        // 记住这个浓度，下张贴条直接沿用（见 lastUsedOpacity 的说明）
        lastUsedOpacity = clamped
    }

    /// 「保存回历史」按钮：先走接线层钩子，没接就什么都不做（不假成功）
    @discardableResult
    func requestSaveToHistory(_ note: PinnedNoteModel) -> Bool {
        guard let didSave = onSaveToHistory?(note), didSave else { return false }
        note.savedAt = Date()
        return true
    }

    private func cancelPendingClickThrough(_ id: UUID) {
        pendingClickThrough[id]?.cancel()
        pendingClickThrough[id] = nil
    }

    // MARK: - 面板接线

    private func wire(panel: PinnedNotePanel, note: PinnedNoteModel) {
        panel.onClose = { [weak self] in
            self?.unpin(id: note.id)
        }
        panel.onCommitEditing = { [weak self, weak note] in
            guard let self, let note else { return }
            // 正文是实时写进 editableText 的（TextEditor 直接绑模型），
            // 这里只负责退出编辑态；originalText 保留用于「有无改动」判断
            note.isEditing = false
            self.setOpacity(note, to: note.opacity)
            self.releaseEditorFocus()
        }

        let actions = PinnedNoteActions(
            close: { [weak self] in self?.unpin(id: note.id) },
            copy: { text in
                // 剪贴板写入统一走 PasteService（内部标记 + 敏感自毁调度都在它那里）
                _ = PasteService.shared.copyText(text, containsSensitive: note.isSensitive || note.isDegraded)
            },
            copyOCR: { text in
                _ = PasteService.shared.copyText(text)
            },
            saveToHistory: { [weak self, weak note] in
                guard let self, let note else { return }
                // 返回值由管理器打点（note.savedAt），卡片据此闪确认；
                // 失败时按钮保持静默——弹窗比「没反应」更打扰
                _ = self.requestSaveToHistory(note)
            },
            toggleCollapse: { [weak self, weak note] in
                guard let self, let note else { return }
                self.toggleCollapse(note)
            },
            toggleClickThrough: { [weak self, weak note] in
                guard let self, let note else { return }
                self.toggleClickThrough(note)
            },
            beginEditing: { [weak self, weak note] in
                guard let self, let note else { return }
                self.beginEditing(note)
            },
            endEditing: { [weak self, weak note] in
                guard let self, let note else { return }
                self.endEditing(note)
            },
            setOpacity: { [weak self, weak note] value in
                guard let self, let note else { return }
                self.setOpacity(note, to: value)
            }
        )

        let hosting = NSHostingView(
            rootView: PinnedNoteCard(note: note, actions: actions).nookClipLocalized()
        )
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = NSRect(origin: .zero, size: panel.frame.size)
        panel.contentView = hosting
    }

    // MARK: - 落点

    /// 新贴条的落点：优先接住被顶掉那张的位置，让「换内容」不改变用户已经摆好的布局；
    /// 没有旧贴条（首次钉）或旧位置在新尺寸下超出可视区时，退到屏幕右上角。
    private func pinOrigin(for size: NSSize, reusing previousFrame: NSRect?) -> NSPoint {
        if let previousFrame {
            let visible = visibleFrame(for: previousFrame)
            let clamped = clampedOrigin(
                NSPoint(x: previousFrame.minX, y: previousFrame.maxY - size.height),
                size: size,
                in: visible
            )
            return NSPoint(x: clamped.x.rounded(), y: clamped.y.rounded())
        }
        let visible = screenVisibleFrame
        let baseX = visible.maxX - size.width - Self.cornerInset
        let baseY = visible.maxY - size.height - Self.cornerInset
        return NSPoint(x: baseX.rounded(), y: baseY.rounded())
    }

    /// 把落点钳进可视区（尺寸变了之后旧位置可能压到菜单栏或屏幕外）。
    private func clampedOrigin(_ origin: NSPoint, size: NSSize, in visible: NSRect) -> NSPoint {
        let maxX = max(visible.minX, visible.maxX - size.width)
        let maxY = max(visible.minY, visible.maxY - size.height)
        return NSPoint(
            x: min(max(origin.x, visible.minX), maxX),
            y: min(max(origin.y, visible.minY), maxY)
        )
    }

    private var screenVisibleFrame: NSRect {
        (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func visibleFrame(for rect: NSRect) -> NSRect {
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) {
            return screen.visibleFrame
        }
        return screenVisibleFrame
    }

    /// 初始尺寸：文本/代码 320×220；图片按等比缩放，最长边不超过 480。
    /// 图片贴条要把头栏、内边距和四周投影边都算进去，否则图片会被压成一条缝。
    private static func initialNoteSize(for note: PinnedNoteModel) -> NSSize {
        guard let image = note.image, image.size.width > 0, image.size.height > 0 else {
            return defaultSize
        }
        // 窗口尺寸 = 内容尺寸 + 2×投影边；下面先按内容算，最后统一加回投影边。
        let chrome = PinnedNotePanel.shadowInset * 2
        let maxContentWidth = PinnedNotePanel.imageMaxSide - chrome - contentPadding * 2
        let maxContentHeight = PinnedNotePanel.imageMaxSide - chrome - headerHeight - contentPadding * 2
        let scale = min(1, min(maxContentWidth / image.size.width, maxContentHeight / image.size.height))
        let width = max(
            PinnedNotePanel.minSize.width,
            (image.size.width * scale + contentPadding * 2).rounded() + chrome
        )
        let height = max(
            PinnedNotePanel.minSize.height,
            (image.size.height * scale + headerHeight + contentPadding * 2).rounded() + chrome
        )
        return NSSize(
            width: min(width, PinnedNotePanel.imageMaxSide + chrome),
            height: min(height, PinnedNotePanel.imageMaxSide + chrome)
        )
    }

    private func clampedSize(_ size: NSSize, in visibleFrame: NSRect? = nil) -> NSSize {
        let visible = (visibleFrame ?? screenVisibleFrame).size
        return NSSize(
            width: min(size.width, max(PinnedNotePanel.minSize.width, visible.width)),
            height: min(size.height, max(PinnedNotePanel.minSize.height, visible.height))
        )
    }

    // MARK: - 内容解析

    /// 取贴条正文字符串。
    /// 敏感条目走 `revealPlainContentResult`：解密失败绝不把掩码串当正文展示，
    /// 而是降级成 summary 并打 `isDegraded` 标记（头栏据此弱提示「已脱敏」）。
    private static func resolveText(for item: ClipboardItem) -> (text: String, degraded: Bool) {
        if item.isSensitive {
            switch item.revealPlainContentResult() {
            case .success(let plain):
                return (plain, false)
            case .failure:
                return (item.summary, true)
            }
        }
        switch item.type {
        case .image:
            return ("", false)
        case .file:
            // 文件贴条展示路径（多选是换行拼接，原样保留）
            return (item.payloadPath ?? item.summary, false)
        case .text, .url:
            return (item.summary, false)
        }
    }

    // MARK: - 键盘 / 滚轮监听

    /// 安装进程级监听（只装一次；`NSEvent` 本地监听是全进程唯一分发口）。
    ///
    /// 这里**只装本地监听**。贴条穿透后焦点在别的应用，本地监听收不到事件，
    /// 原来靠 `NSEvent.addGlobalMonitorForEvents` 兜底——但那个 API 要辅助功能权限，
    /// 没授权时系统静默不投递，于是 ⌥⌘P 形同不存在。跨应用的救回改由
    /// `HotKeyManager.pinnedRestoreShortcut`（Carbon 热键，无需权限）负责。
    private func installEventMonitors() {
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard let self else { return event }
                return self.handleGlobalKey(event) ? nil : event
            }
        }
        if scrollMonitor == nil {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
                guard let self else { return event }
                return self.handleScroll(event) ? nil : event
            }
        }
    }

    /// ⌥⌘P：恢复所有穿透贴条的可交互状态
    private func handleGlobalKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers == [.command, .option], Int(event.keyCode) == kVK_ANSI_P else { return false }
        guard !panels.isEmpty else { return false }
        restoreAllClickThrough()
        return true
    }

    /// ⌥+滚轮：在贴条上调不透明度（步进 5%，夹在 20%~100%）。
    /// 消费事件避免带动正文滚动——用户按着 ⌥ 时意图明确是调透明度。
    private func handleScroll(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.option),
              let panel = event.window as? PinnedNotePanel else { return false }
        let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY
        guard delta != 0 else { return false }
        let step = delta > 0 ? Self.opacityStep : -Self.opacityStep
        setOpacity(panel.note, to: panel.note.opacity + step)
        return true
    }
}

// MARK: - 拖动把手

/// 头栏拖动手柄。
///
/// 为什么不能只靠 `isMovableByWindowBackground`：它依赖命中视图的
/// `mouseDownCanMoveWindow`，而 SwiftUI 的 `NSHostingView` 里只要有一点
/// 手势或可选中文本，这个判定就时真时假——表现成「有时候能拖、有时候按下去没反应」。
/// 这里垫一个真正的 NSView，明说自己可以拖窗口，空出来的头栏区域就永远可拖；
/// 叠在上面的按钮仍然先吃到点击，互不影响。
private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DragAreaView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragAreaView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        /// 手柄不画任何东西，只提供命中区
        override func draw(_ dirtyRect: NSRect) {}
        /// 让光标表达「这里能拖」
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        /// 双保险：`mouseDownCanMoveWindow` 在某些宿主视图里不一定被采纳，
        /// 这里显式接手拖动。`performDrag` 自己区分「点一下」和「拖一段」，
        /// 只想点一下的用户不会被误移窗口。
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

// MARK: - SwiftUI 动作表

/// 卡片对外的动作出口。单独成结构体而不是 8 个闭包参数：
/// 视图初始化语意清楚，加动作时也不至于把调用点撑爆。
@MainActor
struct PinnedNoteActions {
    var close: () -> Void
    var copy: (String) -> Void
    var copyOCR: (String) -> Void
    var saveToHistory: () -> Void
    var toggleCollapse: () -> Void
    var toggleClickThrough: () -> Void
    var beginEditing: () -> Void
    var endEditing: () -> Void
    var setOpacity: (Double) -> Void
}

// MARK: - 卡片投影

/// 只画在卡片外环的投影（把中间掏空）。
///
/// 为什么不用 `.shadow(...)`：SwiftUI 的 `.shadow` 是给整个视图加阴影，卡片填充又是
/// 半透明的，阴影就会从卡片内部透上来；而窗口 `hasShadow` 更是把阴影直接铺在卡片下面，
/// 浅色模式下那圈内侧暗边叠上描边就成了「厚边框」。
/// 这里改成「一团模糊的暗色 + 用 destinationOut 把卡片形状掏掉」，只剩卡片外面那圈，
/// 卡片内部永远保持纯色。
private struct ShadowRing<S: Shape>: View {
    let shape: S

    var body: some View {
        ZStack {
            shape
                .fill(Color.black.opacity(PinnedNotePanel.shadowOpacity))
                .blur(radius: PinnedNotePanel.shadowBlurRadius)
                .offset(y: PinnedNotePanel.shadowOffsetY)
            shape.fill(Color.black).blendMode(.destinationOut)
        }
        .compositingGroup()
        .allowsHitTesting(false)
    }
}

// MARK: - 卡片视图

/// 贴条外观：一张纸。
///
/// 设计取舍都在「克制」两个字上：无彩色强调、无粗描边、无多层阴影堆叠；
/// 控制条默认 `opacity 0` 且不接受点击（只会淡入，不会在静止态出现幽灵热区）。
private struct PinnedNoteCard: View {
    let note: PinnedNoteModel
    let actions: PinnedNoteActions

    /// 悬停态：控制条淡入的唯一开关
    @State private var isHovering = false
    /// 不透明度控件是否展开成滑块（默认只显示百分比胶囊）
    @State private var isOpacityExpanded = false
    /// 展开后自动收回的倒计时
    @State private var opacityCloseWork: DispatchWorkItem?
    /// 穿透提示语可见期（1.5s，与管理器缓冲期等长）
    @State private var isLockHintVisible = false
    /// 「已保存」提示的本地可见期（1.2s；模型上的 savedAt 是持久标记，这里只控动画）
    @State private var isSavedHintVisible = false
    /// 提示语倒计时令牌：变更即重新计时
    @State private var hintToken = 0
    /// 编辑态焦点（失焦即退出编辑态）
    @FocusState private var isEditorFocused: Bool

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: NookClip.radiusPanel, style: .continuous)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            if !note.isCollapsed {
                bodyArea
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(cardShape.fill(NookClip.bgPanel))
        .clipShape(cardShape)
        // 投影摆在 `clipShape` 之后：它本来就要画到卡片轮廓外面去，
        // 放在裁剪之前会被一起裁掉，等于没有阴影。
        .background { ShadowRing(shape: cardShape) }
        .overlay {
            // 0.5pt 是主题里所有卡片面（`nookClipSurface`）的统一线宽。1pt 在浅色下
            // 会明显偏重，看着像加了边框。
            cardShape.strokeBorder(NookClip.borderHairline, lineWidth: 0.5)
        }
        .overlay(alignment: .bottom) { bottomHintPill }
        .overlay(alignment: .bottomTrailing) {
            if !note.isCollapsed { resizeGripIndicator(.bottomRight) }
        }
        .overlay(alignment: .bottomLeading) {
            if !note.isCollapsed { resizeGripIndicator(.bottomLeft) }
        }
        // 投影要画在卡片外，而窗口是透明的、边界是硬的：不留下这圈透明的余量，
        // 光晕就被窗口矩形切断，四角变成笔直的黑色直角线。放在所有 overlay 之后，
        // 这样提示语与缩放手柄仍贴着卡片边缘，不会缩到里面去。
        .padding(PinnedNotePanel.shadowInset)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .animation(.easeOut(duration: 0.15), value: note.isCollapsed)
        // 保存成功：闪一条确认再淡出（无声音、无弹窗，贴条的产品前提是不打扰）
        .onChange(of: note.savedAt) { _, savedAt in
            guard savedAt != nil else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                isSavedHintVisible = true
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                withAnimation(.easeOut(duration: 0.15)) {
                    isSavedHintVisible = false
                }
            }
        }
        .task(id: hintToken) {
            guard isLockHintVisible else { return }
            try? await Task.sleep(nanoseconds: UInt64(PinnedWindowManager.lockedHintDuration * 1_000_000_000))
            withAnimation(.easeOut(duration: 0.15)) {
                isLockHintVisible = false
            }
        }
    }

    /// 缩放手柄视觉提示：hover 时浮出一个指向角外的箭头，和系统窗口角落的通用语汇一致。
    /// 只做视觉，真正的热区与拖拽循环在 `PinnedNotePanel.sendEvent` 里。
    ///
    /// 两个下角都给提示：以前只有右下角有图标，左下角虽然能拖却完全看不出来，
    /// 用户会以为贴条只有一侧能拉伸。
    private func resizeGripIndicator(_ corner: PinnedNotePanel.ResizeCorner) -> some View {
        Image(systemName: corner == .bottomRight ? "arrow.down.right" : "arrow.down.left")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(NookClip.textTertiary)
            .frame(
                width: PinnedNotePanel.resizeGripSize,
                height: PinnedNotePanel.resizeGripSize,
                alignment: corner == .bottomRight ? .bottomTrailing : .bottomLeading
            )
            .padding(.leading, corner == .bottomLeft ? 4 : 0)
            .padding(.trailing, corner == .bottomRight ? 4 : 0)
            .padding(.bottom, 4)
            .opacity(isHovering ? 0.55 : 0)
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.15), value: isHovering)
    }

    // MARK: 头栏（28pt：来源 + 类型徽标 + 控制条）

    private var headerBar: some View {
        HStack(spacing: 6) {
            // 穿透态常驻角标：穿透之后窗口收不到任何鼠标事件，hover 提示永远不会出现，
            // 必须有一个不依赖 hover 的标记告诉用户「它还在，⌥⌘P 能救回来」
            if note.isClickThrough {
                Image(systemName: NookClipIcon.Sensitive.lock)
                    .font(.system(size: NookClipIconSize.micro, weight: .medium))
                    .foregroundStyle(NookClip.accent.opacity(0.9))
                    .help(L10n.tr("pin.locked_hint"))
            }
            if !note.isCollapsed, let app = note.sourceAppName, !app.isEmpty {
                Text(app)
                    .font(.nookClipMeta)
                    .foregroundStyle(NookClip.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            typeBadge
            if note.isDegraded {
                // 敏感明文没取到：头栏给一个极轻的盾牌标记，提醒这是脱敏后的内容
                Image(systemName: NookClipIcon.Sensitive.lock)
                    .font(.system(size: NookClipIconSize.micro, weight: .medium))
                    .foregroundStyle(NookClip.colorSensitive)
            }
            if note.isCollapsed {
                Text(note.summaryLine)
                    .font(.nookClipMeta)
                    .foregroundStyle(NookClip.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // 折叠成一条时，双击标题条直接展开：此时控制条要 hover 才出现，
                    // 让用户为了展开一次而先找准那个小箭头，代价太大
                    .onTapGesture(count: 2) { actions.toggleCollapse() }
                    .help(L10n.tr("pin.expand"))
            }
            Spacer(minLength: 4)
            controlBar
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)
        }
        .padding(.horizontal, 10)
        .frame(height: PinnedWindowManager.headerHeight)
        // 垫一层真正的拖动手柄：SwiftUI 内容上的 isMovableByWindowBackground 时灵时不灵
        .background(WindowDragHandle())
    }

    /// 控制条可见条件：悬停，或正在编辑（编辑时按 ⌘⏎ 需要看见按钮的反馈）
    private var controlsVisible: Bool { isHovering || note.isEditing }

    private var typeBadge: some View {
        Text(typeBadgeText)
            .font(.nookClipBadge)
            .foregroundStyle(NookClip.textTertiary)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule(style: .continuous).fill(NookClip.bgInset))
    }

    private var typeBadgeText: String {
        switch note.itemType {
        case .text:
            return note.isCode ? codeBadgeText : L10n.tr("item.type_text")
        case .image:
            return L10n.tr("item.type_image")
        case .file:
            return L10n.tr("item.type_file")
        case .url:
            return L10n.tr("category.link")
        }
    }

    /// 代码贴条的徽标写法与主面板语言 pill 一致：能认出语言就直接写语言名
    ///（`metadata.language` → 「Objective-C」），认不出才回退到笼统的「代码」。
    private var codeBadgeText: String {
        if let raw = note.language?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let normalized = LanguageClassifier.normalize(raw)
            if normalized != "code", normalized != "unknown" {
                return LanguageClassifier.displayName(for: normalized)
            }
        }
        return L10n.tr("preview.code_fallback")
    }

    /// 头栏是否要临时腾地方：滑块展开时 78pt 的行程会把最小宽度塞爆，
    /// 此时先让低频按钮（编辑 / 复制 / 保存）退场，调完自动回来。
    private var controlBarIsCompact: Bool { isOpacityExpanded && !note.isCollapsed }

    private var controlBar: some View {
        HStack(spacing: PinnedWindowManager.headerControlSpacing) {
            if !note.isCollapsed, note.itemType != .image, !controlBarIsCompact {
                // 编辑入口：原来只能双击正文，用户基本猜不到，等于 Scratchpad 功能白做。
                // 编辑中变成对勾，退出编辑有明确落点（Esc / ⌘⏎ 也仍然有效）。
                iconButton(
                    note.isEditing ? "checkmark" : "pencil",
                    help: L10n.tr(note.isEditing ? "pin.finish_editing" : "pin.edit"),
                    isActive: note.isEditing
                ) {
                    if note.isEditing {
                        actions.endEditing()
                    } else {
                        actions.beginEditing()
                    }
                }
                iconButton("doc.on.doc", help: L10n.tr("pin.copy")) {
                    actions.copy(note.editableText)
                }
                iconButton("tray.and.arrow.down", help: L10n.tr("pin.save_to_history")) {
                    actions.saveToHistory()
                }
            }
            if !note.isCollapsed, note.itemType == .image, !controlBarIsCompact,
               let ocr = note.ocrText, !ocr.isEmpty {
                iconButton("text.viewfinder", help: L10n.tr("pin.copy_ocr")) {
                    actions.copyOCR(ocr)
                }
            }
            if !note.isCollapsed {
                opacityControl
            }
            iconButton(
                note.isClickThrough ? NookClipIcon.Sensitive.lock : "lock.open",
                help: L10n.tr(note.isClickThrough ? "pin.unlock" : "pin.lock"),
                isActive: note.isClickThrough
            ) {
                toggleLock()
            }
            iconButton(
                note.isCollapsed ? "chevron.down" : "chevron.up",
                help: L10n.tr(note.isCollapsed ? "pin.expand" : "pin.collapse")
            ) {
                actions.toggleCollapse()
            }
            iconButton("xmark", help: L10n.tr("pin.close")) {
                actions.close()
            }
        }
    }

    /// 不透明度：默认只占一个 34pt 的百分比胶囊，点一下原地展开成滑块，再点收回。
    ///
    /// 原来常驻一条 52pt 的 mini 滑块，在 232pt 的最小宽度里跟来源名、类型徽标抢位置，
    /// 而且 52pt 行程上拖 20%~100% 根本拿不准。改成按需展开后，静止态更干净，
    /// 真要调的时候又有完整行程。
    @ViewBuilder
    private var opacityControl: some View {
        if isOpacityExpanded {
            Slider(
                value: Binding(
                    get: { note.opacity },
                    set: { actions.setOpacity($0) }
                ),
                in: PinnedWindowManager.minOpacity...PinnedWindowManager.maxOpacity
            )
            .controlSize(.mini)
            .frame(width: 78, height: 18)
            .tint(NookClip.textTertiary)
            .help(L10n.tr("pin.opacity"))
            // 松手就收回胶囊：调完看一眼效果是最常见的动作，不该让贴条一直鼓着一块
            .onChange(of: note.opacity) { _, _ in
                scheduleOpacityAutoClose(after: 1.6)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.92)))
        } else {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { isOpacityExpanded = true }
                scheduleOpacityAutoClose(after: 3.0)
            } label: {
                Text("\(Int((note.opacity * 100).rounded()))%")
                    .font(.nookClipBadge)
                    .monospacedDigit()
                    .foregroundStyle(NookClip.textSecondary)
                    .frame(width: PinnedWindowManager.opacityCapsuleWidth, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(L10n.tr("pin.opacity"))
        }
    }

    private func scheduleOpacityAutoClose(after delay: TimeInterval) {
        opacityCloseWork?.cancel()
        let work = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.12)) { isOpacityExpanded = false }
        }
        opacityCloseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func iconButton(
        _ symbol: String,
        help: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isActive ? NookClip.accent : NookClip.textSecondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(help)
    }

    /// 穿透开关：开启时先展示 1.5s 提示（管理器此时尚未真正设 ignoresMouseEvents，
    /// 用户点错了还能点回来；缓冲结束才穿透，之后只能 ⌥⌘P 恢复）
    private func toggleLock() {
        actions.toggleClickThrough()
        guard note.isClickThrough else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            isLockHintVisible = true
        }
        hintToken += 1
    }

    /// 底部提示：同一时刻只显示一条，保存确认优先于穿透提示
    @ViewBuilder
    private var bottomHintPill: some View {
        if isSavedHintVisible {
            hintPill(text: L10n.tr("pin.saved_hint"), accent: NookClip.colorSuccess)
        } else {
            lockHintPill
        }
    }

    private func hintPill(text: String, accent: Color?) -> some View {
        HStack(spacing: 4) {
            if let accent {
                Image(systemName: "checkmark")
                    .font(.system(size: NookClipIconSize.micro, weight: .semibold))
                    .foregroundStyle(accent)
            }
            Text(text)
                .font(.nookClipCaption)
                .foregroundStyle(NookClip.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule(style: .continuous).fill(NookClip.bgInset))
        .padding(.bottom, 6)
        .transition(.opacity)
    }

    private var lockHintPill: some View {
        Group {
            if isLockHintVisible {
                // 允许折到两行：这条提示要同时说出「点右上角小锁」和「⌘⌥P」两种救回方式，
                // 而贴条最小只有 232pt 宽，强行单行会被截成半句话——那正是用户看不懂的原因。
                Text(L10n.tr("pin.locked_hint"))
                    .font(.nookClipCaption)
                    .foregroundStyle(NookClip.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: NookClip.radiusCard, style: .continuous).fill(NookClip.bgInset))
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                    .transition(.opacity)
            }
        }
    }

    // MARK: 正文

    @ViewBuilder
    private var bodyArea: some View {
        if note.itemType == .image {
            imageBody
        } else if note.isEditing {
            editorBody
        } else if note.isCode {
            codeBody
        } else {
            textBody
        }
    }

    /// 文本正文：只读，可选中文字。行距略放宽，长段落才好读。
    ///
    /// 进编辑态的唯一入口是头栏那颗铅笔按钮，这里**不再绑双击**。
    /// 原因是硬冲突：正文开了 `.textSelection`，而 macOS 里双击的通用语义就是
    /// 「选中一个单词」——同一个手势既想选中词又想变成编辑框，用户想抠一个词复制，
    /// 结果整块正文跳成了输入框。编辑入口留在看得见的按钮上，含义才唯一。
    private var textBody: some View {
        ScrollView(.vertical, showsIndicators: false) {
            Text(note.editableText.isEmpty ? L10n.tr("pin.empty_text") : note.editableText)
                .font(.nookClipBody)
                .foregroundStyle(note.editableText.isEmpty ? NookClip.textTertiary : NookClip.textPrimary)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(PinnedWindowManager.contentPadding)
        }
    }

    /// 代码正文：直接复用主面板那套 `CodeBlockView`（highlight.js 语法高亮、行号列、
    /// 跨行拖选复制、超长行横向平移、hover 行高亮）。
    ///
    /// 以前贴条只做了「等宽字体 + 一层淡底色」，跟主面板里那块代码卡完全两个观感：
    /// 同一段代码钉到屏幕上就不认得了。现在两处共用同一个视图，样式天然一致。
    /// 语言优先取条目自己记下的 `metadata.language`，没有才交给 highlight.js 猜。
    private var codeBody: some View {
        ScrollView(.vertical, showsIndicators: false) {
            if note.editableText.isEmpty {
                Text(L10n.tr("pin.empty_text"))
                    .font(.nookClipBody)
                    .foregroundStyle(NookClip.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(PinnedWindowManager.contentPadding)
            } else {
                CodeBlockView(
                    lines: CodePreviewCard.normalizedLines(note.editableText),
                    forcedLanguage: note.language
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
        }
    }

    /// 编辑态：TextEditor 直接绑模型（实时写入，⌘⏎/失焦只是退出编辑态）
    private var editorBody: some View {
        TextEditor(
            text: Binding(
                get: { note.editableText },
                set: { note.editableText = $0 }
            )
        )
        .font(note.isCode ? .nookClipCode : .nookClipBody)
        .foregroundStyle(NookClip.textPrimary)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .focused($isEditorFocused)
        .padding(.horizontal, PinnedWindowManager.contentPadding - 4)
        .padding(.vertical, 6)
        .onAppear {
            isEditorFocused = true
        }
        .onChange(of: isEditorFocused) { _, focused in
            // 失焦即收尾（点贴条外、切应用前的最后一次点击都算）
            if !focused, note.isEditing {
                actions.endEditing()
            }
        }
    }

    /// 图片贴条：等比铺满，最长边受窗口尺寸约束（窗口尺寸已按图片比例算好）
    @ViewBuilder
    private var imageBody: some View {
        if let image = note.image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(PinnedWindowManager.contentPadding)
        } else {
            Text(L10n.tr("pin.empty_text"))
                .font(.nookClipBody)
                .foregroundStyle(NookClip.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
