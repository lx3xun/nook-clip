import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 依赖组装入口：生产默认实例在此集中构造，后续阶段各组件逐步改为从此注入
    private let dependencies: AppDependencies
    let clipboardMonitor: ClipboardMonitor
    let hotKeyManager = HotKeyManager.shared
    let historyStore: InMemoryHistoryStore
    private var popoverController: QuickPopoverController!
    private lazy var settingsWindowController = SettingsWindowController(historyStore: historyStore)
    private(set) var lastTargetApplication: NSRunningApplication?

    init(dependencies: AppDependencies = .live) {
        self.dependencies = dependencies
        clipboardMonitor = ClipboardMonitor(
            payloadStore: dependencies.payloadStore,
            rustEngine: dependencies.rustHistoryStore.engine
        )
        historyStore = InMemoryHistoryStore(
            rustStore: dependencies.rustHistoryStore,
            syncEngine: dependencies.syncEngine,
            defaults: dependencies.defaults,
            payloadStore: dependencies.payloadStore
        )
        super.init()
    }

    convenience override init() {
        self.init(dependencies: .live)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSScrollView.enableOverlayScrollersGlobally()
        // 1. 防止应用多开：若检测到同 bundleId 的已有进程，退出新进程
        let myPID = ProcessInfo.processInfo.processIdentifier
        let bundleId = Bundle.main.bundleIdentifier ?? "com.lx3xun.nookclip"
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        if running.contains(where: { $0.processIdentifier != myPID }) {
            NSApp.terminate(nil)
            return
        }

        // 2. 初始记录当前非自身的前台应用
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != myPID {
            lastTargetApplication = front
        }

        // 3. 实时监听全局应用切换，随时维护最后活跃的外部应用
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidActivateApp(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        // 3.6 热键自愈：睡眠唤醒/锁屏解锁后 Carbon 热键可能被系统静默丢弃，
        // 重注册恢复（见 HotKeyManager.revalidate 注释）
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(revalidateHotKey(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        // 锁屏解锁没有 NSWorkspace 通知，用系统分布式通知
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(revalidateHotKey(_:)),
            name: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )

        // 3.5 分页加载：store 初始只载首页 100 条，列表滚动到底自动翻页，
        // 无需后台预热（用户明确不引入额外后台开销）。
        popoverController = QuickPopoverController(
            historyStore: historyStore,
            targetApplicationProvider: { [weak self] in
                // 若当前前台是外部应用则用当前，否则回退到最近一次记录的外部应用
                if let front = NSWorkspace.shared.frontmostApplication,
                   front.processIdentifier != myPID {
                    return front
                }
                return self?.lastTargetApplication
            },
            clipboardWriter: dependencies.clipboardWriter
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSettings(_:)),
            name: .openSettings,
            object: nil
        )

        clipboardMonitor.onChange = { [weak self] item in
            self?.historyStore.save(item)
        }
        clipboardMonitor.start()

        hotKeyManager.onPress = { [weak self] in self?.popoverController.toggle() }
        hotKeyManager.register()

        // Sparkle 自动更新：先探测更新源再启动（延迟检查周期默认 24h）
        UpdateService.shared.start()

        // 预热应用列表缓存，避免用户首次在搜索框输入时阻塞
        AppSearchService.shared.warmUp()

        // 调试/冒烟入口：带 `--show-panel` 启动时直接呼出面板
        // （自动化测试无法触发 Carbon 全局热键）
        if ProcessInfo.processInfo.arguments.contains("--show-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.popoverController.showFromMenuBar()
            }
        }
        // 首次启动引导：用户初次打开 App 时自动呼出面板，并在未授权辅助功能时触发系统授权提示
        // （排除 XCTest 单元测试环境以及带命令行窗口覆盖参数的场景）
        let isTesting = NSClassFromString("XCTestCase") != nil
        let hasCliOverride = ProcessInfo.processInfo.arguments.contains("--show-settings")
            || ProcessInfo.processInfo.arguments.contains("--show-panel")
        performFirstLaunchOnboardingIfNeeded(isTesting: isTesting, hasCliOverride: hasCliOverride)


        // 延迟后台静默预热 Vision OCR 模型，避免用户首次在图片预览区点击识别时因加载模型等待 10-20 秒
        if !isTesting {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3.0) {
                OCREngine.shared.prewarm()
            }
        }
        // 调试/冒烟入口：带 `--show-settings` 启动时直接打开设置窗口
        if ProcessInfo.processInfo.arguments.contains("--show-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.settingsWindowController.show()
            }
        }
    }

    /// 首次启动引导逻辑：
    /// 1. 首次启动（`hasLaunchedBefore == false`）时标记已启动并自动呼出快速面板；
    /// 2. 若当前尚未获得 macOS 辅助功能权限（`!PasteService.isAccessibilityTrusted`），
    ///    向系统登记 NookClip 并弹出原生辅助功能授权提示框。
    func performFirstLaunchOnboardingIfNeeded(isTesting: Bool = false, hasCliOverride: Bool = false) {
        guard !isTesting && !hasCliOverride else { return }
        let hasLaunchedBefore = dependencies.defaults.bool(forKey: UserDefaultsKey.hasLaunchedBefore.rawValue)
        guard !hasLaunchedBefore else { return }
        dependencies.defaults.set(true, forKey: UserDefaultsKey.hasLaunchedBefore.rawValue)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.popoverController?.showFromMenuBar(preserveDuration: 3.0)
            _ = PasteService.promptForAccessibilityPermissionIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardMonitor.stop()
        hotKeyManager.unregister()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc func workspaceDidActivateApp(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastTargetApplication = app
        }
    }

    /// 唤醒/解锁后热键可能失效，自动重注册（用户反馈：快捷键偶发失灵）
    @objc private func revalidateHotKey(_ notification: Notification) {
        hotKeyManager.revalidate()
    }

    @objc private func openSettings(_ notification: Notification) {
        popoverController.close(restoreFocus: false)
        let requestedTab: SettingsTab? = {
            if let tab = notification.userInfo?["tab"] as? SettingsTab {
                return tab
            }
            if let raw = notification.userInfo?["tab"] as? String {
                return SettingsTab(rawValue: raw)
            }
            return nil
        }()
        settingsWindowController.show(tab: requestedTab)
    }
}

private final class SettingsWindowController: NSWindowController {
    private let historyStore: InMemoryHistoryStore

    init(historyStore: InMemoryHistoryStore) {
        self.historyStore = historyStore
        let hostingController = NSHostingController(rootView: SettingsView(historyStore: historyStore).nookClipLocalized())
        let window = NSWindow(contentViewController: hostingController)
        window.title = L10n.tr("settings.window_title")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 580, height: 520))
        window.isReleasedWhenClosed = false
        super.init(window: window)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languageDidChange),
            name: .languageDidChange,
            object: nil
        )
    }

    @objc private func languageDidChange() {
        window?.title = L10n.tr("settings.window_title")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show(tab: SettingsTab? = nil) {
        if let tab {
            window?.contentViewController = NSHostingController(
                rootView: SettingsView(historyStore: historyStore, initialTab: tab).nookClipLocalized()
            )
            window?.setContentSize(NSSize(width: 580, height: 520))
        }
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        // LSUIElement 应用无 Dock 图标：最小化后的窗口 makeKeyAndOrderFront
        // 不会自动恢复，必须显式 deminiaturize（审计 BUG-027）
        if window?.isMiniaturized == true {
            window?.deminiaturize(nil)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}
