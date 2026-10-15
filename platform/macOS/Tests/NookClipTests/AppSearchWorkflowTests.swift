import SwiftUI
import XCTest
@testable import NookClip

final class AppSearchWorkflowTests: XCTestCase {
    final class MockWriter: ClipboardWriter {
        func copyOnly(_ item: ClipboardItem, plainTextOnly: Bool) -> Bool { true }
        func copyText(_ text: String, containsSensitive: Bool) -> Bool { true }
        func paste(_ item: ClipboardItem, targetApplication: NSRunningApplication?, plainTextOnly: Bool) -> Bool { true }
        func pasteText(_ text: String, targetApplication: NSRunningApplication?, containsSensitive: Bool) -> Bool { true }
        func clearClipboardIfContent(matches plainText: String) {}
        func staleFileMessage(for item: ClipboardItem) -> String? { nil }
    }

    @MainActor
    func testMainViewUpdateAppSearchResults() {
        let store = makeIsolatedStore()
        let view = MainView(
            store: store,
            clipboardWriter: MockWriter()
        )

        XCTAssertTrue(view.matchedApps.isEmpty)
        XCTAssertNil(view.selectedAppID)

        // 模拟搜索已安装应用，例如 Safari
        view.updateAppSearchResults(query: "safari")
        // 本机通常都有 Safari.app
        if !view.matchedApps.isEmpty {
            XCTAssertNotNil(view.selectedAppID)
            XCTAssertEqual(view.selectedAppID, view.matchedApps.first?.id)
            XCTAssertNil(view.selectionCoordinator.selectedID)
        }

        // 清空搜索
        view.updateAppSearchResults(query: "")
        XCTAssertTrue(view.matchedApps.isEmpty)
        XCTAssertNil(view.selectedAppID)
    }

    @MainActor
    func testAppSelectionNavigationClampsWhenClipboardEmpty() {
        let listState = MainViewListState(store: makeIsolatedStore())

        let app1 = InstalledApp(
            id: "app.test.1",
            name: "App One",
            path: "/Applications/App1.app",
            url: URL(fileURLWithPath: "/Applications/App1.app")
        )
        let app2 = InstalledApp(
            id: "app.test.2",
            name: "App Two",
            path: "/Applications/App2.app",
            url: URL(fileURLWithPath: "/Applications/App2.app")
        )

        listState.matchedApps = [app1, app2]
        listState.selectedAppID = app1.id
        // 向下移动选择第二个 App
        let handled1 = listState.handleAppNavigation(offset: 1)
        XCTAssertTrue(handled1)
        XCTAssertEqual(listState.selectedAppID, app2.id)

        // 当剪贴板无匹配结果（flatRows 为空）时，继续按 ↓ 应保持在最后一个应用，不进入虚空选中态
        let handled2 = listState.handleAppNavigation(offset: 1)
        XCTAssertTrue(handled2)
        XCTAssertEqual(listState.selectedAppID, app2.id)

        // 向上移动到首个 App
        let handled3 = listState.handleAppNavigation(offset: -1)
        XCTAssertTrue(handled3)
        XCTAssertEqual(listState.selectedAppID, app1.id)
    }

    @MainActor
    func testAppAndClipboardSelectionMutualExclusionAndSyncGuard() {
        let listState = MainViewListState(store: makeIsolatedStore())
        let app = InstalledApp(
            id: "app.test.1",
            name: "App One",
            path: "/Applications/App1.app",
            url: URL(fileURLWithPath: "/Applications/App1.app")
        )
        let clipItem = ClipboardItem(type: .text, title: "Clip", summary: "Hello")
        let clipRow = ClipboardRowModel(item: clipItem)

        listState.matchedApps = [app]
        listState.selectedAppID = app.id

        // 1. 异步过滤管线到达调用 syncWithFilter 时，不应覆盖已选中的 App
        listState.syncWithFilter(rows: [clipRow])
        XCTAssertEqual(listState.selectedAppID, app.id)
        XCTAssertNil(listState.selectedID)

        // 2. 用户点击剪贴板条目时，应自动清除 selectedAppID
        listState.handleTap(clipRow, rows: [clipRow], shiftHeld: false, commandHeld: false)
        XCTAssertEqual(listState.selectedID, clipRow.id)
        XCTAssertNil(listState.selectedAppID)

        // 3. 重新选中 App 时，应自动清除剪贴板 selectedID 与批量多选
        listState.selectedAppID = app.id
        XCTAssertEqual(listState.selectedAppID, app.id)
        XCTAssertNil(listState.selectedID)
    }

    @MainActor
    func testResetSessionStateClearsApps() {
        let store = makeIsolatedStore()
        let view = MainView(
            store: store,
            clipboardWriter: MockWriter()
        )

        view.listState.matchedApps = [
            InstalledApp(
                id: "app.test",
                name: "Test App",
                path: "/Applications/Test.app",
                url: URL(fileURLWithPath: "/Applications/Test.app")
            )
        ]
        view.listState.selectedAppID = "app.test"
        view.listState.setSearchText("test", dataVersion: store.dataVersion)

        view.resetSessionState()

        XCTAssertTrue(view.matchedApps.isEmpty)
        XCTAssertNil(view.selectedAppID)
        XCTAssertEqual(view.listState.searchText, "")
    }

    @MainActor
    func testAppSearchRestrictedToAllCategoryOnly() {
        let store = makeIsolatedStore()
        let listState = MainViewListState(store: store)

        // 1. 默认「全部」分类 (categorySelection == 0) 下搜索，可匹配应用程序
        listState.setSearchText("safari", dataVersion: store.dataVersion)
        let matchedInAll = listState.matchedApps

        // 2. 切换到「文本」分类 (categorySelection == 2) 时，应自动清空应用程序匹配结果
        listState.setCategorySelection(2, dataVersion: store.dataVersion)
        XCTAssertTrue(listState.matchedApps.isEmpty, "非『全部』分类下不应混入应用程序搜索结果")
        XCTAssertNil(listState.selectedAppID)

        // 3. 在非「全部」分类下继续输入搜索词，同样不应匹配应用程序
        listState.setSearchText("finder", dataVersion: store.dataVersion)
        XCTAssertTrue(listState.matchedApps.isEmpty)
        XCTAssertNil(listState.selectedAppID)

        // 4. 切回「全部」分类 (0) 时，若搜索框非空则恢复匹配应用程序
        listState.setSearchText("safari", dataVersion: store.dataVersion)
        listState.setCategorySelection(0, dataVersion: store.dataVersion)
        XCTAssertEqual(listState.matchedApps.count, matchedInAll.count)
    }

    @MainActor
    func testAppRowViewRendersSelectedAndUnselected() {
        let app = InstalledApp(
            id: "com.apple.airport.airportutility",
            name: "AirPort 实用工具",
            path: "/System/Applications/Utilities/AirPort Utility.app",
            url: URL(fileURLWithPath: "/System/Applications/Utilities/AirPort Utility.app")
        )

        let unselectedRow = AppRowView(
            app: app,
            isSelected: false,
            highlightKeywords: ["a"]
        )
        let unselectedHost = NSHostingView(rootView: unselectedRow)
        unselectedHost.frame = NSRect(x: 0, y: 0, width: 300, height: 50)
        unselectedHost.layoutSubtreeIfNeeded()
        XCTAssertNotNil(unselectedHost)

        let selectedRow = AppRowView(
            app: app,
            isSelected: true,
            highlightKeywords: ["a"]
        )
        let selectedHost = NSHostingView(rootView: selectedRow)
        selectedHost.frame = NSRect(x: 0, y: 0, width: 300, height: 50)
        selectedHost.layoutSubtreeIfNeeded()
        XCTAssertNotNil(selectedHost)
    }
}
