import AppKit
import Carbon.HIToolbox
import Observation

// MARK: - 顺序粘贴栈（specs/012-scrub-stack-pin · US2）
//
// 为什么需要这一层：用户要把 N 条记录依次塞进 N 个输入框，最有价值的体验是
// 「回到目标应用后只按原生 ⌘V」，而不是在我们的窗口里反复点。所以队列状态
// 必须独立于面板存活：面板关掉、焦点切走，队列仍然在推进。控制器因此拆成
// 「状态模型（可观察）」+「推进机制（监听 ⌘V / 手控）」+「投影（胶囊窗）」三块，
// 任何一块都不持有另一块的强引用环。

/// 出栈顺序。
///
/// 只用一个 `direction` 表达「索引往哪走」：正序向尾部（+1）、倒序向头部（-1）。
/// 进度指针推进、上一条回退、下一条预告全部复用同一位移，避免每处都写一遍
/// `order == .fifo ? +1 : -1` 而漏掉其中一处。
enum PasteStackOrder: String, Codable, CaseIterable, Sendable {
    case fifo
    case lifo

    /// 索引步进方向
    var direction: Int { self == .fifo ? 1 : -1 }

    /// 按本顺序遍历时的起点：正序从头、倒序从尾
    func startIndex(count: Int) -> Int {
        count <= 0 ? 0 : (self == .fifo ? 0 : count - 1)
    }
}

// MARK: - 建队排序

/// 把用户选中的条目排成「真正的复制顺序」。
///
/// 为什么要单独一个函数：列表是按 `lastUsedAt` **倒序**展示的（刚复制的排最上），
/// 直接拿列表顺序建队列会把顺序整个翻过来——依次复制 A、B、C 后多选启动，
/// 用户期待贴出 A → B → C，实际却贴 C → B → A。而「顺序粘贴」的全部价值就是
/// 「照我复制的顺序来」，所以这里必须显式按时间升序重排。
///
/// 注意与「合并粘贴」的区别：合并成一段文本时顺序应与眼前列表一致（用户是照
/// 列表从上往下选的），两处诉求不同，不能共用同一个取序方法。
enum PasteStackQueue {

    /// 按复制先后（时间升序）排列。
    ///
    /// 时间戳相同时依次用 `createdAt`、`id` 兜底：Swift 的 `sort` 不保证稳定，
    /// 没有确定性兜底会出现「同样的选择两次跑出不同队列」。
    static func inCopyOrder(_ items: [ClipboardItem]) -> [ClipboardItem] {
        items.sorted { lhs, rhs in
            if lhs.lastUsedAt != rhs.lastUsedAt {
                return lhs.lastUsedAt < rhs.lastUsedAt
            }
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}


// MARK: - 队列状态

/// 顺序粘贴栈状态模型。
///
/// 与 `InMemoryHistoryStore` / `ExcludedAppsManager` 同构：Observation 框架
/// `@Observable` + 普通 `var`（不用 `ObservableObject` / `@Published`），
/// SwiftUI 侧直接读属性即可建立依赖。
@MainActor
@Observable
final class PasteStackState {
    /// 队列条目快照（启动时由多选集或录制流写入；停止后清空）
    private(set) var items: [ClipboardItem] = []
    /// 粘贴游标：下一条要装进剪贴板的位置（始终落在 items 合法区间内）。
    ///
    /// 它同时就是浮窗里高亮的那一行——高亮不是「选中」，而是「下一条待粘贴」的
    /// 进度指示：贴完一条自动前移，用户不需要再猜「我点到哪儿了、⌘V 会贴哪条」。
    /// 想跳到某一条就点它，游标跟着走；⌘V 仍从游标继续。
    private(set) var currentIndex: Int = 0
    /// 出栈方向（切换时只翻转 `direction`，队列本身不重排，见 toggleOrder）
    var order: PasteStackOrder = .fifo
    /// 是否实时录制模式（外部连续 ⌘C 直接入队）
    private(set) var isRecording = false
    /// 是否因外部非录制复制而暂停（接线层可置位，胶囊窗据此提示）
    private(set) var isPaused = false
    /// 是否已走完全部条目（胶囊窗据此显示「✓ 已完成」并等待淡出）
    private(set) var isCompleted = false
    /// 已经贴出去的条目 id。
    ///
    /// 为什么需要一个集合而不是只看 `currentIndex`：胶囊窗现在是整段列表，
    /// 用户需要一眼分清「这条贴过了」和「这条还没动」，而指针只能表达「现在到哪」。
    /// 用户用按钮跳着贴（贴第 4 条再回头贴第 2 条）时，指针和完成情况就分家了。
    private(set) var pastedIDs: Set<UUID> = []
    /// 是否开启「🔒 粘完保留（固定托盘模式）」。
    ///
    /// 默认关闭：普通顺序粘贴讲究「贴完就走」，队列空了浮窗自己消失。
    /// 开启后 `remaining == 0` 也不再自动收起——托盘常驻，用户可以反复挑任意一条
    /// 重粘（复制一段地址、来回贴几次这种活，重开一次队列是纯浪费）。
    /// 与 `order` 同属「用户选的模式」，`reset()` 不清它。
    private(set) var keepOpen = false

    // MARK: 派生只读（供胶囊窗与测试读取，不额外存状态）

    /// 当前待粘条目
    var currentItem: ClipboardItem? {
        items.indices.contains(currentIndex) ? items[currentIndex] : nil
    }

    /// 按当前顺序的下一条；无下一条时为 nil（胶囊窗据此换显示）
    var nextItem: ClipboardItem? {
        let next = currentIndex + order.direction
        return items.indices.contains(next) ? items[next] : nil
    }

    /// 展示用进度（1 基）：`2 / 5` 里的 2
    var position: Int { items.isEmpty ? 0 : currentIndex + 1 }

    /// 队列总条数
    var total: Int { items.count }

    /// 还没贴出去的条数（列表里未打勾的行数）
    var remaining: Int { items.reduce(0) { $0 + (pastedIDs.contains($1.id) ? 0 : 1) } }

    /// 某条是否已经贴过（列表行据此画对勾）
    func hasPasted(_ item: ClipboardItem) -> Bool {
        pastedIDs.contains(item.id)
    }

    /// 刚入队的这条，是否恰好就是高亮的那条。
    ///
    /// 用来判断「剪贴板要不要校正」：录制模式下复制动作本身就把系统剪贴板
    /// 换成了刚复制的内容，如果高亮不是它，不校正的话下一次 ⌘V 会跳过还没贴的
    /// 条目直接贴最新那条（依次复制 A、B、C 贴出 C、B、C 的根因）。
    /// 反过来，若高亮就是它，剪贴板已经是正确内容，不该重写——重写会丢掉
    /// 原应用放进去的富文本 / 图片等附加类型。
    func isHighlighted(_ item: ClipboardItem) -> Bool {
        currentItem?.id == item.id
    }

    /// 从 `index` 之后按当前方向找下一条还没贴的条目。
    ///
    /// 高亮的定义是「下一条待粘贴」，所以一条贴出去之后，高亮必须落到
    /// 真正还没贴的那条上，而不是机械地 +1：用户跳着贴（贴第 3 条再贴第 2 条）
    /// 时，+1 很可能踩到一条已经打过勾的行，高亮就变成一句废话。
    ///
    /// 走到头会绕回另一端继续找——只要队列里还有没贴的，高亮就不该停在
    /// 已贴的行上。全部贴完则返回 nil。
    /// 按当前方向，队列里第一条还没贴的条目（高亮的默认落点）
    func firstUnpastedIndex() -> Int? {
        guard !items.isEmpty else { return nil }
        let start = order.startIndex(count: items.count)
        return nextUnpastedIndex(after: start - order.direction)
    }

    func nextUnpastedIndex(after index: Int) -> Int? {
        let count = items.count
        guard count > 0 else { return nil }
        for step in 1...count {
            let raw = index + order.direction * step
            let wrapped = ((raw % count) + count) % count
            if !pastedIDs.contains(items[wrapped].id) {
                return wrapped
            }
        }
        return nil
    }

    // MARK: 变更入口（仅控制器调用）

    func setItems(_ newItems: [ClipboardItem], order: PasteStackOrder) {
        items = newItems
        self.order = order
        // 高亮 = 下一条待粘贴：正序从第一条开始，倒序从最后一条开始。
        // 不写死 0——倒序时第一条该贴的是队尾那条，高亮指向队首只会误导用户。
        currentIndex = order.startIndex(count: newItems.count)
        isCompleted = false
        pastedIDs = []
    }

    /// 移动粘贴游标（只有控制器推进时调）
    func move(to index: Int) {
        guard items.indices.contains(index) else { return }
        currentIndex = index
    }

    /// 记下某条已贴出（装填成功才调，装填失败不打勾，避免假成功）
    func markPasted(_ id: UUID) {
        pastedIDs.insert(id)
    }

    func append(_ item: ClipboardItem) {
        items.append(item)
        isCompleted = false
        // 高亮 = 下一条待粘贴，所以追加只在「高亮失效」时才重新找：
        // 当前这条已经贴过（或队列本来是空的）就退回到第一条没贴的，
        // 否则用户正盯着某条准备贴，新来的内容不该把高亮抢走。
        if !items.indices.contains(currentIndex) || pastedIDs.contains(items[currentIndex].id) {
            currentIndex = firstUnpastedIndex() ?? currentIndex
        }
    }

    func setRecording(_ value: Bool) { isRecording = value }
    func setPaused(_ value: Bool) { isPaused = value }
    func setCompleted(_ value: Bool) { isCompleted = value }

    /// 复位出栈方向（新队列起点一律正序，见 `PasteStackController.start(with:)`）
    func setOrder(_ value: PasteStackOrder) { order = value }

    /// 开关「🔒 粘完保留」。
    ///
    /// 状态层只负责存这个开关；「关掉时要不要补一次收尾」属于生命周期决策，
    /// 放在 `PasteStackController.toggleKeepOpen()` 里做。
    func setKeepOpen(_ value: Bool) {
        keepOpen = value
    }

    func toggleKeepOpen() {
        keepOpen.toggle()
    }

    /// 列表内拖拽重排：把第 `from` 条挪到第 `to` 条的位置。
    ///
    /// **关键不变量：▶ 播放头必须继续跟着「同一条」待粘条目走。**
    /// 拖拽改的是条目顺序，但用户心里正打算贴的那条没变——若只按老下标搬运
    /// `currentIndex`，拖一次高亮就会跳到另一条上，⌘V 贴出来的东西也跟着变，
    /// 是那种「什么都没提示但结果错了」的 bug。所以这里按 id 重新定位。
    /// 越界或原位一律忽略（返回 false 供调用方决定要不要刷新）。
    @discardableResult
    func moveItem(from source: Int, to destination: Int) -> Bool {
        guard items.indices.contains(source),
              items.indices.contains(destination),
              source != destination else { return false }
        // 先记下当前高亮条的 id：重排之后下标全变了，只有 id 稳定
        let highlightedID = currentItem?.id
        let moved = items.remove(at: source)
        items.insert(moved, at: destination)
        if let highlightedID, let index = items.firstIndex(where: { $0.id == highlightedID }) {
            currentIndex = index
        } else {
            // 高亮条理论上不可能消失（只是换了位置），兜底退回第一条未贴的
            currentIndex = firstUnpastedIndex() ?? min(currentIndex, max(items.count - 1, 0))
        }
        return true
    }

    /// 复位状态。`keepOpen` 与 `order` 一样属于「用户选的模式」，跨队列保留——
    /// 用户开了固定托盘，下一条队列不该悄悄变回粘完就消失。
    func reset() {
        items = []
        currentIndex = 0
        isRecording = false
        isPaused = false
        isCompleted = false
        pastedIDs = []
    }
}

// MARK: - 控制器（推进机制）

/// 顺序粘贴栈控制器（方案 C：原生 ⌘V 自动装填 + 胶囊窗手控）。
///
/// 推进原理：队列激活期间监听 ⌘V，命中后延迟 150ms 再把下一条写入剪贴板。
/// 延迟是必须的——键事件先落到目标应用，应用读剪贴板是个异步过程，立刻改
/// 剪贴板会让本次粘贴读到下一条内容（连按两次 ⌘V 只吐出第一条的经典 bug）。
///
/// 写入一律走 `PasteService.copyOnly`：它会给剪贴板打 internalMarker 并刷新
/// `lastInternalChangeCount`，`ClipboardMonitor` 据此跳过入库，所以自动装填
/// 不会在历史里制造重复记录。
@MainActor
final class PasteStackController {
    /// 组合根访问点：与 `ExcludedAppsManager.shared` 同一写法，实例方法全部
    /// 主线程隔离，只在主线程取用
    static let shared = PasteStackController()

    /// 队列状态（胶囊窗直接观察它）
    private(set) var state = PasteStackState()

    /// ⌘V 命中到装填之间的让位窗口：目标应用先取走当前内容
    private static let advanceDelay: TimeInterval = 0.15
    /// 走完队列后「✓ 已完成」的停留时长，之后自动淡出
    private static let completionHold: TimeInterval = 0.8

    /// 胶囊窗（首次展示时才创建，避免应用启动即建窗口）
    private var pillPanel: PasteStackPillPanel?
    /// 面板外 ⌘V 全局监听（需要辅助功能权限才有事件）
    private var globalMonitor: Any?
    /// 应用内 ⌘V 本地监听（返回 event，按键照常生效）
    private var localMonitor: Any?
    /// 待装填的下一条（重复 ⌘V 时只保留最后一次）
    private var pendingAdvance: DispatchWorkItem?
    /// 完成态自动退出
    private var pendingStop: DispatchWorkItem?

    /// 队列是否处于激活态（激活 = 有队列且在推进/录制）
    private(set) var isActive = false

    /// 目标应用（点某行「粘贴」时要把内容真正贴到哪个 App）。
    ///
    /// 不做成控制器内部查 `NSWorkspace.frontmostApplication`：用户点浮窗的瞬间
    /// 前台应用可能已经是我们自己，查出来会贴错地方。接线层（AppDelegate）手里
    /// 有「最近一次外部前台应用」的权威答案，注入进来即可。
    var targetApplicationProvider: (() -> NSRunningApplication?)?

    private init() {}

    // MARK: - 生命周期

    /// 启动队列（多选集送入）：立即把第一条写入剪贴板
    ///
    /// 新队列**一律从正序开始**，不继承上一条队列的倒序。
    /// 曾经这里传的是 `state.order`，而 `order` 跨队列保留：用户上一次顺手点过
    /// 倒序徽标，之后每一条新队列都会默默倒着贴，界面上却没有任何提示——
    /// 这是「顺序粘贴没按复制顺序来」最隐蔽的一个成因。倒序仍然可用，
    /// 但必须是用户在这一条队列里主动切的。
    func start(with items: [ClipboardItem]) {
        guard !items.isEmpty else {
            stop()
            return
        }
        teardownRuntime()
        state.setItems(items, order: .fifo)
        isActive = true
        installEventMonitors()
        presentPill()
        loadCurrentItemToPasteboard()
    }

    /// 启动实时录制：队列从空开始，外部每次复制由接线层 `append(_:)` 追加入队
    ///
    /// 录制同样从正序开始：录制的语义就是「照我复制的顺序贴」，
    /// 继承上一轮的倒序会让队列整个反过来。
    func startRecording() {
        teardownRuntime()
        state.reset()
        state.setOrder(.fifo)
        state.setRecording(true)
        isActive = true
        installEventMonitors()
        presentPill()
    }

    /// 录制追加（接线层在 ClipboardMonitor 捕获到新条目时调用）。
    ///
    /// **关键不变量：队列激活期间，系统剪贴板必须始终装着「高亮的那一条」。**
    ///
    /// 录制模式下用户每复制一次，他自己就把剪贴板换成了刚复制的内容；而高亮
    /// 按设计不会被他抢走（见 `PasteStackState.append(_:)`）。两者一旦分家，
    /// 第一次按 ⌘V 贴出去的就是「最后复制的那条」而不是「高亮的那条」——
    /// 依次复制 A、B、C 会贴出 C、B、C，正是用户反馈的「1、2、3 贴出来 3、2、3」。
    ///
    /// 所以这里分两种情况：
    /// - 高亮恰好就是刚复制的这条（队列本来是空的，或上一条已贴完）：剪贴板
    ///   已经是它了，不用重写——重写反而会丢掉原应用放的富文本/图片类型。
    /// - 高亮停在更早的条目上：说明用户还没贴完前面的，必须把剪贴板换回高亮
    ///   那条，否则 ⌘V 会跳过还没贴的条目直接贴最新那条。
    func append(_ item: ClipboardItem) {
        guard isActive else { return }
        guard state.isRecording else {
            pause()
            return
        }
        //     窗口会随队列变长而长高，行若先画出来再等卡片飞过去，
        //     用户看到的是「凭空多一行 + 一张卡片飞来撞它」，因果是反的。
        pillPanel?.prepareArrival(for: item.id)
        state.append(item)
        state.setPaused(false)
        // 队列变长要立刻把窗口撑高，否则新行会被无边框面板裁掉
        pillPanel?.syncSize()
        // 二、把剪贴板校正回「高亮那条」，见上面的关键不变量
        if !state.isHighlighted(item) {
            loadCurrentItemToPasteboard()
        }
        // 三、卡片从鼠标位置飞向它在列表里的槽位。
        //     起点用 NSEvent.mouseLocation 而不是「当前焦点输入框」：
        //     复制动作发生在别的应用里，我们拿不到那边的光标位置，
        //     而鼠标通常就停在刚复制的那段文字附近——这是最接近「从这里来的」的答案。
        launchArrivalFlight(for: item)
    }

    /// 播放「新条目飞入队列」的动画；没有可用的浮窗或落点时静默跳过。
    ///
    /// 落点分三档：优先精确到那条新行；超过可视行数时列表会自动滚到最新一行，
    /// 那条新行就占着可视区的最后一个槽位，落点按该槽位算；浮窗尚未出现
    /// （`NSApp` 为空的测试环境）则直接放行该行、不做动画。
    private func launchArrivalFlight(for item: ClipboardItem) {
        guard let panel = pillPanel, panel.isVisible else {
            // 没有浮窗就没有落点：立刻放行，避免这一行永远是隐形的
            pillPanel?.completeArrival(for: item.id)
            return
        }
        // 新行在可视区里的槽位：不足一屏时就是它自己的序号，
        // 超过一屏时列表会跟到最后一行，视觉上落在最后一个可见槽位。
        let lastIndex = state.items.count - 1
        let visibleSlot = min(max(lastIndex, 0), PasteStackPillPanel.maxVisibleRows - 1)
        let target = panel.screenRect(forRow: visibleSlot)
            ?? panel.screenRectForListArea()
        guard let target else {
            panel.completeArrival(for: item.id)
            return
        }
        PasteStackFlightOverlay.launch(
            summary: item.fallbackDisplayTitle,
            from: NSEvent.mouseLocation,
            to: target
        ) { [weak self] in
            self?.pillPanel?.completeArrival(for: item.id)
        }
    }

    /// 外部非录制复制造成的干扰：由接线层置位，胶囊窗据此提示暂停
    func pause() {
        guard isActive else { return }
        state.setPaused(true)
    }

    /// 点某行的「粘贴」按钮：把队列里第 `index` 条直接贴出去。
    ///
    /// 与 `advance()` 的区别：不依赖「游标 + 方向」，而是用户指定贴哪条。
    /// 贴完高亮自动落到下一条还没贴的条目上（绕回头部继续找），
    /// 这样「高亮 = 下一条待粘贴」在跳着贴的时候也始终成立。
    /// 对已贴过的行再点一次不算错：用户就是想重贴一遍。
    func pasteItem(at index: Int) {
        guard isActive, state.items.indices.contains(index) else { return }
        let item = state.items[index]
        cancelPendingStop()
        state.setCompleted(false)
        state.setPaused(false)
        // 失败时（没权限）界面上也能看出他点的是哪条
        state.move(to: index)
        // 真实粘贴：写剪贴板 + 激活目标应用 + 模拟 ⌘V。
        // 不再走 loadCurrentItemToPasteboard()——那只是「装填」，按钮的语义是
        // 「现在贴出去」，用户点了就该看到内容落进目标输入框。
        let pasted = PasteService.shared.paste(
            item,
            targetApplication: targetApplicationProvider?(),
            plainTextOnly: false
        )
        guard pasted else {
            // 缺辅助功能权限时 paste 已写剪贴板并弹过授权引导；
            // 这里不改任何状态，避免「界面上打了勾但其实没贴」的假成功
            return
        }
        state.markPasted(item.id)
        // 列表里每条都被点过 = 这一轮结束。录制模式例外：随时可能有新条目进来
        if !state.isRecording, state.remaining == 0 {
            // 固定托盘模式：全部贴完也不收起，留在这儿让用户继续挑着重粘。
            // 剪贴板里此刻就是这条内容，⌘V 自己也能再贴一遍，不用重新装填。
            guard !state.keepOpen else { return }
            markCompleted()
            return
        }
        // 高亮立刻跟到「下一条待粘贴」：用户点完就该看到下一步指向哪，
        // 不能等 250ms 才更新，否则那一瞬间「已贴的第 3 条」还挂着高亮，很怪。
        if let next = state.nextUnpastedIndex(after: index) {
            state.move(to: next)
        }
        // 剪贴板则必须等本次粘贴落地再换：`paste` 只是排了个延时任务，真正的
        // ⌘V 要等 120ms 才发出去。此刻若立刻装填下一条，目标应用读到的就是
        // 下一条内容——点第 3 条却贴出第 1 条的经典错位。
        // 比 ⌘V 路径多留 100ms 余量，覆盖「激活目标应用 + 投递按键」的抖动。
        scheduleLoad(after: Self.advanceDelay + 0.1)
    }

    /// 点某一行本身：只把「下一条待粘贴」挪过去并装填，不真的粘贴。
    ///
    /// 与 `pasteItem(at:)` 分开是手感问题：用户常常要先看一眼再决定贴不贴，
    /// 点一下就往输入框里灌内容太糙。挪完游标后按 ⌘V 或 ⏎ 都能贴这条。
    func jumpToItem(at index: Int) {
        guard isActive, state.items.indices.contains(index) else { return }
        cancelPendingStop()
        state.setCompleted(false)
        state.setPaused(false)
        state.move(to: index)
        loadCurrentItemToPasteboard()
    }

    // MARK: - 推进

    /// 前进一条（仅 ⌘V 命中）：越界即视为走完。浮窗不提供上一/下一条，
    /// 要贴指定某条走 `pasteItem(at:)`。
    ///
    /// 进入这里就说明当前条已经被原生 ⌘V 贴出去了（监听命中后才排队 150ms 调用），
    /// 所以先把当前条记为已贴，再移动指针——列表里的对勾由此而来。
    func advance() {
        guard isActive, !state.isCompleted, !state.isPaused, !state.items.isEmpty else { return }
        if let current = state.currentItem {
            state.markPasted(current.id)
        }
        // 机械 +1 会踩在已打勾的行上，高亮就失去意义
        guard let next = state.nextUnpastedIndex(after: state.currentIndex) else {
            // 录制模式没有「队列走完」的概念：新条目会继续追加，停在原处即可
            guard !state.isRecording else { return }
            // 固定托盘模式同理：全部贴完也留着，用户还要反复重粘。
            //
            // 这里**刻意什么都不做**：若顺手「清掉对勾重开一轮」，用户只是多按了
            // 一次 ⌘V，⌘V 就会突然贴出第一条而不是刚才那条——手还在键上时最危险。
            // 想再来一遍，点某行的重粘、或按 ⌥1~⌥9 挑着贴，动作是明确的。
            guard !state.keepOpen else { return }
            markCompleted()
            return
        }
        state.move(to: next)
        loadCurrentItemToPasteboard()
    }

    /// 切换正序 / 倒序，并按当前条目的 id 立即重定位 + 重新装填。
    ///
    /// 队列本身不重排：条目靠 `id` 定位，翻转的只是「往前走」的方向。
    /// 这样用户切顺序时看到的内容不变（不会突然粘错东西），变的只是下一跳
    /// 落在头侧还是尾侧。找不到当前条目（队列已被外部清空）则回到新顺序起点。
    func toggleOrder() {
        guard isActive else { return }
        state.setOrder(state.order == .fifo ? .lifo : .fifo)
        guard !state.items.isEmpty else { return }
        cancelPendingStop()
        state.setCompleted(false)
        if let currentID = state.currentItem?.id,
           let index = state.items.firstIndex(where: { $0.id == currentID }) {
            state.move(to: index)
        } else {
            state.move(to: state.order.startIndex(count: state.items.count))
        }
        loadCurrentItemToPasteboard()
    }

    /// 退出：拆监听、清队列、收胶囊窗、复位状态（幂等，可重复调用）
    func stop() {
        teardownRuntime()
        isActive = false
        state.reset()
    }

    /// 切换「🔒 粘完保留」。
    ///
    /// 打开时若队列已经全贴完（正处于「✓ 已完成」等待淡出），要立刻撤销那次
    /// 自动退出——用户就是在说「别走」，再把浮窗收掉就成了点了按钮没反应。
    /// 关掉时反过来：已经贴完的话补一次收尾，否则会永远挂着一个本该消失的浮窗。
    func toggleKeepOpen() {
        guard isActive else { return }
        state.toggleKeepOpen()
        guard !state.isRecording, state.remaining == 0 else { return }
        if state.keepOpen {
            cancelPendingStop()
            state.setCompleted(false)
        } else {
            markCompleted()
        }
    }

    /// 列表内拖拽重排（浮窗行视图回调）。
    func moveItem(from source: Int, to destination: Int) {
        guard isActive, state.moveItem(from: source, to: destination) else { return }
        loadCurrentItemToPasteboard()
    }

    // MARK: - 内部：装填与完成

    /// 把当前条目写进系统剪贴板。
    /// 必须经 PasteService（宪法 II：UI 层禁止直调 NSPasteboard）：内部写入
    /// 标记能让 ClipboardMonitor 跳过入库，敏感条目还会顺带挂上自毁定时。
    private func loadCurrentItemToPasteboard() {
        guard let item = state.currentItem else { return }
        _ = PasteService.shared.copyOnly(item, plainTextOnly: false)
    }

    /// 走完队列：先亮 0.8s 完成态，再自动退出（胶囊窗在此期间淡出）
    private func markCompleted() {
        state.setCompleted(true)
        cancelPendingStop()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.stop()
            }
        }
        pendingStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.completionHold, execute: work)
    }

    private func cancelPendingStop() {
        pendingStop?.cancel()
        pendingStop = nil
    }

    // MARK: - 内部：⌘V 监听

    private func installEventMonitors() {
        // 两条通道缺一不可：
        // · 全局通道收「别的应用里按下的 ⌘V / Esc」——方案 C 的主路径，需要辅助功能权限；
        // · 本地通道收「我们自己的窗口里按下的 ⌘V」——无权限时仍可推进。
        // 全局监听收不到发给本进程的事件，所以不会同一次按键触发两遍。
        //
        // 但**自己合成的 ⌘V 会被全局通道收到**：按钮路径调用
        // `PasteService.paste` 会投递一次真实按键事件给前台应用，而全局监听
        // 收的正是「发给别的应用」的按键。不排除的话，点一次「粘贴」会先贴出
        // 这一条、再被自己的按键推一格、还多装填一次剪贴板——用户看到的就是
        // 「顺序乱了 / 漏了一条」。`PasteService.isSyntheticPasteEvent` 用事件
        // userData 标记 + 极短时间窗双重识别。
        guard globalMonitor == nil, localMonitor == nil else { return }
        HotKeyManager.shared.onOrdinalPastePress = { [weak self] index in
            self?.pasteItem(at: index)
        }
        HotKeyManager.shared.registerOrdinalPasteHotKeys()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isPaste = Self.isPasteShortcut(event)
            let isEscape = Self.isEscapeKey(event)
            guard isPaste || isEscape else { return }
            // 自身回环：直接丢弃，不推进也不退出
            if isPaste, PasteService.isSyntheticPasteEvent(event) { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if isPaste {
                        self.scheduleAdvanceAfterPaste()
                    } else {
                        self.stop()
                    }
                }
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // 焦点在我们自己的窗口上时，全局监听收不到事件（它只看发给别的应用的那些），
            // 只剩本地这一条路。所以 Esc 也必须在这里接一次——否则用户开着主面板
            // 想结束队列时，底部提示写着 Esc，按下去却毫无反应。
            if Self.isEscapeKey(event) {
                var handled = false
                MainActor.assumeIsolated {
                    guard let self, self.isActive else { return }
                    self.stop()
                    handled = true
                }
                // 真吞掉：队列已经结束，这个 Esc 不该再顺带关掉面板或清掉筛选条件
                return handled ? nil : event
            }
            // ⌥1~⌥9：直接贴对应序号的条目，并且**必须吞掉按键**。
            // 不吞的话这个组合还会继续落到目标应用里，在输入框打出 ¡ ™ £ 之类的
            // 特殊符号——用户只想贴一条，结果多了一串垃圾字符。
            if let ordinalIndex = Self.ordinalPasteIndex(event) {
                var handled = false
                MainActor.assumeIsolated {
                    guard let self, self.isActive else { return }
                    self.pasteItem(at: ordinalIndex)
                    handled = true
                }
                return handled ? nil : event
            }
            if Self.isPasteShortcut(event), !PasteService.isSyntheticPasteEvent(event) {
                MainActor.assumeIsolated {
                    self?.scheduleAdvanceAfterPaste()
                }
            }
            // 返回 event（不吞按键）：⌘V 仍要落给当前应用完成本次粘贴
            return event
        }
    }

    private func removeEventMonitors() {
        HotKeyManager.shared.unregisterOrdinalPasteHotKeys()
        HotKeyManager.shared.onOrdinalPastePress = nil
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        globalMonitor = nil
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        localMonitor = nil
    }

    private func scheduleAdvanceAfterPaste() {
        scheduleAdvance(after: Self.advanceDelay)
    }

    /// 延后推进队列。`delay` 是「等目标应用把剪贴板读走」的窗口：
    /// `PasteService.paste` 自己在 +120ms 才发出 ⌘V，若我们在那之前换掉
    /// 剪贴板，目标应用读到的就是下一条——点第 3 条贴出第 1 条的错位。
    private func scheduleAdvance(after delay: TimeInterval) {
        guard isActive, !state.isCompleted, !state.isPaused else { return }
        pendingAdvance?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingAdvance = nil
                self?.advance()
            }
        }
        pendingAdvance = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 按钮路径专用：只延后「把下一条装进剪贴板」，不推进游标。
    /// 游标在点按钮那一刻就已经挪到「下一条待粘贴」了，再调 `advance()`
    /// 会把它又往后推一格、并额外静默装填一次。
    private func scheduleLoad(after delay: TimeInterval) {
        guard isActive, !state.isCompleted else { return }
        pendingAdvance?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingAdvance = nil
                self?.loadCurrentItemToPasteboard()
            }
        }
        pendingAdvance = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// ⌥1 ~ ⌥9 判定：按序号直接贴出队列第 1~9 条，返回 0 基下标；不匹配返回 nil。
    ///
    /// 为什么用 ⌥（Option）而不是数字键本体：队列活跃期间用户还在目标应用里打字，
    /// 裸数字必须原样落进去，绝不能吞。⌥+数字在 macOS 上本来就是打特殊符号
    /// （¡ ™ £ …），用户几乎不会在正常输入里用到，代价最小。
    ///
    /// 只认主键盘区（ANSI）的 1–9：小键盘数字有独立的 keyCode，而笔记本用户
    /// 基本只用主键盘区，多接一套只会让判定表变长。
    nonisolated static func ordinalPasteIndex(_ event: NSEvent) -> Int? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // 严格等于 ⌥：⌥⇧1 / ⌘⌥1 是别的东西（系统输入法、第三方快捷键）
        guard flags == .option else { return nil }
        switch Int(event.keyCode) {
        case kVK_ANSI_1: return 0
        case kVK_ANSI_2: return 1
        case kVK_ANSI_3: return 2
        case kVK_ANSI_4: return 3
        case kVK_ANSI_5: return 4
        case kVK_ANSI_6: return 5
        case kVK_ANSI_7: return 6
        case kVK_ANSI_8: return 7
        case kVK_ANSI_9: return 8
        default: return nil
        }
    }

    /// ⌘V 判定：只认「⌘ + V」这一种形态（⌘⇧V / ⌘⌥V 是系统或第三方粘贴快捷键，
    /// 不属于本方案要推进的原生粘贴）
    private nonisolated static func isPasteShortcut(_ event: NSEvent) -> Bool {
        guard event.keyCode == UInt16(kVK_ANSI_V) else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags == .command
    }

    /// Esc 判定：只认不带修饰键的裸 Esc。
    ///
    /// 刻意走全局监听：队列浮窗是 `.nonactivatingPanel`，只为「不抢焦点」而设计，
    /// 显示时并不会成为 key window——只靠窗口内的 `handleKey` 接 Esc，
    /// 用户不看浮窗、焦点还在目标输入框里时按 Esc 就完全没反应，
    /// 而底部提示明明写着「Esc 结束」。这是承诺与实现不一致，必须补上全局通道。
    ///
    /// 代价是：队列活跃期间，在别的应用里按裸 Esc（Vim、关对话框）也会结束队列。
    /// 权衡后接受——这是用户自己开启、会一直挂着的临时模式，退出成本远低于
    /// 「提示写着能退却退不掉」；而且误退只是队列没了，重新 `⌥⏎` / `⌃⌥V` 即可。
    /// 带修饰键的 Esc（⌘⎋ 强制退出、⌥⎋ 等）一律不接管。
    nonisolated static func isEscapeKey(_ event: NSEvent) -> Bool {
        guard event.keyCode == UInt16(kVK_Escape) else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags.isEmpty
    }

    // MARK: - 内部：胶囊窗

    private func presentPill() {
        // 纯 SPM 测试环境没有 NSApplication，不建窗口（队列逻辑仍可被测试驱动）
        guard NSApp != nil else { return }
        makePillPanelIfNeeded().show()
    }

    private func makePillPanelIfNeeded() -> PasteStackPillPanel {
        if let pillPanel {
            return pillPanel
        }
        let panel = PasteStackPillPanel(state: state)
        panel.onToggleOrder = { [weak self] in self?.toggleOrder() }
        panel.onStop = { [weak self] in self?.stop() }
        panel.onPasteItem = { [weak self] index in self?.pasteItem(at: index) }
        panel.onJumpToItem = { [weak self] index in self?.jumpToItem(at: index) }
        panel.onPasteHighlighted = { [weak self] in self?.pasteHighlightedItem() }
        panel.onToggleKeepOpen = { [weak self] in self?.toggleKeepOpen() }
        panel.onMoveItem = { [weak self] source, destination in
            self?.moveItem(from: source, to: destination)
        }
        pillPanel = panel
        return panel
    }

    /// ⏎：贴出高亮那条（也就是「下一条待粘贴」）。
    func pasteHighlightedItem() {
        guard isActive, !state.items.isEmpty else { return }
        pasteItem(at: state.currentIndex)
    }

    // MARK: - 内部：拆机

    /// 拆掉所有运行时资源。监听必须成对 removeMonitor（否则全局监听泄漏后会
    /// 一直拦截系统键盘事件），定时任务必须 cancel（否则停止后仍会推进一拍）
    private func teardownRuntime() {
        removeEventMonitors()
        pendingAdvance?.cancel()
        pendingAdvance = nil
        cancelPendingStop()
        // 飞行中的卡片要一起收掉：队列已结束，还留在屏幕上飞就是孤儿窗口。
        // dismissAll() 会替每一张未落地的卡片调用 completion，把隐形行放行，
        // 否则下次开队列时那些 id 仍挂在 arrivingIDs 里，行会一直不显示。
        PasteStackFlightOverlay.dismissAll()
        pillPanel?.hide()
    }
}
