import AppKit
import XCTest
@testable import NookClip

/// 双栏面板呼出与宽度恢复测试：
/// 面板常驻双栏（最小 580，最大 1400），show() 必须恢复保存的 panelWidth。
final class PanelPreviewStateRestoreTests: XCTestCase {
    /// 记录受影响键并在 teardown 恢复（QuickPopoverController 直接读 standard 域）
    @discardableResult
    private func snapshotDefaultsKeys(_ keys: [String]) -> [String: Any?] {
        var snapshot: [String: Any?] = [:]
        for key in keys {
            snapshot[key] = UserDefaults.standard.object(forKey: key)
        }
        addTeardownBlock {
            for (key, value) in snapshot {
                if let value {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }
        return snapshot
    }

    /// 找到本次 controller.toggle() 新建的面板（控制器持有面板句柄；
    /// delegate 已随红绿灯逻辑移除，不可再作标识）
    @MainActor
    private func panelCreated(by controller: QuickPopoverController) -> DraggablePanel? {
        controller.panel as? DraggablePanel
    }

    @MainActor
    func testPanelOpensWithDefaultWidthAndConstraints() {
        snapshotDefaultsKeys(["panelWidth"])
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "panelWidth")

        let store = makeIsolatedStore()
        let controller = QuickPopoverController(historyStore: store, targetApplicationProvider: { nil }, clipboardWriter: PasteService.shared)

        controller.toggle()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        guard let panel = panelCreated(by: controller) else {
            return XCTFail("面板应已创建")
        }
        XCTAssertEqual(panel.frame.width, PanelGeometry.expandedDefaultWidth, "无历史记录时应为默认展开宽度 750")
        XCTAssertEqual(panel.currentMinPanelWidth, PanelGeometry.expandedMinWidth)
        XCTAssertEqual(panel.currentMaxPanelWidth, PanelGeometry.expandedMaxWidth)
    }

    @MainActor
    func testReopenRespectsSavedCustomWidth() {
        snapshotDefaultsKeys(["panelWidth"])
        let defaults = UserDefaults.standard
        defaults.set(880.0, forKey: "panelWidth")

        let store = makeIsolatedStore()
        let controller = QuickPopoverController(historyStore: store, targetApplicationProvider: { nil }, clipboardWriter: PasteService.shared)

        controller.toggle()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        guard let panel = panelCreated(by: controller) else {
            return XCTFail("面板应已创建")
        }
        XCTAssertEqual(panel.frame.width, 880.0, "应恢复手动保存的面板宽度")
        XCTAssertEqual(panel.currentMinPanelWidth, PanelGeometry.expandedMinWidth)
        XCTAssertEqual(panel.currentMaxPanelWidth, PanelGeometry.expandedMaxWidth)
    }
}
