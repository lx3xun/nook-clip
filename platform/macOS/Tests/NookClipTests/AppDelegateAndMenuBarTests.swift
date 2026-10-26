import XCTest
import AppKit
import SwiftUI
@testable import NookClip

@MainActor
final class AppDelegateAndMenuBarTests: XCTestCase {

    func testAppDelegateInitialization() {
        let delegate = AppDelegate()
        XCTAssertNotNil(delegate.clipboardMonitor, "AppDelegate 必须初始化剪贴板监听器")
        XCTAssertNotNil(delegate.historyStore, "AppDelegate 必须初始化历史存储")
        XCTAssertNil(delegate.lastTargetApplication, "初始状态下外部活跃应用记录为空")
    }

    func testAppDelegateWorkspaceDidActivateAppRecordsExternalApp() {
        let delegate = AppDelegate()
        XCTAssertNil(delegate.lastTargetApplication)

        // 1. 空通知或无 userInfo 时不崩溃且不记录
        let emptyNotif = Notification(name: NSWorkspace.didActivateApplicationNotification)
        delegate.workspaceDidActivateApp(emptyNotif)
        XCTAssertNil(delegate.lastTargetApplication)

        // 2. 外部应用激活时（如 Finder），记录为 lastTargetApplication
        if let externalApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            let externalNotif = Notification(
                name: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                userInfo: [NSWorkspace.applicationUserInfoKey: externalApp]
            )
            delegate.workspaceDidActivateApp(externalNotif)
            XCTAssertEqual(delegate.lastTargetApplication?.bundleIdentifier, "com.apple.finder", "外部应用激活时必须更新记录")
        }
    }

    func testMenuBarViewRendersAndListensToHotKeyDidChange() {
        let menuBar = MenuBarView()
        XCTAssertNotNil(menuBar, "状态栏菜单视图应正常创建")

        // 验证发送 .hotKeyDidChange 通知时不发生崩溃或死锁
        NotificationCenter.default.post(name: .hotKeyDidChange, object: nil)
    }

    func testOpenSettingsBringsSettingsWindowToFrontOnFirstTrigger() {
        let delegate = AppDelegate()
        let notif = Notification(name: NSApplication.didFinishLaunchingNotification)
        delegate.applicationDidFinishLaunching(notif)
        defer {
            delegate.applicationWillTerminate(notif)
            let title = L10n.tr("settings.window_title")
            if let win = NSApp.windows.first(where: { $0.title == title }) {
                win.close()
            }
        }

        NotificationCenter.default.post(name: .openSettings, object: nil)

        let settingsTitle = L10n.tr("settings.window_title")
        let settingsWindow = NSApp.windows.first { $0.title == settingsTitle }
        XCTAssertNotNil(settingsWindow, "首次发送 .openSettings 时设置窗口必须立即创建并存在")
        XCTAssertTrue(settingsWindow?.isVisible == true, "设置窗口首次展示必须立即处于可见状态")
        XCTAssertNotNil(settingsWindow?.contentViewController, "展示期间应持有 SettingsView 宿主视图控制器")
        // 设置页改为方案 C 的外壳（侧栏 + 画布）后，580×520 装不下折叠分组与现状带，
        // 窗口放宽到 900×720 并允许缩放（最小 760×560）
        XCTAssertEqual(settingsWindow?.contentView?.frame.width, 900, "设置窗口内容宽度必须为 900")
        XCTAssertEqual(settingsWindow?.contentView?.frame.height, 720, "设置窗口内容高度必须为 720")
        XCTAssertTrue(
            settingsWindow?.styleMask.contains(.resizable) == true,
            "设置窗口应允许缩放，否则内容被固定高度裁切"
        )
        XCTAssertFalse(settingsWindow?.isReleasedWhenClosed ?? true, "设置窗口关闭时不应被自动释放")
        XCTAssertEqual(settingsWindow?.level, .floating, "作为 LSUIElement 应用的设置窗口应为 floating 层级以防点击外部被覆盖消失")

        // 关闭设置窗口后应自动释放宿主视图树以回收内存，再次发送 .openSettings 应能无缝重建
        settingsWindow?.close()
        XCTAssertNil(settingsWindow?.contentViewController, "设置窗口关闭后应释放 contentViewController 宿主视图树")
        NotificationCenter.default.post(name: .openSettings, object: nil)
        XCTAssertNotNil(settingsWindow?.contentViewController, "再次打开设置窗口应重新挂载 SettingsView 宿主视图树")
        XCTAssertTrue(settingsWindow?.isVisible == true)
    }

    func testQuickPopoverControllerCloseWithoutRestoreFocusHidesPanel() {
        let store = makeIsolatedStore()
        let controller = QuickPopoverController(
            historyStore: store,
            targetApplicationProvider: { nil },
            clipboardWriter: PasteService.shared
        )

        controller.showFromMenuBar()
        XCTAssertTrue(controller.panel?.isVisible == true, "showFromMenuBar 必须展示面板")

        controller.close(restoreFocus: false)
        XCTAssertFalse(controller.panel?.isVisible ?? true, "close(restoreFocus: false) 之后面板必须隐藏")
    }

    func testNotificationNamesFormatAndUniqueness() {
        let names: [Notification.Name] = [
            .openQuickPopover,
            .quickPopoverDidOpen,
            .openSettings,
            .hotKeyDidChange,
            .quickPopoverPreviewStateDidChange,
            .quickPopoverPreserveWindow,
            .languageDidChange,
            .appearanceDidChange,
            .restoreKeyboardFocus,
            .startPasteStackRecording
        ]

        let rawNames = names.map(\.rawValue)
        let uniqueNames = Set(rawNames)
        XCTAssertEqual(rawNames.count, uniqueNames.count, "所有内部通知名称必须全局唯一，避免冲突")
        XCTAssertTrue(rawNames.allSatisfy { $0.hasPrefix("NookClip.") }, "所有内部通知名称必须以 NookClip. 命名空间开头")
    }

    func testFirstLaunchOnboardingPromptsForAccessibilityPermissionWhenUntrusted() {
        let defaults = makeIsolatedDefaults()
        let dependencies = AppDependencies(
            defaults: defaults,
            payloadStore: FileStore.shared,
            cryptoService: KeychainCryptoService.shared,
            clipboardWriter: PasteService.shared,
            syncEngine: makeDisabledSyncEngine()
        )
        let delegate = AppDelegate(dependencies: dependencies)

        let originalChecker = PasteService.accessibilityTrustChecker
        let originalPrompter = PasteService.accessibilityPermissionPrompter
        let originalIsDefault = PasteService.accessibilityTrustCheckerIsDefault
        defer {
            PasteService.accessibilityTrustChecker = originalChecker
            PasteService.accessibilityPermissionPrompter = originalPrompter
            PasteService.accessibilityTrustCheckerIsDefault = originalIsDefault
        }

        var promptCount = 0
        PasteService.accessibilityTrustCheckerIsDefault = false
        PasteService.accessibilityTrustChecker = { false }
        PasteService.accessibilityPermissionPrompter = {
            promptCount += 1
            return false
        }

        let expectation = expectation(description: "First launch onboarding triggers accessibility permission prompt")
        delegate.performFirstLaunchOnboardingIfNeeded(isTesting: false, hasCliOverride: false)
        XCTAssertTrue(defaults.bool(forKey: UserDefaultsKey.hasLaunchedBefore.rawValue), "首次启动后应置位 hasLaunchedBefore")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            XCTAssertEqual(promptCount, 1, "首次启动且未授权辅助功能时应触发一次系统权限引导")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        // 二次调用（非首次启动）不应重复触发
        delegate.performFirstLaunchOnboardingIfNeeded(isTesting: false, hasCliOverride: false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.75))
        XCTAssertEqual(promptCount, 1, "非首次启动不应重复触发首次启动权限引导")
    }

    func testPastePromptsForAccessibilityPermissionWhenUntrusted() {
        let originalChecker = PasteService.accessibilityTrustChecker
        let originalPrompter = PasteService.accessibilityPermissionPrompter
        let originalIsDefault = PasteService.accessibilityTrustCheckerIsDefault
        defer {
            PasteService.accessibilityTrustChecker = originalChecker
            PasteService.accessibilityPermissionPrompter = originalPrompter
            PasteService.accessibilityTrustCheckerIsDefault = originalIsDefault
        }

        var promptCount = 0
        PasteService.accessibilityTrustCheckerIsDefault = false
        PasteService.accessibilityTrustChecker = { false }
        PasteService.accessibilityPermissionPrompter = {
            promptCount += 1
            return false
        }

        withPasteboardLock {
            let item = ClipboardItem(type: .text, title: "Test", summary: "Prompt on paste")
            let singleSuccess = PasteService.shared.paste(item)
            XCTAssertFalse(singleSuccess)
            XCTAssertEqual(promptCount, 1, "单条粘贴在未授权辅助功能时应触发系统权限弹窗")

            let batchSuccess = PasteService.shared.pasteText("Batch text")
            XCTAssertFalse(batchSuccess)
            XCTAssertEqual(promptCount, 2, "批量合并粘贴在未授权辅助功能时也应触发系统权限弹窗")
        }
    }
}
