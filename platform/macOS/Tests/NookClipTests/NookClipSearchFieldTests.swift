import XCTest
import SwiftUI
@testable import NookClip

final class NookClipSearchFieldTests: XCTestCase {
    @MainActor
    func testSearchFieldInitializationAndDefaults() {
        var text = "hello"
        let binding = Binding(get: { text }, set: { text = $0 })
        let searchField = NookClipSearchField(text: binding)
        XCTAssertEqual(searchField.text, "hello")
        XCTAssertEqual(searchField.placeholder, L10n.tr("search.placeholder"))
    }

    @MainActor
    func testSearchFieldLeadingPaddingConstant() {
        // 契约：搜索文字与内容保持 14pt 统一左对齐基准线
        XCTAssertEqual(NookClip.searchContentLeadingPadding, 14, "搜索内容与下方列表统一为 14pt 安全缩进")
    }

    @MainActor
    func testSearchFieldHosting() {
        var text = ""
        let binding = Binding(get: { text }, set: { text = $0 })
        let host = NSHostingView(rootView: NookClipSearchField(text: binding))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNotNil(host.window)
    }
}
