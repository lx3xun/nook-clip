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
        XCTAssertEqual(SettingsTab.allCases.count, 6)
    }

    func testSettingsViewRendersAllTabsWithoutCrashing() {
        let store = makeIsolatedStore()
        for tab in SettingsTab.allCases {
            let settingsView = SettingsView(historyStore: store, initialTab: tab)
            let host = renderView(settingsView)
            // 方案 C 的外壳不再使用 tag 0 做锚点，改为断言视图树真的展开了：
            // 每个 tab 都必须渲染出侧栏 + 画布两棵子树
            XCTAssertFalse(host.subviews.isEmpty, "\(tab.rawValue) 页应渲染出视图树")
            XCTAssertGreaterThan(host.fittingSize.width, 0, "\(tab.rawValue) 页应有可测量的宽度")
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

    /// 历史清理维度已从「保留天数」换成「最大记录条数」：
    /// 新文案三语齐备、旧档位文案彻底退役、设置页仍能正常渲染
    func testHistorySettingsTabUsesMaxItemCountInsteadOfRetentionDays() {
        let retiredKeys = [
            "settings.general.history_retention",
            "settings.retention.day",
            "settings.retention.week",
            "settings.retention.month",
            "settings.retention.quarter",
            "settings.retention.half_year",
            "settings.retention.year"
        ]
        for language in ["zh-Hans", "zh-Hant", "en"] {
            guard let path = Bundle.module.path(forResource: language, ofType: "lproj"),
                  let bundle = Bundle(path: path) else {
                XCTFail("缺少语言包: \(language)")
                continue
            }
            XCTAssertNotEqual(bundle.localizedString(forKey: "settings.general.history_max_items", value: nil, table: nil),
                              "settings.general.history_max_items", "\(language) 缺少条数上限文案")
            for key in retiredKeys {
                XCTAssertEqual(bundle.localizedString(forKey: key, value: nil, table: nil), key,
                               "\(language) 仍残留已退役的保留天数文案: \(key)")
            }
        }

        // 「无限制」已退役：档位封顶在硬上限 1000 条，且不提供 0 档
        XCTAssertEqual(HistoryMaxItemsPolicy.presets, [100, 200, 500, 1000])
        XCTAssertEqual(HistoryMaxItemsPolicy.presets.last, HistoryMaxItemsPolicy.hardCap,
                       "最高档必须就是硬上限")
        XCTAssertTrue(HistoryMaxItemsPolicy.presets.contains(HistoryMaxItemsPolicy.defaultMaxItems),
                      "默认值必须落在可选档位内，否则 Picker 无对应项")
        XCTAssertFalse(HistoryMaxItemsPolicy.presets.contains(0),
                       "条数 Picker 不得再提供「无限制」档位")
        // 磁盘上限同样退役「无限制」，档位为 512MB/1GB/2GB/5GB/10GB/20GB
        XCTAssertEqual(DiskLimitPolicy.presets, [512, 1024, 2048, 5120, 10240, 20480])
        XCTAssertTrue(DiskLimitPolicy.presets.contains(DiskLimitPolicy.defaultLimitMB),
                      "磁盘默认值必须落在可选档位内")
        XCTAssertEqual(DiskLimitPolicy.presets.last, DiskLimitPolicy.hardCapMB)

        let store = makeIsolatedStore()
        let host = renderView(HistorySettingsTab(historyStore: store))
        XCTAssertNotNil(host, "改用条数上限后设置页必须仍能渲染")
    }

    /// 条数上限的档位文案必须真的来自本地化表（不是回退到 key 原文），
    /// 且旧的天数档位文案彻底不存在
    func testHistorySettingsTabMaxItemsPickerOptions() {
        // 「无限制」文案仍被敏感剪贴板超时档位复用，故保留翻译；但条数/磁盘 Picker 不再引用
        let unlimited = L10n.tr("settings.retention.unlimited")
        XCTAssertFalse(unlimited.isEmpty)

        for count in HistoryMaxItemsPolicy.presets {
            let label = L10n.tr("clipboard.items_count", count)
            let digits = label.filter(\.isNumber)
            let expected = "\(count)".filter(\.isNumber)
            XCTAssertEqual(digits, expected, "档位 \(count) 的文案数字应匹配（允许千分位）: \(label)")
            XCTAssertFalse(label.hasPrefix("clipboard."), "档位文案不得回退成 key 原文: \(label)")
        }
        XCTAssertFalse(unlimited.hasPrefix("settings."), "「无限制」文案不得回退成 key 原文")
        XCTAssertFalse(HistoryMaxItemsPolicy.presets.contains(0), "条数档位不得再含「无限制」")
        XCTAssertFalse(DiskLimitPolicy.presets.contains(0), "磁盘档位不得再含「无限制」")

        // 旧天数档位（半天/季度等）已从词表移除，任何语言都不该再解析出中文/英文档位名
        for retired in ["settings.retention.half_year", "settings.retention.quarter", "settings.retention.day"] {
            XCTAssertEqual(L10n.tr(retired), retired, "已退役档位文案不应再有翻译: \(retired)")
        }
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
