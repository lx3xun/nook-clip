import AppKit
import XCTest
@testable import NookClip

/// 面板不得出现任何 macOS 标准窗口按钮（红/黄/绿）：
/// - 红/黄键靠 styleMask 不含 .closable / .miniaturizable
/// - 绿键跟随 .resizable 出现，必须显式 isHidden（曾因误删隐藏线回归）
/// - 关闭只走 Esc / 外部点击的 close() 路径
final class PanelWindowButtonsHiddenTests: XCTestCase {
    @MainActor
    func testPanelHidesAllStandardWindowButtons() {
        let store = makeIsolatedStore()
        let controller = QuickPopoverController(
            historyStore: store,
            targetApplicationProvider: { nil },
            clipboardWriter: PasteService.shared
        )
        controller.toggle()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        guard let panel = controller.panel else {
            return XCTFail("面板应已创建")
        }
        XCTAssertNil(
            panel.standardWindowButton(.closeButton).flatMap { $0.isHidden ? nil : $0 },
            "红键不得可见"
        )
        XCTAssertNil(
            panel.standardWindowButton(.miniaturizeButton).flatMap { $0.isHidden ? nil : $0 },
            "黄键不得可见"
        )
        XCTAssertNil(
            panel.standardWindowButton(.zoomButton).flatMap { $0.isHidden ? nil : $0 },
            "绿键不得可见"
        )
        XCTAssertFalse(
            panel.styleMask.contains(.closable),
            "styleMask 不应包含 .closable（关闭不走系统红键）"
        )
    }
}
