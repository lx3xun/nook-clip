import XCTest
@testable import NookClip

@MainActor
final class PasteServiceTests: XCTestCase {

    override func tearDown() {
        PasteService.postKeyEventHook = nil
        PasteService.accessibilityTrustCheckerIsDefault = true
        PasteService.accessibilityTrustChecker = { AXIsProcessTrusted() }
        super.tearDown()
    }

    func testPastePlainTextWritesToClipboardAndTriggersKeyEvent() async throws {
        let defaults = makeIsolatedDefaults()
        let service = PasteService(defaults: defaults)

        var keyEventTriggered = false
        PasteService.postKeyEventHook = {
            keyEventTriggered = true
        }
        PasteService.accessibilityTrustCheckerIsDefault = false
        PasteService.accessibilityTrustChecker = { true }

        let item = ClipboardItem(type: .text, title: "Title", summary: "Hello PasteService")

        try await withPasteboardLock {
            let success = service.paste(item)
            XCTAssertTrue(success)

            let pb = PasteboardAccess.general
            XCTAssertEqual(pb.string(forType: .string), "Hello PasteService")
            XCTAssertTrue(pb.types?.contains(PasteService.internalMarker) == true)

            // 等待异步击键派发
            try await Task.sleep(nanoseconds: 180_000_000)
            XCTAssertTrue(keyEventTriggered, "辅助功能授权通过时应模拟击键")
        }
    }

    func testPasteTextWritesToClipboardAndTriggersKeyEvent() async throws {
        let defaults = makeIsolatedDefaults()
        let service = PasteService(defaults: defaults)

        var keyEventTriggered = false
        PasteService.postKeyEventHook = {
            keyEventTriggered = true
        }
        PasteService.accessibilityTrustCheckerIsDefault = false
        PasteService.accessibilityTrustChecker = { true }

        try await withPasteboardLock {
            let success = service.pasteText("Merged text 1\nMerged text 2")
            XCTAssertTrue(success)

            let pb = PasteboardAccess.general
            XCTAssertEqual(pb.string(forType: .string), "Merged text 1\nMerged text 2")

            try await Task.sleep(nanoseconds: 180_000_000)
            XCTAssertTrue(keyEventTriggered)
        }
    }

    func testPasteWithoutAccessibilityPermissionReturnsFalseAndNoKeyEvent() async throws {
        let defaults = makeIsolatedDefaults()
        let service = PasteService(defaults: defaults)

        var keyEventTriggered = false
        PasteService.postKeyEventHook = {
            keyEventTriggered = true
        }
        PasteService.accessibilityTrustCheckerIsDefault = false
        PasteService.accessibilityTrustChecker = { false }

        let item = ClipboardItem(type: .text, title: "Title", summary: "No Permission Text")

        try await withPasteboardLock {
            let success = service.paste(item)
            XCTAssertFalse(success, "未获得辅助功能权限时 paste 必须返回 false")

            let pb = PasteboardAccess.general
            XCTAssertEqual(pb.string(forType: .string), "No Permission Text", "即使不击键，剪贴板也应备好供手动 ⌘V")

            try await Task.sleep(nanoseconds: 180_000_000)
            XCTAssertFalse(keyEventTriggered, "未获权限时不应触发按键模拟")
        }
    }

    func testSensitiveDataTimeoutClearsClipboard() async throws {
        let defaults = makeIsolatedDefaults()
        // 设置极短自毁时间：1 秒
        defaults.set(1, forKey: "sensitiveClipboardTimeout")
        let service = PasteService(defaults: defaults)

        let secret = "sensitive-secret-\(UUID().uuidString)"

        try await withPasteboardLock {
            service.copyText(secret, containsSensitive: true)
            let pb = PasteboardAccess.general
            XCTAssertEqual(pb.string(forType: .string), secret)
            XCTAssertTrue(pb.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) == true)

            // 等待自毁计时触发 (1s + buffer)
            try await Task.sleep(nanoseconds: 1_200_000_000)
            XCTAssertNil(pb.string(forType: .string), "敏感数据自毁计时到期后剪贴板必须被清空")
        }
    }

    func testReferencedFilePathsForTextReturnsEmpty() {
        let textItem = ClipboardItem(type: .text, title: "Title", summary: "/tmp/some/file.txt")
        let paths = PasteService.referencedFilePaths(textItem)
        XCTAssertTrue(paths.isEmpty, "非文件类型条目不应解析出文件路径")
    }

    func testReferencedFilePathsForMultipleFiles() {
        let multiPath = "/tmp/file1.png\n/tmp/file2.png"
        let fileItem = ClipboardItem(type: .file, title: "Files", summary: multiPath, payloadPath: multiPath)
        let paths = PasteService.referencedFilePaths(fileItem)
        XCTAssertEqual(paths, ["/tmp/file1.png", "/tmp/file2.png"])
    }
}
