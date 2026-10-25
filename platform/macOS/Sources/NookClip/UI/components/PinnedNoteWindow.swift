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
//   · 必须能退出穿透——点击穿透后窗口收不到任何鼠标事件，只能靠 ⌥⌘P 救回来，
//     因此穿透前留 1.5s 缓冲期（提示语同屏可见，期间点一下即可反悔）。
//
// 与 `PasteStackPillPanel` 同一套搭建方式（NSPanel + NSHostingView），差异在于：
// 贴条是常驻的、可拖拽/缩放/折叠的，还要承载编辑态。

// MARK: - 通知（上限提示 / 穿透恢复提示）

extension Notification.Name {
    /// 贴条达到 12 张上限（`pin` 不再新建）。接线层可监听它弹 toast，
    /// 贴条本身不弹 alert——打断式弹窗会毁掉「不打扰」的产品前提。
    static let pinnedNoteLimitReached = Notification.Name("NookClip.pinnedNoteLimitReached")
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
    /// 贴条尺寸下限（再小就压不住 28pt 头栏 + 12pt 内边距）
    static let minSize = NSSize(width: 200, height: 120)
    /// 折叠态尺寸（只留一行头栏）
    static let collapsedSize = NSSize(width: 220, height: 28)
    /// 右下角缩放手柄热区（正方向）
    static let resizeGripSize: CGFloat = 18
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
        hasShadow = true
        isFloatingPanel = true
        level = .floating
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
    }

    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            if handleKeyDown(event) { return }
        case .leftMouseDown:
            // 右下角缩放：只在手柄热区内接管，其余点击照常交给 SwiftUI
            let point = event.locationInWindow
            if !note.isCollapsed,
               point.x >= frame.width - Self.resizeGripSize,
               point.y <= Self.resizeGripSize {
                handleResize(startEvent: event)
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
            onClose?()
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

    /// 右下角拖拽缩放：顶边锚定（贴条贴在屏幕上方，用户下拉底线时上沿不该跟着动）
    private func handleResize(startEvent: NSEvent) {
        let startFrame = frame
        let startMouse = NSEvent.mouseLocation
        let screenMax = (screen ?? NSScreen.main)?.visibleFrame.size
            ?? NSSize(width: 4096, height: 4096)
        let maxWidth = max(Self.minSize.width, screenMax.width)
        let maxHeight = max(Self.minSize.height, screenMax.height)

        while true {
            guard let next = nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) else { break }
            if next.type == .leftMouseUp { break }

            let current = NSEvent.mouseLocation
            let deltaX = current.x - startMouse.x
            // 鼠标上移（deltaY > 0）= 把下沿往上收 = 高度变小
            let deltaY = current.y - startMouse.y

            var newFrame = startFrame
            newFrame.size.width = min(max(startFrame.width + deltaX, Self.minSize.width), maxWidth)
            newFrame.size.height = min(max(startFrame.height - deltaY, Self.minSize.height), maxHeight)
            newFrame.origin.y = startFrame.maxY - newFrame.size.height
            setFrame(newFrame, display: true)
        }

        // 记住用户手改后的尺寸，折叠再展开时按这个还原
        expandedSize = NSSize(width: frame.width, height: frame.height)
    }
}

// MARK: - 管理器

/// 贴条总线：创建 / 排布 / 收起，以及窗口级的全局监听（⌥⌘P 与 ⌥+滚轮）。
///
/// 为什么把手势放到管理器而不是各面板里：`NSEvent` 本地监听是全进程唯一的
/// 分发口，放面板里会出现「12 个监听器互相抢事件」。管理器只有一份。
@MainActor
@Observable
final class PinnedWindowManager {
    static let shared = PinnedWindowManager()

    /// 同时钉住的上限：12 张是「阶梯排布在 1440pt 宽屏幕上仍不糊成一片」的经验上限
    static let maxPinnedNotes = 12
    /// 文本/代码贴条默认尺寸
    static let defaultSize = NSSize(width: 320, height: 220)
    /// 默认不透明度（留 4% 透底，让用户感知到这是浮层而非文档）
    static let defaultOpacity: Double = 0.96
    /// 不透明度下限 / 上限
    static let minOpacity: Double = 0.20
    static let maxOpacity: Double = 1.0
    /// ⌥+滚轮每档步进
    static let opacityStep: Double = 0.05
    /// 阶梯叠放偏移（右下方向）
    static let ladderStep: CGFloat = 24
    /// 距屏幕可视区右上角的首张贴条留白
    static let ladderInset: CGFloat = 24
    /// 穿透前的缓冲期：提示语同屏可见，期间点一下还能反悔
    static let lockedHintDuration: TimeInterval = 1.5
    /// 贴条内容内边距（正文四周；图片贴条也按它留白）
    static let contentPadding: CGFloat = 12
    /// 单行头栏高度
    static let headerHeight: CGFloat = 28

    /// 活跃贴条（顺序即创建顺序，阶梯排布按它算索引）
    private(set) var notes: [PinnedNoteModel] = []

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
    /// ⌥⌘P（全局：贴条穿透后焦点在别的应用，只能靠全局监听救回来）
    @ObservationIgnored private var globalKeyMonitor: Any?
    /// ⌥+滚轮调不透明度
    @ObservationIgnored private var scrollMonitor: Any?

    var pinnedCount: Int { notes.count }
    var isAtCapacity: Bool { notes.count >= Self.maxPinnedNotes }

    private init() {}

    // MARK: - 创建 / 关闭

    /// 从剪贴板条目钉一张贴条。
    /// 已达上限时不新建、不弹框，只广播通知（产品前提：这个动作永远不能打断用户）。
    func pin(item: ClipboardItem) {
        installEventMonitors()

        guard !isAtCapacity else {
            NotificationCenter.default.post(
                name: .pinnedNoteLimitReached,
                object: self,
                userInfo: ["limit": Self.maxPinnedNotes]
            )
            return
        }

        let resolved = Self.resolveText(for: item)
        let imageData = item.type == .image
            ? item.payloadPath.flatMap { FileStore.shared.load(path: $0) }
            : nil

        let note = PinnedNoteModel(
            sourceItemId: item.id.uuidString,
            itemType: item.type,
            sourceAppName: item.sourceAppName,
            editableText: resolved.text,
            originalText: resolved.text,
            imageData: imageData,
            ocrText: item.ocrText,
            isCode: item.persistedKind == "code",
            isDegraded: resolved.degraded
        )

        let size = Self.initialNoteSize(for: note)
        let origin = nextLadderOrigin(for: size)
        let panel = PinnedNotePanel(note: note, contentSize: size)
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
        pendingClickThrough[id]?.cancel()
        pendingClickThrough[id] = nil
        panel.orderOut(nil)
        panel.contentView = nil
        notes.removeAll { $0.id == id }
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
        if note.isCollapsed {
            panel.expandedSize = frame.size
            frame.size = PinnedNotePanel.collapsedSize
        } else {
            // 折叠期间用户可能动过屏幕，还原时仍要卡在可视区内
            let target = NSSize(
                width: max(PinnedNotePanel.minSize.width, panel.expandedSize.width),
                height: max(PinnedNotePanel.minSize.height, panel.expandedSize.height)
            )
            frame.size = clampedSize(target)
        }
        frame.origin.y = panel.frame.maxY - frame.size.height
        frame.origin.x = min(max(frame.origin.x, 0), max(0, screenVisibleFrame.maxX - frame.size.width))
        panel.setFrame(frame, display: true, animate: true)
    }

    /// 点击穿透开关。
    /// 开启时**不立刻**设 `ignoresMouseEvents`：先给 1.5s 缓冲，让「按 ⌥⌘P 恢复」
    /// 的提示同屏可见，用户误点时还能点回来；缓冲结束才真正穿透。
    func toggleClickThrough(_ note: PinnedNoteModel) {
        guard let panel = panels[note.id] else { return }

        if note.isClickThrough {
            cancelPendingClickThrough(note.id)
            note.isClickThrough = false
            panel.ignoresMouseEvents = false
            return
        }

        note.isClickThrough = true
        cancelPendingClickThrough(note.id)
        let work = DispatchWorkItem { [weak self, weak panel] in
            guard let self, let panel, panel.note.isClickThrough else { return }
            panel.ignoresMouseEvents = true
            self.pendingClickThrough[note.id] = nil
        }
        pendingClickThrough[note.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lockedHintDuration, execute: work)
    }

    /// 恢复所有穿透贴条为可交互（⌥⌘P / 接线层托盘菜单共用）。
    /// 穿透后贴条收不到任何鼠标事件，这是唯一出口——所以监听必须常驻。
    func restoreAllClickThrough() {
        for (id, panel) in panels {
            cancelPendingClickThrough(id)
            panel.note.isClickThrough = false
            panel.ignoresMouseEvents = false
        }
    }

    /// 不透明度（滑块 / ⌥+滚轮共用；钳制在 20%~100%）
    func setOpacity(_ note: PinnedNoteModel, to value: Double) {
        let clamped = min(Self.maxOpacity, max(Self.minOpacity, value))
        note.opacity = clamped
        panels[note.id]?.alphaValue = clamped
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
        }

        let actions = PinnedNoteActions(
            close: { [weak self] in self?.unpin(id: note.id) },
            copy: { text in
                // 剪贴板写入统一走 PasteService（内部标记 + 敏感自毁调度都在它那里）
                _ = PasteService.shared.copyText(text, containsSensitive: note.isDegraded)
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
            beginEditing: { [weak note] in note?.isEditing = true },
            endEditing: { [weak note] in note?.isEditing = false },
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

    // MARK: - 阶梯排布

    /// 新贴条位置：以屏幕右上角为起点，第 n 张向右下偏移 24pt；
    /// 越界回绕到起点重新叠，落点被占用时继续沿阶梯找下一个空位。
    private func nextLadderOrigin(for size: NSSize) -> NSPoint {
        let visible = screenVisibleFrame
        let baseX = visible.maxX - size.width - Self.ladderInset
        let baseY = visible.maxY - size.height - Self.ladderInset

        // 向右 / 向下各还能走几步（取小值作为回绕长度）
        let stepsRight = Int(((visible.maxX - size.width) - baseX) / Self.ladderStep)
        let stepsDown = Int((baseY - visible.minY) / Self.ladderStep)
        let wrapCount = max(1, min(stepsRight, stepsDown) + 1)

        var index = notes.count % wrapCount
        var probe = 0
        while probe < wrapCount {
            let candidate = NSRect(
                x: baseX + CGFloat(index) * Self.ladderStep,
                y: baseY - CGFloat(index) * Self.ladderStep,
                width: size.width,
                height: size.height
            )
            let occupied = panels.values.contains { $0.frame.intersects(candidate) }
            if !occupied {
                return NSPoint(x: candidate.origin.x.rounded(), y: candidate.origin.y.rounded())
            }
            index = (index + 1) % wrapCount
            probe += 1
        }
        // 全占满：回到起点直接叠（用户看得见新贴条比"拒绝创建"重要）
        return NSPoint(x: baseX.rounded(), y: baseY.rounded())
    }

    private var screenVisibleFrame: NSRect {
        (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// 初始尺寸：文本/代码 320×220；图片按等比缩放，最长边不超过 480。
    /// 图片贴条要把头栏与内边距算进去，否则图片会被压成一条缝。
    private static func initialNoteSize(for note: PinnedNoteModel) -> NSSize {
        guard let image = note.image, image.size.width > 0, image.size.height > 0 else {
            return defaultSize
        }
        let maxContentWidth = PinnedNotePanel.imageMaxSide - contentPadding * 2
        let maxContentHeight = PinnedNotePanel.imageMaxSide - headerHeight - contentPadding * 2
        let scale = min(1, min(maxContentWidth / image.size.width, maxContentHeight / image.size.height))
        let width = max(
            PinnedNotePanel.minSize.width,
            (image.size.width * scale + contentPadding * 2).rounded()
        )
        let height = max(
            PinnedNotePanel.minSize.height,
            (image.size.height * scale + headerHeight + contentPadding * 2).rounded()
        )
        return NSSize(
            width: min(width, PinnedNotePanel.imageMaxSide),
            height: min(height, PinnedNotePanel.imageMaxSide)
        )
    }

    private func clampedSize(_ size: NSSize) -> NSSize {
        let visible = screenVisibleFrame.size
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

    // MARK: - 全局监听

    /// 安装进程级监听（只装一次；`NSEvent` 本地监听是全进程唯一分发口）。
    private func installEventMonitors() {
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard let self else { return event }
                return self.handleGlobalKey(event) ? nil : event
            }
        }
        if globalKeyMonitor == nil {
            // 贴条穿透后焦点在别的应用，本地监听收不到事件：只能靠全局监听兜底。
            // 全局监听需要辅助功能权限；没权限时系统静默不投递（不影响本地路径）。
            globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    _ = self?.handleGlobalKey(event)
                }
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
        .overlay {
            cardShape.strokeBorder(NookClip.borderHairline, lineWidth: 1)
        }
        // 柔和投影：窗口本身也开了 hasShadow，两层叠加后是「纸上有一点点浮起」
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .overlay(alignment: .bottom) { bottomHintPill }
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

    // MARK: 头栏（28pt：来源 + 类型徽标 + 控制条）

    private var headerBar: some View {
        HStack(spacing: 6) {
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
            }
            Spacer(minLength: 4)
            controlBar
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)
        }
        .padding(.horizontal, 10)
        .frame(height: PinnedWindowManager.headerHeight)
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
            return note.isCode ? L10n.tr("preview.code_fallback") : L10n.tr("item.type_text")
        case .image:
            return L10n.tr("item.type_image")
        case .file:
            return L10n.tr("item.type_file")
        case .url:
            return L10n.tr("category.link")
        }
    }

    private var controlBar: some View {
        HStack(spacing: 2) {
            if !note.isCollapsed, note.itemType != .image {
                iconButton("doc.on.doc", help: L10n.tr("pin.copy")) {
                    actions.copy(note.editableText)
                }
                iconButton("tray.and.arrow.down", help: L10n.tr("pin.save_to_history")) {
                    actions.saveToHistory()
                }
            }
            if !note.isCollapsed, note.itemType == .image,
               let ocr = note.ocrText, !ocr.isEmpty {
                iconButton("text.viewfinder", help: L10n.tr("pin.copy_ocr")) {
                    actions.copyOCR(ocr)
                }
            }
            if !note.isCollapsed {
                opacitySlider
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

    /// 不透明度滑块：20%~100%（拖动即时生效）
    private var opacitySlider: some View {
        Slider(
            value: Binding(
                get: { note.opacity },
                set: { actions.setOpacity($0) }
            ),
            in: PinnedWindowManager.minOpacity...PinnedWindowManager.maxOpacity
        )
        .controlSize(.mini)
        .frame(width: 52, height: 18)
        .tint(NookClip.textTertiary)
        .help(L10n.tr("pin.opacity"))
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
                Text(L10n.tr("pin.locked_hint"))
                    .font(.nookClipCaption)
                    .foregroundStyle(NookClip.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule(style: .continuous).fill(NookClip.bgInset))
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
        } else {
            textBody
        }
    }

    /// 文本正文：双击进入编辑态（Scratchpad）。行距略放宽，长段落才好读
    private var textBody: some View {
        ScrollView(.vertical, showsIndicators: false) {
            Text(note.editableText.isEmpty ? L10n.tr("pin.empty_text") : note.editableText)
                .font(note.isCode ? .nookClipCode : .nookClipBody)
                .foregroundStyle(note.editableText.isEmpty ? NookClip.textTertiary : NookClip.textPrimary)
                .lineSpacing(note.isCode ? 2 : 3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(PinnedWindowManager.contentPadding)
        }
        .background {
            // 代码贴条垫一层极淡的代码底（令牌色，不抢正文）
            if note.isCode {
                RoundedRectangle(cornerRadius: NookClip.radiusCard, style: .continuous)
                    .fill(NookClip.bgCode)
                    .padding(8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            actions.beginEditing()
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
