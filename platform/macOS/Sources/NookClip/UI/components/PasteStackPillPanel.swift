import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

// MARK: - 顺序粘贴栈浮窗（specs/012-scrub-stack-pin · US2 · T009）
//
// 这个窗口的设计目标：用户回到目标应用后能不被打断地按 ⌘V 逐条粘贴，
// 同时**随时看得见整条队列**——贴到第几条、哪几条已经贴过、还剩哪些没贴。
// 因此：
//   · 不能用普通窗口——普通 NSPanel 一 show 就抢走键盘焦点，目标应用就打不了字；
//     `.nonactivatingPanel` + 只 `orderFrontRegardless()` 不 `makeKey` 才能做到
//     「浮在屏幕底部、前台应用仍是它自己」。
//   · 又不能完全不收键盘——用户点一下窗口想按 ⏎ 贴选中行、Esc 退出，所以
//     `canBecomeKey` 必须是 true（点击后成为 key，但不激活本 App）。
//   · 早期版本只显示「当前一条 + 下一条预告」，用户看不到全局、也没法指定贴哪条；
//     现在改成完整列表，每行右侧有「粘贴」按钮，点哪条就贴哪条。
//   · 行数超过 5 条时列表内部滚动，窗口高度封顶——否则一次贴 20 条会挡住半屏。

// MARK: - 出场动画载体

/// 浮窗显隐动画的开关（面板控制、SwiftUI 消费）。
///
/// 为什么单开一个对象而不是把 `isVisible` 塞进 `PasteStackState`：显隐是纯
/// 呈现层状态，队列模型不该知道窗口有没有画出来。面板每次 show/hide 翻转它，
/// SwiftUI 用 `.animation(value:)` 拿到一次干净的 0.16s 补间——
/// 窗口 alphaValue 没做动画，因为反复 show/hide 时窗口级动画会残留半透明帧。
@MainActor
@Observable
final class PasteStackPillPresenter {
    var isVisible = false

    /// 正在「飞来」的条目：飞行卡片还在路上时，列表里对应行先隐形占位。
    ///
    /// 不隐形的话，新行会在卡片起飞的同时凭空出现，用户看到的是「凭空多一行 +
    /// 一张卡片莫名其妙飞过来撞它」，因果读起来是反的。先占位、落点那刻再显形，
    /// 视觉上才是「这张卡片变成了那一行」。
    private(set) var arrivingIDs: Set<UUID> = []

    func isArriving(_ id: UUID) -> Bool { arrivingIDs.contains(id) }

    /// 新行入列，等卡片落地
    func beginArrival(_ id: UUID) { arrivingIDs.insert(id) }

    /// 卡片落地：放行该行（带回弹的淡入由行视图自己做）
    func completeArrival(_ id: UUID) { arrivingIDs.remove(id) }

    func clearArrivals() { arrivingIDs.removeAll() }
}

// MARK: - 面板

/// 不抢焦的顺序粘贴浮窗（340 × 自适应高度，屏幕底部居中）。
///
/// 与 `QuickPopoverController` 同一套搭建方式（NSPanel + 宿主视图），差异只有
/// 三处：无边框、不抢焦点、位置由自己管。
///
/// 位置策略：**用户拖过就记住，没拖过就贴当前屏幕底部居中**。早期版本每次
/// show / 改尺寸都强制回到底部，用户把浮窗挪到顺手的角落，下一轮又被拽回去——
/// 这正是「浮窗要可拖动」的反馈来源。现在只在一个「用户尚未摆过位置」的
/// 状态下自动定位，一旦拖动过就永久尊重用户的选择（跨会话记在 UserDefaults）。
@MainActor
final class PasteStackPillPanel: NSPanel {
    /// 宽度：容得下「序号 + 一句摘要 + 粘贴按钮」三列，再宽就会盖住目标应用输入区
    static let width: CGFloat = 340
    /// 行高：摘要单行 + 上下留白
    static let rowHeight: CGFloat = 26
    /// 行间距：1pt 足够分隔，多了会显得散
    static let rowSpacing: CGFloat = 1
    /// 顶部进度行高
    static let headerHeight: CGFloat = 18
    /// 底部键帽行高
    static let footerHeight: CGFloat = 14
    /// 上下内边距
    static let verticalPadding: CGFloat = 8
    /// 段落间距（进度行 / 列表 / 键帽行之间）
    static let sectionGap: CGFloat = 6
    /// 最多直接显示的行数，超出部分列表内滚动
    static let maxVisibleRows = 5

    /// 距屏幕可见区底部的高度：120pt 是「键盘上方 + 不压 Dock」的经验值
    static let bottomInset: CGFloat = 120
    /// 用户拖出来的位置（屏幕坐标；跨会话保留）。
    /// 缺省即「没拖过」，此时走底部居中。
    private static let originKey = "pasteStack.panelOrigin"
    /// 显隐补间时长（与 SwiftUI 侧 `.easeOut(duration: 0.16)` 保持一致）
    private static let fadeDuration: TimeInterval = 0.16

    var onToggleOrder: (() -> Void)?
    var onStop: (() -> Void)?
    /// 点某一行的「粘贴」按钮：参数是该行在队列里的下标
    var onPasteItem: ((Int) -> Void)?
    /// 点某一行本身：只把「下一条待粘贴」挪过去，不粘任何东西
    var onJumpToItem: ((Int) -> Void)?
    /// ⏎ 贴出高亮那条（即「下一条待粘贴」）
    var onPasteHighlighted: (() -> Void)?

    private let stackState: PasteStackState
    private let presenter = PasteStackPillPresenter()
    /// 浮窗内键盘手控监听（仅可见期间安装）
    private var keyMonitor: Any?
    /// 用户是否已经自己摆过位置（拖过就不再自动贴底居中）
    private var hasUserPlacedWindow = false
    /// 拖动起点（屏幕坐标）与起拖时的窗口原点；nil 表示当前没有在拖
    private var dragAnchor: NSPoint?
    private var dragStartOrigin: NSPoint = .zero
    /// 超过这个位移才算「拖动」，小于它的抖动一律当作点击
    private static let dragThreshold: CGFloat = 3
    /// 记住拖动结束时的位置（`NSWindowDidMoveNotification` 会连尺寸变化一起触发，
    /// 所以只在这两个明确的拖动/缩放时机落盘，避免自动定位也被当成用户意图）
    private var isApplyingProgrammaticFrame = false

    /// 按队列条数算窗口尺寸：行数封顶到 `maxVisibleRows`，再多的部分靠滚动
    static func size(rowCount: Int) -> NSSize {
        let rows = max(1, min(rowCount, maxVisibleRows))
        let listHeight = CGFloat(rows) * rowHeight + CGFloat(rows - 1) * rowSpacing
        let height = verticalPadding * 2 + headerHeight + sectionGap + listHeight + sectionGap + footerHeight
        return NSSize(width: width, height: height.rounded())
    }

    init(state: PasteStackState) {
        self.stackState = state
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size(rowCount: state.items.count)),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        configure()
    }

    // MARK: NSWindow 行为覆写

    /// 必须为 true：用户点浮窗后要能收到 ⏎ / Esc（`.nonactivatingPanel` 保证
    /// 成为 key 的同时不激活本 App，前台应用不会被切走）
    override var canBecomeKey: Bool { true }
    /// 浮窗永远不做 main window，避免参与系统窗口循环
    override var canBecomeMain: Bool { false }

    /// 点一下就取键盘（`.nonactivatingPanel` 保证只取键盘、不激活 App）。
    /// 没有这一步，用户在浮窗上按 ⏎ 会落空——show() 期间我们刻意不 makeKey，
    /// 否则打开队列的一瞬间会把目标应用的输入焦点抢走。
    /// 用 sendEvent 而不是 mouseDown：鼠标事件先派给 SwiftUI 内容视图，
    /// 无边框面板的 mouseDown 根本收不到。
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            if !isKeyWindow {
                makeKey()
            }
            // 记下可能是一次拖动的起点。此时还不移动窗口——用户很可能只是
            // 想点某行的「粘贴」按钮，位移超过阈值才升级成拖动（见
            // `.leftMouseDragged`），否则按钮会变得特别难点。
            dragAnchor = NSEvent.mouseLocation
            dragStartOrigin = frame.origin
        case .leftMouseDragged:
            if let anchor = dragAnchor {
                let current = NSEvent.mouseLocation
                let dx = current.x - anchor.x
                let dy = current.y - anchor.y
                if abs(dx) >= Self.dragThreshold || abs(dy) >= Self.dragThreshold {
                    // 拖动中直接改位置：不经过 applyFrameOrigin 的标记，
                    // 但也不落盘——落盘留到 mouseUp，避免拖动过程写几十次 UserDefaults
                    setFrameOrigin(NSPoint(x: dragStartOrigin.x + dx, y: dragStartOrigin.y + dy))
                    return
                }
            }
        case .leftMouseUp:
            if let anchor = dragAnchor {
                let didMove = abs(NSEvent.mouseLocation.x - anchor.x) >= Self.dragThreshold
                    || abs(NSEvent.mouseLocation.y - anchor.y) >= Self.dragThreshold
                if didMove {
                    hasUserPlacedWindow = true
                    Self.saveOrigin(frame.origin)
                }
            }
            dragAnchor = nil
        default:
            break
        }
        super.sendEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        // 正常情况下本地监听先截获并 return nil，这里只是监听未就绪时的兜底
        if handleKey(event) { return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onStop?()
    }

    // MARK: 展示与收起

    /// 显示浮窗。已可见时只同步尺寸（内容由 Observation 自动刷新），不重置位置。
    func show() {
        installKeyMonitor()
        syncSize()
        if isVisible {
            return
        }
        alphaValue = 1
        // 首次显示必须显式定位：窗口构造时原点在 (0,0)，而 syncSize 只在
        // 尺寸真的变化时才重排位置——队列条数在 show 之前就装好了，尺寸
        // 恰好没变，不补这一句窗口就会停在屏幕左下角
        positionOnScreen()
        // orderFrontRegardless 而非 makeKeyAndOrderFront：不抢键盘焦点，
        // 目标应用继续能输入，⌘V 由控制器的全局监听收走
        orderFrontRegardless()
        presenter.isVisible = true
    }

    /// 队列条数变化时同步窗口高度（录制模式下条目会持续追加）。
    ///
    /// 单独一个方法而不是让 SwiftUI 自己撑开：无边框 NSPanel 不会跟随内容尺寸，
    /// 宿主视图被窗口裁掉的话，新追加的行就永远看不见。
    func syncSize() {
        let target = Self.size(rowCount: stackState.items.count)
        guard target != frame.size else { return }
        // 高度变化时保持左上角不动（AppKit 的 origin 是左下角，直接 setFrame
        // 会让窗口向上生长，视觉上往下坠了一截）
        let top = frame.maxY
        var next = NSRect(origin: frame.origin, size: target)
        next.origin.y = top - target.height
        isApplyingProgrammaticFrame = true
        setFrame(next, display: true)
        isApplyingProgrammaticFrame = false
        // 没被用户摆过时才需要重新贴底居中
        positionOnScreen()
    }

    /// 收起浮窗：先让 SwiftUI 淡出/缩小，窗口随后 orderOut。
    /// 顺序不能反——先 orderOut 会让用户看到硬切消失。
    func hide() {
        removeKeyMonitor()
        presenter.clearArrivals()
        guard isVisible else {
            presenter.isVisible = false
            return
        }
        presenter.isVisible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeDuration) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.presenter.isVisible else { return }
                self.orderOut(nil)
                self.alphaValue = 1
            }
        }
    }

    // MARK: 行定位（飞行动画的落点）

    /// 队列里第 `index` 行的**屏幕矩形**（AppKit 坐标：原点在左下、y 向上）。
    ///
    /// 为什么由浮窗自己算而不是让 SwiftUI 上报：飞行浮层是另一个窗口，它需要的
    /// 是「这一行此刻在屏幕上的绝对位置」。SwiftUI 的 `GeometryReader` 拿到的是
    /// 窗口内坐标，跨窗口还得再换算一次，反而更容易错位。这里直接用本窗口的
    /// `frame` 加上渲染时用的同一组布局常量推出来，两者天然对齐。
    ///
    /// 返回 nil 的两种情况：
    ///   · 窗口还没显示（`isVisible == false`）——此时没有可靠的屏幕位置；
    ///   · 该行被滚动出了可视区——调用方应退化成「落到列表区域」。
    func screenRect(forRow index: Int) -> NSRect? {
        guard isVisible, index >= 0, index < stackState.items.count else { return nil }
        guard index < Self.maxVisibleRows else { return nil }
        let rowStride = Self.rowHeight + Self.rowSpacing
        // 内容从窗口顶部往下排：上内边距 → 进度行 → 段间距 → 列表
        let rowTop = frame.maxY
            - Self.verticalPadding
            - Self.headerHeight
            - Self.sectionGap
            - CGFloat(index) * rowStride
        // 列表区上下各有 10pt 横向内边距，卡片落在内容中央而不是压在边框上
        let inset: CGFloat = 10
        return NSRect(
            x: frame.minX + inset,
            y: rowTop - Self.rowHeight,
            width: frame.width - inset * 2,
            height: Self.rowHeight
        )
    }

    /// 被滚动出可视区时的兜底落点：列表区域中心。
    /// 落在列表上（而不是放弃动画）仍然传达「东西进队列了」这一关键信息。
    func screenRectForListArea() -> NSRect? {
        guard isVisible else { return nil }
        let rows = max(1, min(stackState.items.count, Self.maxVisibleRows))
        let listHeight = CGFloat(rows) * Self.rowHeight + CGFloat(rows - 1) * Self.rowSpacing
        let listTop = frame.maxY - Self.verticalPadding - Self.headerHeight - Self.sectionGap
        return NSRect(x: frame.minX + 10, y: listTop - listHeight, width: frame.width - 20, height: listHeight)
    }

    /// 新条目入队：先让对应行隐形，等飞行卡片落地再显形。
    ///
    /// 调用顺序有讲究——必须在 `syncSize()` **之前**登记隐形，否则窗口先长高、
    /// 新行先画出来，卡片才起飞，因果顺序对不上（用户先看到行、再看到卡片飞过来）。
    func prepareArrival(for id: UUID) {
        presenter.beginArrival(id)
    }

    /// 卡片落地：放行该行并触发落点处的一次强调闪动
    func completeArrival(for id: UUID) {
        presenter.completeArrival(id)
    }

    // MARK: 内部：搭建

    private func configure() {
        // 无边框 + 透明底：圆角、材质全部由 SwiftUI 内容自己画出来，
        // 否则系统会给无边框窗口套一层方角底板
        isOpaque = false
        backgroundColor = .clear
        // 投影交给窗口：系统沿内容真实 alpha 轮廓在窗口**外**绘制。
        // SwiftUI 的 shadow 只能在窗口内画，四角圆角缝隙里会漏出一圈被硬切的灰边
        hasShadow = true
        isFloatingPanel = true
        level = .floating
        // canJoinAllSpaces：切 Space 时浮窗跟着走（用户可能换了桌面继续填表）；
        // fullScreenAuxiliary：全屏应用上也能浮出来
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        // 拖动由本类在 sendEvent 里手动实现（见 beginDrag/dragTo），
        // 因为无边框面板的内容是 NSHostingView，鼠标事件全被 SwiftUI 吃掉，
        // isMovableByWindowBackground 根本不会生效
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        // 关闭系统窗口动画：显隐由 presenter 驱动的 SwiftUI 补间接管，
        // 两套动画叠加会看到「先弹一下再淡出」
        animationBehavior = .none
        // 弹窗式成为 key：点击即取键盘，不要求先激活应用
        becomesKeyOnlyIfNeeded = false

        let hostingView = NSHostingView(
            rootView: PasteStackListContent(
                state: stackState,
                presenter: presenter,
                onToggleOrder: { [weak self] in self?.onToggleOrder?() },
                onStop: { [weak self] in self?.onStop?() },
                onPasteItem: { [weak self] index in self?.onPasteItem?(index) },
                onJumpToItem: { [weak self] index in self?.onJumpToItem?(index) },
                onPasteHighlighted: { [weak self] in self?.onPasteHighlighted?() }
            )
            .nookClipLocalized()
        )
        hostingView.autoresizingMask = [.width, .height]
        hostingView.frame = NSRect(origin: .zero, size: Self.size(rowCount: stackState.items.count))
        contentView = hostingView

    }

    /// 摆放窗口。三种情况按优先级：
    /// 1. 用户拖过 → 用记下的位置（但仍要夹回当前屏幕可见区，副屏拔掉后不至于飞出屏幕）；
    /// 2. 没拖过但有存档 → 当作「用户上次摆过」；
    /// 3. 都没有 → 贴当前屏幕可见区底部居中。
    private func positionOnScreen() {
        if let saved = Self.savedOrigin() {
            hasUserPlacedWindow = true
            moveToSavedOrigin(saved)
            return
        }
        guard !hasUserPlacedWindow else { return }
        centerBottom()
    }

    private func centerBottom() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let x = visible.midX - frame.width / 2
        let y = visible.minY + Self.bottomInset
        applyFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }

    /// 把窗口挪到存档位置，并保证它仍然落在某块屏幕的可见区内。
    /// 不做夹取的话，用户在外接屏上摆好位置、拔线之后浮窗会停在屏幕外，
    /// 表现为「队列还在跑但看不见窗口」——比位置不理想严重得多。
    private func moveToSavedOrigin(_ origin: NSPoint) {
        let target = NSPoint(x: origin.x.rounded(), y: origin.y.rounded())
        if NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -8, dy: -8).contains(target) }) {
            applyFrameOrigin(target)
        } else {
            hasUserPlacedWindow = false
            Self.clearSavedOrigin()
            centerBottom()
        }
    }

    /// 程序化改位置时打标，避免被 `windowDidMove` 记成「用户拖动」
    private func applyFrameOrigin(_ origin: NSPoint) {
        isApplyingProgrammaticFrame = true
        setFrameOrigin(origin)
        isApplyingProgrammaticFrame = false
    }

    private static func savedOrigin() -> NSPoint? {
        guard let raw = UserDefaults.standard.string(forKey: originKey) else { return nil }
        let parts = raw.split(separator: ",")
        guard parts.count == 2,
              let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
        return NSPoint(x: x, y: y)
    }

    private static func saveOrigin(_ origin: NSPoint) {
        UserDefaults.standard.set("\(origin.x),\(origin.y)", forKey: originKey)
    }

    private static func clearSavedOrigin() {
        UserDefaults.standard.removeObject(forKey: originKey)
    }

    // MARK: 内部：键盘手控

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    /// ⏎ 贴选中行 / O 切换正序倒序 / Esc 退出。
    /// 带 ⌘⌥⌃⇧ 的一律放行：那是系统或第三方快捷键，不该被这里吞掉。
    ///
    /// 这里刻意**不接 ↑↓**：顺序粘贴的推进由 ⌘V 自动完成，手动翻页既多余又会
    /// 和「跳过某条」的旧语义纠缠不清。要贴哪条直接点，或者点一下再按 ⏎。
    private func handleKey(_ event: NSEvent) -> Bool {
        // 只有本窗成为 key 时才接管按键：否则用户在我们其它窗口里按 ⏎
        // 会被这里悄悄吞掉（本 App 在队列期间仍可能被唤醒出面板）
        guard isVisible, isKeyWindow else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let commandLike: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        guard flags.isDisjoint(with: commandLike) else { return false }

        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            onPasteHighlighted?()
            return true
        case kVK_Escape:
            onStop?()
            return true
        case kVK_ANSI_O:
            onToggleOrder?()
            return true
        default:
            return false
        }
    }
}

// MARK: - SwiftUI 内容

/// 浮窗内容视图（纯展示，状态全部来自 `PasteStackState`）。
///
/// 布局三段：顶部进度（已贴 / 总数 + 顺序 + 关闭）、中间完整列表、底部键帽提示。
private struct PasteStackListContent: View {
    let state: PasteStackState
    let presenter: PasteStackPillPresenter
    let onToggleOrder: () -> Void
    let onStop: () -> Void
    let onPasteItem: (Int) -> Void
    let onJumpToItem: (Int) -> Void
    let onPasteHighlighted: () -> Void

    /// 录制红点的呼吸相位（onAppear 置 true，靠 repeatForever 动画循环）
    @State private var recordDotPulse = false

    /// 出场补间（只做 opacity + 0.96 缩放，克制且不遮挡背后的内容）
    private static let appearAnimation = Animation.easeOut(duration: 0.16)
    /// 条目切换补间（进度数字滚动替换）
    private static let stepAnimation = Animation.easeOut(duration: 0.16)
    /// 飞行卡片落地、对应行现形时的补间。
    ///
    /// 用 `.spring` 而不是 `easeOut`：卡片是「砸进槽位」的，略微过冲再加一点回弹
    /// 才像被接住；纯线性淡入会显得这张卡片凭空消失、这一行凭空出现，两件事没连上。
    /// 响应速度给得比较快、阻尼偏小，避免在连续复制时拖出一串黏糊糊的余韵。
    private static let rowArrivalAnimation = Animation.spring(response: 0.28, dampingFraction: 0.72)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
                .frame(height: PasteStackPillPanel.headerHeight)
            listBody
                .padding(.top, PasteStackPillPanel.sectionGap)
            footerRow
                .frame(height: PasteStackPillPanel.footerHeight)
                .padding(.top, PasteStackPillPanel.sectionGap)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, PasteStackPillPanel.verticalPadding)
        .frame(
            width: PasteStackPillPanel.width,
            height: PasteStackPillPanel.size(rowCount: state.items.count).height,
            alignment: .topLeading
        )
        // 浮动材质的既有做法：毛玻璃 + 令牌底色 + 发丝边。
        //
        // 这里刻意**不加 SwiftUI 投影**（popover: false）：窗口尺寸与内容严丝合缝，
        // 投影只能画在窗口边界内——直边处被裁得一点不剩，四角的圆角缝隙里却漏进
        // 一圈灰影，又被窗口边缘硬切成直角。观感就是「圆角处有一圈脏边」。
        // 投影交给窗口自己（hasShadow = true），系统沿真实 alpha 轮廓在窗口外画，
        // 不会被裁。与主面板 DraggablePanel 的处理方式一致。
        .nookClipSurface(tint: NookClip.bgPopover, radius: NookClip.radiusPanel, popover: false)
        .scaleEffect(presenter.isVisible ? 1 : 0.96)
        .opacity(presenter.isVisible ? 1 : 0)
        .animation(Self.appearAnimation, value: presenter.isVisible)
    }

    // MARK: 顶部进度

    private var headerRow: some View {
        HStack(spacing: 6) {
            if state.isRecording {
                recordDot
            }
            if state.isCompleted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.nookClip(12, .semibold))
                    .foregroundStyle(NookClip.colorSuccess)
                Text(L10n.tr("scrub.stack.completed"))
                    .font(.nookClipSubheadMedium)
                    .foregroundStyle(NookClip.colorSuccess)
                    .lineLimit(1)
            } else {
                Text(progressText)
                    .font(.nookClipKeycap)
                    .monospacedDigit()
                    .foregroundStyle(NookClip.textSecondary)
                    .lineLimit(1)
                    // 数字位做滚动替换而不是整段跳变：`2 / 5` → `3 / 5` 时只有前一位动
                    .contentTransition(.numericText())
                    .animation(Self.stepAnimation, value: state.pastedIDs.count)
            }
            if state.isPaused, !state.isCompleted {
                Text(L10n.tr("scrub.stack.paused"))
                    .font(.nookClipCaption)
                    .foregroundStyle(NookClip.colorSensitive)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            orderBadge
            closeButton
        }
    }

    /// 录制指示：一个带呼吸感的红点。
    /// 为什么用动画而不是静态圆点——录制态是新条目不断进队的活状态，静态点会被
    /// 误读成「有错误」。0.9s 的循环补间很轻，不抢注意力也不刺眼。
    private var recordDot: some View {
        Circle()
            .fill(NookClip.colorDanger)
            .frame(width: 6, height: 6)
            .opacity(recordDotPulse ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: recordDotPulse)
            .onAppear { recordDotPulse = true }
            .accessibilityHidden(true)
    }

    /// FIFO / LIFO 小胶囊：点击即翻转方向
    private var orderBadge: some View {
        Button(action: onToggleOrder) {
            Text(orderLabel)
                .font(.nookClipBadge)
                .tracking(0.2)
                .foregroundStyle(NookClip.accent)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(height: 16)
                .background {
                    RoundedRectangle(cornerRadius: NookClip.radiusThumb, style: .continuous)
                        .fill(NookClip.bgAccentSubtle)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(L10n.tr("scrub.stack.order_hint"))
        // 不参与压缩：两三个字被截成「顺」等于没写
        .fixedSize()
    }

    private var closeButton: some View {
        Button(action: onStop) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(NookClip.textTertiary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(L10n.tr("scrub.stack.stop_hint"))
        .accessibilityLabel(L10n.tr("scrub.stack.stop_hint"))
        .fixedSize()
    }

    // MARK: 列表

    @ViewBuilder
    private var listBody: some View {
        let rowsHeight = listHeight
        if state.items.isEmpty {
            // 录制模式刚启动：还没有条目进队，给一句明确的等待说明
            Text(L10n.tr("scrub.stack.waiting"))
                .font(.nookClipCaption)
                .foregroundStyle(NookClip.textTertiary)
                .lineLimit(1)
                .frame(height: PasteStackPillPanel.rowHeight)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: PasteStackPillPanel.rowSpacing) {
                        ForEach(Array(state.items.enumerated()), id: \.element.id) { index, item in
                            // 飞行途中的行先隐形占位：卡片落点那刻才显形，
                            // 视觉上才是「这张卡片变成了这一行」，而不是「行先冒出来、卡片飞来撞它」。
                            // `scaleEffect` 从 0.92 起跳，落地时像被轻轻按进槽位。
                            let isArriving = presenter.isArriving(item.id)
                            PasteStackRow(
                                index: index,
                                item: item,
                                isHighlighted: index == state.currentIndex,
                                isPasted: state.hasPasted(item),
                                onJump: { onJumpToItem(index) },
                                onPaste: { onPasteItem(index) }
                            )
                            .opacity(isArriving ? 0 : 1)
                            .scaleEffect(isArriving ? 0.92 : 1, anchor: .center)
                            .animation(isArriving ? nil : Self.rowArrivalAnimation, value: isArriving)
                            .animation(Self.stepAnimation, value: state.currentIndex)
                        }
                    }
                }
                .frame(height: rowsHeight)
                // 条数不多时禁掉滚动，避免出现「能拖但内容不动」的迷惑手感
                .scrollDisabled(state.items.count <= PasteStackPillPanel.maxVisibleRows)
                // 新行入队时列表本身也轻轻让一下：只挪 1pt，够察觉、不干扰阅读
                .animation(Self.stepAnimation, value: state.items.count)
                // 超过可视行数后，新行会落在滚动区外——用户看不到它，
                // 飞行卡片也会因为拿不到行矩形而失去落点。这里主动跟到最新一行，
                // 保证「刚落进去的那条」永远在视野里。
                .onChange(of: state.items.count) { _, newCount in
                    guard newCount > PasteStackPillPanel.maxVisibleRows,
                          let last = state.items.last else { return }
                    // 与飞行时长同步：卡片飞行途中列表已经就位，落地时才不会跳一下
                    withAnimation(Self.stepAnimation) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                // 开始粘贴后要跟着高亮走：高亮代表「下一条待粘贴」，
                // 它被滚出视野就等于用户看不到队列在推进到哪一步了。
                // 与「跟到最新一行」不冲突——粘贴只改高亮、不改条数，两者触发点不同。
                .onChange(of: state.currentIndex) { _, newIndex in
                    guard state.items.indices.contains(newIndex) else { return }
                    withAnimation(Self.stepAnimation) {
                        proxy.scrollTo(state.items[newIndex].id, anchor: .center)
                    }
                }
            }
        }
    }

    private var listHeight: CGFloat {
        let rows = max(1, min(state.items.count, PasteStackPillPanel.maxVisibleRows))
        return CGFloat(rows) * PasteStackPillPanel.rowHeight
            + CGFloat(rows - 1) * PasteStackPillPanel.rowSpacing
    }

    // MARK: 底部键帽

    private var footerRow: some View {
        HStack(spacing: 4) {
            // 只保留真正还能用的键：⏎ 贴选中行、Esc 退出。
            // 上下键已经取消（推进全交给 ⌘V），继续挂着就是教用户按无效键
            if !state.isCompleted, !state.items.isEmpty {
                KbdView(text: "⏎", fontSize: 9)
            }
            KbdView(text: "Esc", fontSize: 9)
            Spacer(minLength: 4)
            Text(footerHint)
                .font(.nookClipCaption)
                .foregroundStyle(NookClip.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(footerHint)
    }

    // MARK: 文案派生

    /// 底部提示随状态切换：完成态不该再说「按 ⌘V 贴下一条」，
    /// 录制空态要告诉用户「去复制吧」——静态文案在这两种状态下都是错的
    private var footerHint: String {
        if state.isCompleted {
            return L10n.tr("scrub.stack.hint_done")
        }
        if state.isRecording, state.items.isEmpty {
            return L10n.tr("scrub.stack.hint_recording")
        }
        return L10n.tr("scrub.stack.hint")
    }

    /// `已贴 2 / 5`：列表模式下「贴了几条」比「现在到第几条」更有意义
    private var progressText: String {
        L10n.tr("scrub.stack.progress", String(state.pastedIDs.count), String(state.total))
    }

    private var orderLabel: String {
        L10n.tr(state.order == .fifo ? "scrub.stack.order_fifo" : "scrub.stack.order_lifo")
    }
}

// MARK: - 单行

/// 队列里的一行：序号（或对勾）+ 摘要 + 粘贴按钮。
///
/// 三态视觉：
///   · 已贴过 → 序号位置换成绿色对勾 + 删除线、标题降到三级色（不再抢占注意力）
///   · 下一条 → 行首一枚强调色 ▶ 播放头 + 序号转强调色 + 标题升到一级色并加半档字重
///   · 其余   → 常态（二级色标题），悬停时给一层中性浅底
///
/// 高亮不是「选中」，是进度指示：⌘V 推进后自动前移，点某行也会挪过去，
/// 用户因此永远不用猜「⌘V 现在会贴哪条」。
///
/// **刻意不用整行强调底色**：整行浅蓝底 + 左侧竖条是 macOS 用来表达「用户选中」的
/// 语法（Finder、各类列表、菜单都这样），而这行是 ⌘V 自己往前跑的——用户没选它，
/// 用选中的样式等于每贴一条都替他改一次选择，还和真正可点击的「选中」互相干扰。
/// 改用播放器的语言（▶ = 正在播 / 下一首）：只看行首一枚小三角，就知道下一个是谁，
/// 强调靠字重与颜色层级，不靠色块。
private struct PasteStackRow: View {
    let index: Int
    let item: ClipboardItem
    let isHighlighted: Bool
    let isPasted: Bool
    let onJump: () -> Void
    let onPaste: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            playhead
                .frame(width: 9)
            marker
                .frame(width: 12, alignment: .trailing)
            Text(item.fallbackDisplayTitle)
                .font(isHighlighted ? .nookClipSubheadMedium : .nookClipSubhead)
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .strikethrough(isPasted, color: NookClip.textTertiary)
            Spacer(minLength: 6)
            pasteButton
        }
        .padding(.leading, 4)
        .padding(.trailing, 3)
        .frame(height: PasteStackPillPanel.rowHeight)
        .background(rowBackground)
        .contentShape(Rectangle())
        // 点行本身只挪高亮，不粘：用户常要先看一眼再决定，误触不该直接往输入框里灌内容
        .onTapGesture { onJump() }
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
    }

    /// 前导播放头：只有「下一条」这一行亮起 ▶，其余行留空。
    ///
    /// 位置固定、宽度不随状态变（不亮时是等宽透明占位），所以标题起点在整列里
    /// 完全对齐——列表滚动时，眼睛可以顺着这条竖线下移，不会因某行多了个图标而错位。
    @ViewBuilder
    private var playhead: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(NookClip.accent)
            .opacity(isHighlighted ? 1 : 0)
            .accessibilityLabel(isHighlighted ? L10n.tr("scrub.stack.next_up") : "")
            .accessibilityHidden(!isHighlighted)
    }

    /// 序号 / 对勾：已贴的换绿色对勾，其余给等宽数字。
    ///
    /// **序号始终保留、不被 ▶ 顶掉**——这是上一版的教训：把序号换成 ▶ 之后
    /// 列表读起来像「▶ ROW-A / 2 ONE / 3 ROW-B」，序号从 2 开头，看着像丢了一条。
    @ViewBuilder
    private var marker: some View {
        if isPasted {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(NookClip.colorSuccess)
        } else {
            Text("\(index + 1)")
                .font(.nookClipKeycap)
                .monospacedDigit()
                .foregroundStyle(isHighlighted ? NookClip.accent : NookClip.textTertiary)
        }
    }

    /// 行内「粘贴」按钮。
    ///
    /// **默认是纯文字，只有悬停该行时才浮出浅色底**：一屏五行就有五个强调色块，
    /// 强调色的稀缺性被自己消耗掉了——眼睛会先看到五块蓝，而不是「▶ 那一条」。
    /// 让按钮退成低对比文字，把唯一的蓝色留给播放头，扫描路径才唯一。
    /// 已贴过的行不再提供这个按钮：再贴一次是可能的诉求，但用 ⌘V 或点行跳转即可，
    /// 让它留在原地只会和删除线、对勾挤在一起。
    @ViewBuilder
    private var pasteButton: some View {
        if !isPasted {
            Button(action: onPaste) {
                Text(L10n.tr("scrub.stack.paste"))
                    .font(.nookClipBadge)
                    .foregroundStyle(isHovering ? NookClip.accent : NookClip.textTertiary)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .frame(height: 18)
                    .background {
                        RoundedRectangle(cornerRadius: NookClip.radiusThumb, style: .continuous)
                            .fill(isHovering ? NookClip.bgAccentSubtle : .clear)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(L10n.tr("scrub.stack.paste_hint"))
            .accessibilityLabel(L10n.tr("scrub.stack.paste_hint", item.fallbackDisplayTitle))
            .fixedSize()
        }
    }

    private var titleColor: Color {
        if isPasted { return NookClip.textTertiary }
        return isHighlighted ? NookClip.textPrimary : NookClip.textSecondary
    }

    @ViewBuilder
    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
            .fill(backgroundFill)
    }

    /// 底色只表达「鼠标在这行」，不再表达「下一条」：
    /// 前者是用户此刻的手势，用中性灰；后者是程序推进的状态，交给 ▶ 与字重。
    /// 两件事各用一套视觉，才不会出现「高亮行和悬停行都变成蓝底、分不清谁是谁」。
    private var backgroundFill: Color {
        isHovering ? NookClip.bgRowHover : .clear
    }
}
