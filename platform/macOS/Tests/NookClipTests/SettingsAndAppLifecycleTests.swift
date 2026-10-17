import SwiftUI
import XCTest
@testable import NookClip

@MainActor
final class SettingsAndAppLifecycleTests: XCTestCase {

    private func renderView<V: View>(_ view: V) -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 600)
        host.layoutSubtreeIfNeeded()
        return host
    }

    func testSettingsTabsTitlesAndIcons() {
        for tab in SettingsTab.allCases {
            XCTAssertFalse(tab.title.isEmpty, "Tab title should not be empty")
            XCTAssertFalse(tab.icon.isEmpty, "Tab icon name should not be empty")
        }
        XCTAssertEqual(SettingsTab.allCases.count, 5)
    }

    func testSettingsViewRendersAllTabsWithoutCrashing() {
        let store = makeIsolatedStore()
        for tab in SettingsTab.allCases {
            let settingsView = SettingsView(historyStore: store, initialTab: tab)
            let host = renderView(settingsView)
            XCTAssertNotNil(host.viewWithTag(0))
        }
    }

    func testSettingsViewTabSwitchingViaNotification() {
        let store = makeIsolatedStore()
        let settingsView = SettingsView(historyStore: store, initialTab: .general)
        let host = renderView(settingsView)
        XCTAssertNotNil(host)

        NotificationCenter.default.post(
            name: .openSettings,
            object: nil,
            userInfo: ["tab": SettingsTab.appearance]
        )
        // 验证通知派发后正常运行
        NotificationCenter.default.post(
            name: .openSettings,
            object: nil,
            userInfo: ["tab": "history"]
        )
    }

    func testExcludedAppsManagerAddRemoveAndPresets() {
        let defaults = makeIsolatedDefaults()
        let manager = ExcludedAppsManager(defaults: defaults)

        XCTAssertTrue(manager.apps.isEmpty)

        // 添加应用
        manager.add(bundleIdentifier: "com.example.testapp", name: "TestApp")
        XCTAssertEqual(manager.apps.count, 1)
        XCTAssertTrue(manager.isExcluded(bundleIdentifier: "com.example.testapp"))
        XCTAssertTrue(manager.isExcluded(bundleIdentifier: "COM.EXAMPLE.TESTAPP"), "大小写不敏感匹配")

        // 重复添加相同 bundle id 应被忽略
        manager.add(bundleIdentifier: "com.example.testapp", name: "Duplicate TestApp")
        XCTAssertEqual(manager.apps.count, 1)

        // 添加预设密码管理器
        manager.addPresetPasswordManagers()
        XCTAssertTrue(manager.apps.count > 1)
        XCTAssertTrue(manager.isExcluded(bundleIdentifier: "com.1password.1password"))

        // 删除特定应用
        manager.remove(bundleIdentifier: "com.example.testapp")
        XCTAssertFalse(manager.isExcluded(bundleIdentifier: "com.example.testapp"))

        // 清空所有
        manager.removeAll()
        XCTAssertTrue(manager.apps.isEmpty)
        XCTAssertFalse(manager.isExcluded(bundleIdentifier: "com.1password.1password"))
    }
}
