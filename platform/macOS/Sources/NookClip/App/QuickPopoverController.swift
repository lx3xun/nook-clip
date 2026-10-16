import AppKit
import SwiftUI

@MainActor
final class QuickPopoverController: NSObject {
    private let historyStore: InMemoryHistoryStore
    private(set) var panel: NSPanel?
    private let targetApplicationProvider: () -> NSRunningApplication?
    private var currentTargetApplication: NSRunningApplication?
    /// T040（契约 R4/R5）：经 AppDelegate → AppDependencies 注入，转发给 MainView
    private let clipboardWriter: any ClipboardWriter
    private var globalClickMonitor: Any?

    init(historyStore: InMemoryHistoryStore, targetApplicationProvider: @escaping () -> NSRunningApplication?, clipboardWriter: any ClipboardWriter) {
        self.historyStore = historyStore
        self.targetApplicationProvider = targetApplicationProvider
        self.clipboardWriter = clipboardWriter
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openFromMenuBar),
            name: .openQuickPopover,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePreserveWindow),
            name: .quickPopoverPreserveWindow,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppearanceChanged),
            name: .appearanceDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSystemColorsChanged),
            name: NSColor.systemColorsDidChangeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWorkspaceDidActivateApp(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    deinit {
        // deinit 非隔离：直接内联监控移除（对象销毁中，无并发访问）
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// 保持窗口短时守卫（置位后 0.6s 内不因失焦关闭）
    private let preserveOnResignKey = AutoResetFlag()

    @objc private func handlePreserveWindow() {
        preserveOnResignKey.set(for: 0.8)
        // 保持面板打开模式（⌘⏎）：在目标应用激活并消费模拟粘贴事件后，
        // 重新将浮层置为 KeyWindow 并聚焦，使用户可连续按键操作（如 ↓ 下一行再 ⌘⏎）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            guard let self = self, let panel = self.panel, panel.isVisible else { return }
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
            (panel as? DraggablePanel)?.restoreKeyboardFocus()
            self.preserveOnResignKey.reset()
        }
    }
    @objc private func handleAppearanceChanged() {
        if let panel {
            updatePanelAppearance(panel)
        }
    }
    @objc private func handleSystemColorsChanged() {
        if let panel {
            panel.contentView?.needsDisplay = true
        }
    }

    private var lastExpandedWidth: CGFloat = 750

    /// 同步面板宽度约束（NSPanel min/maxSize + DraggablePanel 拖拽范围）
    private func applyPanelSizeConstraints(_ panel: NSPanel) {
        panel.minSize = NSSize(width: PanelGeometry.expandedMinWidth, height: PanelGeometry.minHeight)
        panel.maxSize = NSSize(width: PanelGeometry.expandedMaxWidth, height: PanelGeometry.maxHeight)
        if let draggable = panel as? DraggablePanel {
            draggable.currentMinPanelWidth = PanelGeometry.expandedMinWidth
            draggable.currentMaxPanelWidth = PanelGeometry.expandedMaxWidth
        }
    }

    /// 目标面板宽度：优先上次展开宽度，其次手动拖拽记录的 panelWidth / 缺省值，上限 expandedMaxWidth
    private var expandedTargetWidth: CGFloat {
        let savedWidth = UserDefaults.standard.double(forKey: UserDefaultsKey.panelWidth.rawValue)
        let fallback = savedWidth >= Double(PanelGeometry.expandedMinWidth)
            ? CGFloat(savedWidth)
            : PanelGeometry.expandedDefaultWidth
        return min(max(lastExpandedWidth, fallback), PanelGeometry.expandedMaxWidth)
    }

    /// 目标面板高度：处理旧版本历史默认值 644 迁移，保证未手动缩放时严格为 10 行高度 (625)
    private var effectivePanelHeight: CGFloat {
        let savedHeight = UserDefaults.standard.double(forKey: UserDefaultsKey.panelCustomHeight.rawValue)
        if savedHeight <= 0 || abs(savedHeight - 644) < 0.5 {
            return PanelGeometry.minHeight
        }
        return savedHeight >= Double(PanelGeometry.minHeight) ? CGFloat(savedHeight) : PanelGeometry.minHeight
    }
    private func updatePanelAppearance(_ panel: NSPanel) {
        let mode = UserDefaults.standard.string(forKey: "appearance") ?? "system"
        switch mode {
        case "light":
            panel.appearance = NSAppearance(named: .aqua)
        case "dark":
            panel.appearance = NSAppearance(named: .darkAqua)
        default:
            panel.appearance = nil
        }
    }


    func toggle() {
        if let panel = panel, panel.isVisible {
            close()
        } else {
            show()
            // 唤起浮层时触发一次云端同步拉取（60s 节流，避免频繁呼出反复读 iCloud）
            Task { @MainActor [weak self] in
                await self?.historyStore.pullRemoteChanges(minInterval: 60)
            }
        }
    }

    private func show(preserveDuration: TimeInterval? = nil) {
        if let preserveDuration {
            preserveOnResignKey.set(for: preserveDuration)
        }
        currentTargetApplication = targetApplicationProvider()
        let panel = getOrCreatePanel()
        updatePanelAppearance(panel)
        let targetWidth: CGFloat = expandedTargetWidth
        let height: CGFloat = effectivePanelHeight
        applyPanelSizeConstraints(panel)
        // 获取当前鼠标指针所在的显示器，若未找到则回退至主屏幕
        let mouseLocation = NSEvent.mouseLocation
        let activeScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main
        let screenVisibleFrame = activeScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // 始终在鼠标所在显示器的可见区域内垂直水平居中
        var targetOriginX = screenVisibleFrame.midX - targetWidth / 2
        var targetOriginY = screenVisibleFrame.midY - height / 2

        // 确保窗口始终落在屏幕可见区域内
        targetOriginX = max(screenVisibleFrame.minX, min(targetOriginX, screenVisibleFrame.maxX - targetWidth))
        targetOriginY = max(screenVisibleFrame.minY, min(targetOriginY, screenVisibleFrame.maxY - height))

        panel.setFrame(
            NSRect(
                x: targetOriginX,
                y: targetOriginY,
                width: targetWidth,
                height: height
            ),
            display: true
        )
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        startMonitoringOutsideClicks()
        NotificationCenter.default.post(name: .quickPopoverDidOpen, object: nil)
    }

    func close(restoreFocus: Bool = true) {
        stopMonitoringOutsideClicks()
        panel?.orderOut(nil)
        guard restoreFocus else { return }
        // 归还焦点：show() 用 NSApp.activate 抢占了前台，关闭时若 NookClip 仍是
        // 前台（Esc/外部点击/快捷键收起），把焦点还给呼出前的目标应用——
        // LSUIElement 无其他窗口时系统不一定自动归还，原应用会持续失焦吞键
        //（审计 BUG-025）。应用切换路径（对方已激活）不抢焦点
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            if let target = currentTargetApplication {
                target.activate()
            } else {
                NSApp.deactivate()
            }
        }
    }

    /// 「不该关闭」守卫（外部点击 / 应用切换两条路径、同步与异步复核共用）：
    /// 面板不可见、保持窗口期（0.6s）、拖动/缩放进行中、鼠标按下（仅应用切换路径）、
    /// 或鼠标位于面板及 28pt 容差热区内（正在抓边框/拖放，仅外部点击路径）时不得关闭。
    /// - Parameter mouseLocationCheck: 鼠标热区检查仅限外部点击路径——键盘切应用
    ///   （⌘Tab/Spotlight）不产生鼠标事件，指针恰在面板内时不得据此拒绝关闭，
    ///   否则面板悬浮遮挡新应用且无任何路径能再收起（审计 BUG-026）
    private func shouldClosePanelNow(mousePressedCheck: Bool = false, mouseLocationCheck: Bool = true) -> Bool {
        guard let panel = panel, panel.isVisible else { return false }
        guard !preserveOnResignKey.isActive else { return false }
        if let draggable = panel as? DraggablePanel, draggable.isResizing || draggable.isDragging {
            return false
        }
        if mousePressedCheck, NSEvent.pressedMouseButtons != 0 {
            return false
        }
        if mouseLocationCheck,
           panel.frame.insetBy(dx: -PanelGeometry.outsideClickTolerance, dy: -PanelGeometry.outsideClickTolerance).contains(NSEvent.mouseLocation) {
            return false
        }
        return true
    }

    private func startMonitoringOutsideClicks() {
        stopMonitoringOutsideClicks()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, self.shouldClosePanelNow() else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.shouldClosePanelNow() else { return }
                self.close()
            }
        }
    }

    private func stopMonitoringOutsideClicks() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
    }

    @objc private func handleWorkspaceDidActivateApp(_ notification: Notification) {
        // 鼠标按下（正在拖拽/缩放/点击边框边缘）时不关闭；鼠标热区检查在此路径
        // 禁用（键盘切应用 + 指针停在面板内 ≠ 抓边框，审计 BUG-026）
        guard shouldClosePanelNow(mousePressedCheck: true, mouseLocationCheck: false) else { return }
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.shouldClosePanelNow(mousePressedCheck: true, mouseLocationCheck: false) else { return }
                self.close()
            }
        }
    }

    func showFromMenuBar(preserveDuration: TimeInterval? = nil) { show(preserveDuration: preserveDuration) }

    @objc private func openFromMenuBar() { show() }

    private func getOrCreatePanel() -> NSPanel {
        if let existing = panel {
            return existing
        }
        let savedWidth = UserDefaults.standard.double(forKey: UserDefaultsKey.panelWidth.rawValue)
        let targetWidth: CGFloat = savedWidth >= Double(PanelGeometry.expandedMinWidth) ? CGFloat(savedWidth) : PanelGeometry.expandedDefaultWidth
        // 高度下限：保证 10 行（50pt/行）完整可见（见 PanelGeometry.minHeight 注释）
        let height: CGFloat = effectivePanelHeight
        // .titled + .fullSizeContentView：标题栏透明且不占独立空间，内容铺满全窗。
        // 无红绿灯按钮：红键/黄键靠 styleMask 不含 .closable / .miniaturizable 隐藏
        //（LSUIElement 无 Dock 图标，最小化无意义且恢复有坑，设置窗 BUG-027）；
        // 绿键跟随 .resizable 出现、无法靠样式位去除，必须显式隐藏。
        // 关闭走 Esc/外部点击的 close() 路径。
        let panel = DraggablePanel(
            contentRect: NSRect(x: 0, y: 0, width: targetWidth, height: height),
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.minSize = NSSize(width: PanelGeometry.expandedMinWidth, height: PanelGeometry.minHeight)
        panel.maxSize = NSSize(width: PanelGeometry.expandedMaxWidth, height: PanelGeometry.maxHeight)
        panel.acceptsMouseMovedEvents = true
        panel.isMovableByWindowBackground = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.isOpaque = true
        panel.backgroundColor = nil
        panel.hasShadow = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let hostingController = NSHostingController(
            rootView: MainView(
                store: historyStore,
                clipboardWriter: clipboardWriter,
                getTargetApplication: { [weak self] in self?.currentTargetApplication },
                onClose: { [weak self] in self?.close() },
                // 键盘主循环动作表注入面板（weak 防止 闭包→MainView→面板 的持有环）
                installKeyActions: { [weak panel] actions in
                    panel?.keyActions = actions
                }
            )
            .nookClipLocalized()
        )
        hostingController.sizingOptions = []
        panel.contentViewController = hostingController

        // Esc 穿透到 AppKit cancelOperation 时走控制器的 close()（解绑监听、
        // 同步生命周期，审计 BUG-043）
        panel.onCancel = { [weak self] in self?.close() }
        // T039：面板创建时校验热区并集仍覆盖预期交互区（debug 断言）
        panel.debugAssertHotZoneCoverage()

        self.panel = panel
        return panel
    }
}

