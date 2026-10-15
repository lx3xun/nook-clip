import AppKit
import Carbon.HIToolbox
import SwiftUI

/// 面板几何常量（数值与重构前逐项一致，集中单一来源）
enum PanelGeometry {
    /// 展开态（双栏）最小宽度
    static let expandedMinWidth: CGFloat = 580
    /// 展开态最大宽度
    static let expandedMaxWidth: CGFloat = 1400
    /// 展开态缺省宽度（无记录时）
    static let expandedDefaultWidth: CGFloat = 750
    /// 折叠态（纯列表）最大宽度
    static let collapsedMaxWidth: CGFloat = 600
    /// 折叠态宽度下限（拖拽记录入库的判定下界）
    static let collapsedMinWidthFloor: CGFloat = 340
    /// 面板高度下限（正好完整展示 10 条数据：顶栏 78 + 顶部锚点 1 + 组头 24 + 10×50 行 + 底栏 22）
    static let minHeight: CGFloat = 625
    /// 面板高度上限
    static let maxHeight: CGFloat = 900
    /// 外部点击/切换应用判定的边缘容差热区（含阴影及外扩边缘）：
    /// 用户抓取边框调整大小时，鼠标点落在窗口外侧数像素也绝不被当成外部点击
    static let outsideClickTolerance: CGFloat = 28
}

/// 短时自动复位标志（0.6s 保持窗口 / 拖动缩放守卫）：
/// 置位后经 duration 自动复位；重复置位取消先前的复位定时（最后一次置位
/// 决定复位时刻）——拖拽/缩放持续数秒时循环内续期才能保持标志有效
///（原「最早定时生效」语义下续期无效，守卫在 0.15s 后即失效，审计 BUG-048）
final class AutoResetFlag {
    private(set) var isActive = false
    private var resetWorkItem: DispatchWorkItem?

    func set(for duration: TimeInterval) {
        isActive = true
        resetWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.isActive = false
        }
        resetWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func reset() {
        isActive = false
        resetWorkItem?.cancel()
        resetWorkItem = nil
    }
}

final class DraggablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    private(set) var hasKeyFocus = false

    override func makeKey() {
        hasKeyFocus = true
        super.makeKey()
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        hasKeyFocus = true
        super.makeKeyAndOrderFront(sender)
    }

    override func resignKey() {
        hasKeyFocus = false
        super.resignKey()
    }

    override func orderOut(_ sender: Any?) {
        hasKeyFocus = false
        super.orderOut(sender)
    }
    /// 全局点击监听、同步生命周期状态）——直接 orderOut 会绕过清理，
    /// 监听器残留持续拦截系统鼠标事件（审计 BUG-043）
    var onCancel: (() -> Void)?
    /// 键盘主循环动作表（MainView onAppear 经 QuickPopoverController 注入）。
    /// 注入前面板按键全部走响应链（仅面板创建到首帧的窗口期）
    var keyActions: PanelKeyActions?

    /// 预览复制等动作发出的焦点归还通知监听（见 restoreKeyboardFocus）
    private var keyboardFocusObserver: Any?

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        keyboardFocusObserver = NotificationCenter.default.addObserver(
            forName: .restoreKeyboardFocus, object: nil, queue: .main
        ) { [weak self] _ in
            self?.restoreKeyboardFocus()
        }
    }

    deinit {
        if let keyboardFocusObserver {
            NotificationCenter.default.removeObserver(keyboardFocusObserver)
        }
    }


    private let resizingFlag = AutoResetFlag()
    private let draggingFlag = AutoResetFlag()

    /// 缩放进行中（外部点击/切应用关闭守卫用）
    var isResizing: Bool { resizingFlag.isActive }
    /// 拖动进行中（外部点击/切应用关闭守卫用）
    var isDragging: Bool { draggingFlag.isActive }

    override func cancelOperation(_ sender: Any?) {
        if let onCancel {
            onCancel()
        } else {
            orderOut(nil)
        }
    }
    override func selectKeyView(preceding view: NSView) {
        // 禁用 Tab 焦点循环导航，防止在面板各按钮/控件间游走留下高亮焦点环
    }

    override func selectKeyView(following view: NSView) {
        // 禁用 Tab 焦点循环导航，防止在面板各按钮/控件间游走留下高亮焦点环
    }

    override func selectNextKeyView(_ sender: Any?) {
        // 禁用 Tab 键聚焦下一个控件
    }

    override func selectPreviousKeyView(_ sender: Any?) {
        // 禁用 Shift+Tab 键聚焦上一个控件
    }
    // 高度钳制统一使用 PanelGeometry.minHeight/maxHeight（625~900）：
    // 私有 400/1200 与控制器 min/maxSize 冲突（审计 BUG-039）
    private let borderMargin: CGFloat = 12
    private let cornerMargin: CGFloat = 20
    var currentMinPanelWidth: CGFloat = PanelGeometry.expandedMinWidth
    var currentMaxPanelWidth: CGFloat = PanelGeometry.expandedMaxWidth

    var maxAllowedWidth: CGFloat {
        currentMaxPanelWidth
    }
    enum ResizeDirection: Equatable {
        case left
        case right
        case top
        case bottom
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight

        /// 涉及水平缩放（左右缘及四角）
        var affectsWidth: Bool {
            switch self {
            case .left, .right, .topLeft, .topRight, .bottomLeft, .bottomRight: return true
            case .top, .bottom: return false
            }
        }

        /// 涉及垂直缩放（上下缘及四角）
        var affectsHeight: Bool {
            switch self {
            case .top, .bottom, .topLeft, .topRight, .bottomLeft, .bottomRight: return true
            case .left, .right: return false
            }
        }

        /// 拖右缘（左缘锚定不动）
        var anchorsLeft: Bool {
            self == .right || self == .topRight || self == .bottomRight
        }

        /// 拖顶缘（底缘锚定不动）
        var anchorsBottom: Bool {
            self == .top || self == .topLeft || self == .topRight
        }
    }

    private var nwseCursor: NSCursor {
        let sel = Selector(("_windowResizeNorthWestSouthEastCursor"))
        if NSCursor.responds(to: sel), let cursor = NSCursor.perform(sel)?.takeUnretainedValue() as? NSCursor {
            return cursor
        }
        return .arrow
    }

    private var neswCursor: NSCursor {
        let sel = Selector(("_windowResizeNorthEastSouthWestCursor"))
        if NSCursor.responds(to: sel), let cursor = NSCursor.perform(sel)?.takeUnretainedValue() as? NSCursor {
            return cursor
        }
        return .arrow
    }

    private var isResizeCursorActive = false

    func resizeDirection(at point: NSPoint) -> ResizeDirection? {
        let nearLeft = point.x <= borderMargin
        let nearRight = point.x >= frame.width - borderMargin
        let nearBottom = point.y <= borderMargin
        let nearTop = point.y >= frame.height - borderMargin

        let cornerLeft = point.x <= cornerMargin
        let cornerRight = point.x >= frame.width - cornerMargin
        let cornerBottom = point.y <= cornerMargin
        let cornerTop = point.y >= frame.height - cornerMargin

        // 优先判断角部
        if cornerRight && cornerBottom {
            return .bottomRight
        }
        if cornerLeft && cornerBottom {
            return .bottomLeft
        }
        if cornerRight && cornerTop {
            return .topRight
        }
        if cornerLeft && cornerTop {
            return .topLeft
        }

        // 判断边缘
        if nearRight {
            return .right
        }
        if nearBottom {
            return .bottom
        }
        if nearLeft {
            return .left
        }
        if nearTop {
            return .top
        }

        return nil
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .mouseMoved {
            let point = event.locationInWindow
            if !isInteractiveArea(at: point), let direction = resizeDirection(at: point) {
                switch direction {
                case .right, .left:
                    NSCursor.resizeLeftRight.set()
                case .bottom, .top:
                    NSCursor.resizeUpDown.set()
                case .bottomRight, .topLeft:
                    nwseCursor.set()
                case .bottomLeft, .topRight:
                    neswCursor.set()
                }
                isResizeCursorActive = true
            } else if isResizeCursorActive {
                NSCursor.arrow.set()
                isResizeCursorActive = false
            }
            super.sendEvent(event)
            return
        }
        if event.type == .keyDown, let actions = keyActions,
           dispatchKeyboardEvent(event, actions: actions) {
            return
        }

        guard event.type == .leftMouseDown else {
            super.sendEvent(event)
            return
        }

        let point = event.locationInWindow

        // 点击搜索框以外的区域时，取消搜索框的焦点状态。
        // 但点击落在可选中文本上（预览区 .textSelection 的 NSTextView）时不抢焦点：
        // 抢焦点会在 super.sendEvent 分发前打断选择，导致预览文本无法选中复制
        if !isSearchBarArea(at: point),
           isSelectableTextResponder(firstResponder),
           !hitSelectableText(at: point) {
            makeFirstResponder(nil)
        }
        // 1. 交互控件区域（搜索框及清除按钮、时间轨、右上角切换按钮等）优先正常分发事件，严禁拦截为窗口缩放拖动
        if isInteractiveArea(at: point) {
            super.sendEvent(event)
            return
        }

        // 2. 边框及角部拖动改变整个窗口大小
        if let direction = resizeDirection(at: point) {
            handleResize(direction: direction, startEvent: event)
            return
        }

        // 3. 顶部标题栏非交互区域拖动窗口位置
        if isHeaderDragArea(at: point) {
            // 拖动持续期间持续续期守卫；结束后保持 0.5s（与缩放同策略，审计 BUG-048）
            draggingFlag.set(for: 0.15)
            performDrag(with: event)
            draggingFlag.set(for: 0.5)
            return
        }
        super.sendEvent(event)
    }

    // MARK: 键盘主循环分发表（contracts C3 全表 · 单一事实来源）

    /// 面板内快捷键统一分发（原 SwiftUI 根视图 onKeyPress + 窗口层拦截 +
    /// 搜索框转发的三层合并）。按物理键位 + 修饰符匹配，焦点不再是前置
    /// 条件——面板收到 keyDown 即分发，任何文本视图持焦都不会令快捷键
    /// 静默失效（原「上下键时好时坏」类问题的根因）。
    /// 上下文由第一响应者判定：
    /// - 行内重命名编辑器：全部交给输入框（⏎ 提交 / Esc 放弃在 RowRenameField）
    /// - 预览可选中文本：水平选择键/⌘A 放行，⌘C 原生复制后归还焦点，
    ///   其余键归还焦点后按列表态同步重入分发（不再异步重投递事件）
    /// - 搜索框编辑器：⌘C/⌘R/⌘方向键放行（文本编辑语义），其余同列表态
    /// - 列表态（无文本编辑器持焦）：完整键表 + 打字即搜索
    /// 返回 true = 已消费（不进入响应链）。
    @discardableResult
    func dispatchKeyboardEvent(
        _ event: NSEvent,
        actions: PanelKeyActions,
        allowPreviewRefocus: Bool = true
    ) -> Bool {
        let responder = firstResponder

        // 输入法（IME）组字态（如中文拼音/日文候选）：按键由输入法消费，不得拦截
        if let client = responder as? (any NSTextInputClient), client.hasMarkedText() {
            return false
        }

        // 行内重命名编辑态 或 详情区可编辑文本编辑器（如未来的笔记/待办正文编辑）：
        // 按键全部交给编辑器自身处理，不被列表快捷键或打字即搜索抢占
        if let responder, isListColumnFieldEditor(responder) || isPreviewEditableTextResponder(responder) {
            return false
        }
        let isSearchFocused = (responder as? NSView).map { isSearchFieldEditor($0) } ?? false
        // 预览可选中文本持焦：除文本选择键外，先归还焦点再按列表态分发
        if let responder, isPreviewSelectableTextResponder(responder) {
            let previewModifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
            let previewCode = Int(event.keyCode)
            let isSelectionEdit = previewCode == kVK_LeftArrow || previewCode == kVK_RightArrow
                || (previewModifiers == .command && event.charactersIgnoringModifiers?.lowercased() == "a")
            if !isSelectionEdit {
                if previewModifiers == .command && previewCode == kVK_ANSI_C {
                    super.sendEvent(event)
                    restoreKeyboardFocus()
                    return true
                }
                guard allowPreviewRefocus else { return false }
                restoreKeyboardFocus()
                // 焦点已归还，同步重入：此时按列表/搜索态分发本次按键
                return dispatchKeyboardEvent(event, actions: actions, allowPreviewRefocus: false)
            }
            return false
        }

        // 仅提取关心的四个基础修饰符（消除 Caps Lock 开启导致全等匹配脱靶的缺陷）
        let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let keyCode = Int(event.keyCode)

        // ⌘F：聚焦搜索框
        if modifiers == .command && keyCode == kVK_ANSI_F {
            actions.focusSearch()
            return true
        }

        // ⌘[ / ⌘]：分类循环（⌘[ 上一个，⌘] 下一个）
        if modifiers == .command, (keyCode == kVK_ANSI_LeftBracket || keyCode == kVK_ANSI_RightBracket) {
            actions.cycleCategory(keyCode == kVK_ANSI_LeftBracket ? -1 : 1)
            return true
        }

        // ↑/↓：⌘↑ 与搜索态 ⌘方向键交还（文本编辑语义：光标移行首/行尾）；
        // 搜索态 ⌥/⌃ 方向键交还（文本编辑语义：光标跳段/跳行）
        if keyCode == kVK_UpArrow {
            if modifiers.contains(.command) || (isSearchFocused && (modifiers.contains(.option) || modifiers.contains(.control))) {
                return false
            }
            actions.arrow(-1, modifiers.contains(.shift))
            return true
        }
        if keyCode == kVK_DownArrow {
            if modifiers.contains(.command) {
                // ⌘↓：开合分类下拉（⇧ 组合交还系统；搜索态交还光标移动）
                if !modifiers.contains(.shift), !isSearchFocused {
                    actions.toggleCategoryMenu()
                    return true
                }
                return false
            }
            if isSearchFocused && (modifiers.contains(.option) || modifiers.contains(.control)) {
                return false
            }
            actions.arrow(1, modifiers.contains(.shift))
            return true
        }

        // 以下按键不响应按住自动重复（与原 onKeyPress phases: .down 一致）
        guard !event.isARepeat else { return false }

        // ⏎（含小键盘 ⏎）：⌘ 保持面板打开 / ⌥ 纯文本粘贴
        if keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter {
            actions.confirm(modifiers.contains(.command), modifiers.contains(.option))
            return true
        }

        // Esc：分层清空。⌘/⌃ 组合形态放行（⌥⌘Esc 强退等系统/辅助快捷键
        // 不在面板拦截范围），⌥/无修饰照常触发
        if keyCode == kVK_Escape,
           !modifiers.contains(.command), !modifiers.contains(.control) {
            actions.escape()
            return true
        }


        // ⌘⌫ / ⌘⌦：删除选中（前向删除键同 ⌫；搜索态交还输入框：macOS 文本
        // 编辑语义「删除到行首」，避免误删历史条目）
        if keyCode == kVK_Delete || keyCode == kVK_ForwardDelete, modifiers.contains(.command) {
            if !isSearchFocused {
                actions.deleteSelection()
                return true
            }
            return false
        }

        // ⌘ 字母动作：物理键位匹配（⌘⌥ 组合同效——非 US 布局不丢键，
        // 原字符匹配的 "ß" 特例不再需要）；⇧/⌃ 组合交还系统。
        // 搜索态 ⌘C/⌘R/⌘Z 归输入框（复制选中文本 / 避免输入误触重命名 / 撤销文本输入）
        if modifiers == .command || modifiers == [.command, .option] {
            switch keyCode {
            case kVK_ANSI_C:
                if !isSearchFocused {
                    actions.copySelection()
                    return true
                }
            case kVK_ANSI_R:
                if !isSearchFocused {
                    actions.beginRename()
                    return true
                }
            case kVK_ANSI_S:
                actions.toggleFavorite()
                return true
            case kVK_ANSI_T:
                actions.cycleTimeAnchor()
                return true
            case kVK_ANSI_Z:
                if !isSearchFocused {
                    actions.undoDelete()
                    return true
                }
            default:
                break
            }
            return false
        }

        // 列表态打字即搜索（Spotlight 式）：无修饰可打印字符聚焦搜索框，
        // 字符经动作重投递落入输入框。文本编辑器持焦时不抢（输入归编辑器）
        if modifiers.isEmpty,
           !(responder.map { isSelectableTextResponder($0) } ?? false),
           isTypeToSearchChar(event) {
            actions.typeToSearch(event)
            return true
        }

        return false
    }

    // T039（D8 热区同源 / 契约 R11）：几何常量引用 NookClip 令牌
    //（NookTheme.swift「4.4b 面板交互热区」），与 UI 布局同源，勿在此硬编码
    func isInteractiveArea(at point: NSPoint) -> Bool {
        if isSearchBarArea(at: point) { return true }

        // 预览区顶部工具栏（复制/收藏/删除按钮）
        if point.x >= NookClip.widthListCol
            && point.y >= (frame.height - NookClip.hotZonePreviewToolbarHeight) {
            return true
        }

        // 时间锚点刻度轨区域（列表列右缘）
        let isTimeRailArea = point.x >= (NookClip.widthListCol - NookClip.hotZoneTimeRailWidth)
            && point.x <= NookClip.widthListCol
            && point.y >= NookClip.hotZoneTopControlHeight
            && point.y <= (frame.height - NookClip.hotZoneTopControlHeight)
        if isTimeRailArea { return true }

        // 底部提示与帮助栏
        if point.y <= NookClip.heightFooter && point.x <= NookClip.widthListCol {
            return true
        }

        return false
    }

    func isSearchBarArea(at point: NSPoint) -> Bool {
        return point.x >= NookClip.hotZoneSearchBarLeading
            && point.x <= NookClip.widthListCol
            && point.y >= (frame.height - NookClip.hotZoneSearchBarTopInset)
            && point.y <= (frame.height - NookClip.hotZoneSearchBarBottomInset)
    }

    /// T039：debug 断言热区矩形覆盖预期交互区（面板创建时由
    /// QuickPopoverController.getOrCreatePanel 调用）。令牌改动导致热区
    /// 漂移（罩不住搜索框带 / 预览工具栏）时即刻失败。
    func debugAssertHotZoneCoverage() {
        // 搜索栏热区带 [topInset, bottomInset] 必须罩住
        // 搜索框带 [searchTopInset, searchTopInset + heightSearch]
        assert(NookClip.hotZoneSearchBarTopInset >= NookClip.searchTopInset + NookClip.heightSearch,
               "搜索栏热区上缘须覆盖搜索框下沿（D8 同源断言）")
        assert(NookClip.hotZoneSearchBarBottomInset <= NookClip.searchTopInset,
               "搜索栏热区下缘须覆盖搜索框上沿（D8 同源断言）")
        assert(NookClip.hotZonePreviewToolbarHeight >= NookClip.heightToolbar,
               "预览工具栏热区须覆盖工具栏高度（D8 同源断言）")
    }

    func isHeaderDragArea(at point: NSPoint) -> Bool {
        guard point.y >= frame.height - 48 else { return false }
        if resizeDirection(at: point) != nil { return false }
        return !isInteractiveArea(at: point)
    }

    /// 边缘缩放事件循环：八个方向的差异仅为「哪条边锚定不动」，收敛为
    /// anchorsLeft / anchorsBottom 两个布尔驱动的单一几何计算
    private func handleResize(direction: ResizeDirection, startEvent: NSEvent) {
        // AutoResetFlag 固定 0.15s 自动复位，而缩放循环常持续数秒——结束时
        // 重新置位一段保持期，避免拖拽后期「isResizing 已失效」时应用切换
        // 通知把面板强行关闭（审计 BUG-048）
        resizingFlag.set(for: 0.15)

        let startFrame = frame
        let startMouseScreen = NSEvent.mouseLocation
        let startTop = startFrame.origin.y + startFrame.height
        let startRight = startFrame.origin.x + startFrame.width
        let minW = currentMinPanelWidth
        let maxW = maxAllowedWidth

        while true {
            guard let nextEvent = nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) else {
                break
            }
            if nextEvent.type == .leftMouseUp {
                break
            }

            let currentMouseScreen = NSEvent.mouseLocation
            let deltaX = currentMouseScreen.x - startMouseScreen.x
            let deltaY = currentMouseScreen.y - startMouseScreen.y

            var newFrame = startFrame
            if direction.affectsWidth {
                // 拖右缘：宽度随 +deltaX 增大、左缘锚定；拖左缘反之（右缘锚定）
                let signedDelta = direction.anchorsLeft ? deltaX : -deltaX
                let newWidth = min(max(startFrame.width + signedDelta, minW), maxW)
                newFrame.size.width = newWidth
                if !direction.anchorsLeft {
                    newFrame.origin.x = startRight - newWidth
                }
            }
            if direction.affectsHeight {
                // 拖顶缘：高度随 +deltaY 增大、底缘锚定；拖底缘反之（顶缘锚定）。
                // 高度钳制与 PanelGeometry 统一（625~900）：私有 400/1200 会让拖出的
                let signedDelta = direction.anchorsBottom ? deltaY : -deltaY
                let newHeight = min(max(startFrame.height + signedDelta, PanelGeometry.minHeight), PanelGeometry.maxHeight)
                newFrame.size.height = newHeight
                if !direction.anchorsBottom {
                    newFrame.origin.y = startTop - newHeight
                }
            }

            setFrame(newFrame, display: true)
            resizingFlag.set(for: 0.15) // 拖拽期间持续续期守卫
        }

        // 拖拽结束：守卫再保持 0.5s（覆盖随后的点击/应用切换抖动）
        resizingFlag.set(for: 0.5)
        saveResizedDimensions()
    }

    private func saveResizedDimensions() {
        UserDefaults.standard.set(Double(frame.width), forKey: UserDefaultsKey.panelWidth.rawValue)
        UserDefaults.standard.set(Double(frame.height), forKey: UserDefaultsKey.panelCustomHeight.rawValue)
    }
    /// 归还键盘焦点：脱离预览可选中文本（否则 ↑↓/⌘C 被文本视图截留）。
    /// 面板非 key window 时（LSUIElement 应用 NSMenu 关闭后 key 状态可能不回归，
    /// 键盘事件全部派发给 key window，面板收不到任何按键——键盘主循环整体失灵），
    /// 先激活应用夺回 key 状态。搜索框/重命名输入框持焦时不抢（输入态优先）。
    /// 预览复制（PreviewDataProvider / CodePreviewCard）经 .restoreKeyboardFocus
    /// 通知走同一入口；组头时间菜单关闭后夺回 key 状态也走此入口。
    func restoreKeyboardFocus() {
        if isVisible, (!isKeyWindow || !hasKeyFocus) {
            NSApp.activate(ignoringOtherApps: true)
            makeKey()
        }
        if let responder = firstResponder as? NSView,
           isSearchFieldEditor(responder) || isListColumnFieldEditor(responder) || isPreviewEditableTextResponder(responder) {
            return
        }
        makeFirstResponder(nil)
    }
}

// MARK: - 第一响应者与文本交互判定扩展

extension DraggablePanel {
    /// firstResponder 是否可选中文本交互视图（NSText 或 SwiftUI .textSelection 视图）
    func isSelectableTextResponder(_ responder: NSResponder?) -> Bool {
        guard let view = responder as? NSView else { return false }
        return view is NSText || String(describing: type(of: view)).contains("TextInteraction")
    }

    /// firstResponder 是否详情区域的可编辑文本编辑器（`NSText.isEditable == true`，如未来的笔记/待办编辑器）
    func isPreviewEditableTextResponder(_ responder: NSResponder?) -> Bool {
        guard let text = responder as? NSText, text.isEditable else { return false }
        guard !isSearchFieldEditor(text), !isListColumnFieldEditor(text) else { return false }
        let frame = text.convert(text.bounds, to: nil)
        let mid = NSPoint(x: frame.midX, y: frame.midY)
        return isPreviewColumnPoint(mid)
    }

    /// firstResponder 是否预览区域的**只读**可选中文本视图（位于预览列，非搜索框/重命名框/可编辑文本器）
    func isPreviewSelectableTextResponder(_ responder: NSResponder?) -> Bool {
        guard let view = responder as? NSView, isSelectableTextResponder(view) else { return false }
        if let text = view as? NSText, text.isEditable { return false }
        guard !isSearchFieldEditor(view), !isListColumnFieldEditor(view) else { return false }
        let frame = view.convert(view.bounds, to: nil)
        let mid = NSPoint(x: frame.midX, y: frame.midY)
        return isPreviewColumnPoint(mid)
    }

    /// 点击位置是否落在可选中文本视图（SwiftUI .textSelection 生成的视图或 NSTextView）内
    func hitSelectableText(at point: NSPoint) -> Bool {
        guard let contentView else { return false }
        var current: NSView? = contentView.hitTest(point)
        while let view = current {
            if isSelectableTextResponder(view) { return true }
            current = view.superview
        }
        return false
    }

    /// firstResponder 是否搜索框的 field editor
    func isSearchFieldEditor(_ responder: NSView) -> Bool {
        guard responder is NSText else { return false }
        let frame = responder.convert(responder.bounds, to: nil)
        return isSearchBarArea(at: NSPoint(x: frame.midX, y: frame.midY))
    }

    /// 事件是否为无修饰可打印单字符（字母/数字/标点/符号/空格）；
    /// Tab、方向键、⏎、Esc、⌫ 等控制键返回 false
    func isTypeToSearchChar(_ event: NSEvent) -> Bool {
        guard let chars = event.charactersIgnoringModifiers,
              chars.count == 1,
              let scalar = chars.unicodeScalars.first else { return false }
        if scalar == " " { return true }
        return CharacterSet.alphanumerics.contains(scalar)
            || CharacterSet.punctuationCharacters.contains(scalar)
            || CharacterSet.symbols.contains(scalar)
    }

    /// firstResponder 是否列表列的字段编辑器（行内重命名输入框）
    func isListColumnFieldEditor(_ responder: NSResponder) -> Bool {
        guard let text = responder as? NSText else { return false }
        let frame = text.convert(text.bounds, to: nil)
        let mid = NSPoint(x: frame.midX, y: frame.midY)
        return !isSearchFieldEditor(text) && !isPreviewColumnPoint(mid)
    }

    /// 预览列区域（x > widthListCol；面板收窄到无预览列时恒 false）
    func isPreviewColumnPoint(_ point: NSPoint) -> Bool {
        guard frame.width >= PanelGeometry.expandedMinWidth else { return false }
        return point.x > NookClip.widthListCol
    }
}
