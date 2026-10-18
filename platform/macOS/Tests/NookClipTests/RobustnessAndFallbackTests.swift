import XCTest
import AppKit
@testable import NookClip

/// 极端异常、崩溃容错与降级兜底的实质性测试集
@MainActor
final class RobustnessAndFallbackTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        PasteboardAccess.useIsolatedNamedPasteboard()
    }

    // MARK: - 1. 钥匙串访问故障与降级内存库测试

    func testKeychainFailureFallsBackToMemoryStoreAndPreservesDiskDatabase() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nook_keychain_fallback_\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let validKeyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nook_valid_key_\(UUID().uuidString).key")
        defer { try? FileManager.default.removeItem(at: validKeyURL) }

        let validKeychain = KeychainCryptoService(
            keyFileURL: validKeyURL,
            keychainService: "test.valid.\(UUID().uuidString)",
            keychainBackupEnabled: false
        )
        let defaults = makeIsolatedDefaults()

        // 1. 先用正常钥匙串初始化生产库并写入条目
        let initialStore = RustHistoryStore.openProduction(
            databaseURL: dbURL,
            keychain: validKeychain,
            defaults: defaults
        )
        let item1 = ClipboardItem(type: .text, title: "Persisted Note", summary: "Saved content on disk")
        initialStore.save(item1)
        XCTAssertEqual(initialStore.page().count, 1)

        // 2. 模拟钥匙串完全损坏/不可访问（使用不可写入的只读非法路径触发 getOrCreateKey() == nil）
        let brokenKeyURL = URL(fileURLWithPath: "/dev/null/impossible_dir/master.key")
        let brokenKeychain = KeychainCryptoService(
            keyFileURL: brokenKeyURL,
            keychainService: "test.broken.\(UUID().uuidString)",
            keychainBackupEnabled: false
        )
        XCTAssertNil(brokenKeychain.getOrCreateKey(), "前置校验：损坏钥匙串必须返回 nil")

        // 3. 打开生产库：此时必须平稳降级为内存临时库，绝不可触发 fatalError，且绝不可损毁磁盘文件
        let fallbackStore = RustHistoryStore.openProduction(
            databaseURL: dbURL,
            keychain: brokenKeychain,
            defaults: defaults
        )
        // 内存库初始状态应为空
        XCTAssertEqual(fallbackStore.page().count, 0, "降级内存库不包含旧磁盘数据")

        // 内存库仍可正常写入操作
        let tempItem = ClipboardItem(type: .text, title: "Memory Item", summary: "Transient note")
        fallbackStore.save(tempItem)
        XCTAssertEqual(fallbackStore.page().count, 1)

        // 4. 关键安全断言：验证磁盘上的数据库文件完好无损，且原条目未被擦除
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path), "磁盘文件绝不可被删除")

        let recoveredStore = RustHistoryStore.openProduction(
            databaseURL: dbURL,
            keychain: validKeychain,
            defaults: defaults
        )
        let recoveredItems = recoveredStore.page()
        XCTAssertEqual(recoveredItems.count, 1, "恢复正常钥匙串后，磁盘上的条目必须完好存在")
        XCTAssertEqual(recoveredItems.first?.summary, "Saved content on disk")
    }

    // MARK: - 2. 磁盘资源缺失（Ghost Asset）防御测试

    func testGhostAssetGracefulHandlingInPasteAndWorkflow() throws {
        let store = makeIsolatedStore()
        let missingPath = NSTemporaryDirectory() + "ghost_deleted_image_\(UUID().uuidString).png"

        // 构造一个在数据库中有记录、但磁盘物理文件已丢失的图片条目
        let ghostItem = ClipboardItem(
            type: .image,
            title: "Ghost Image",
            summary: "Missing image file",
            payloadPath: missingPath
        )
        store.save(ghostItem)

        let pasteService = PasteService.shared
        // 1. copyOnly 必须安全返回 false，不可崩溃，也不得把损坏垃圾写入剪贴板
        let copySuccess = pasteService.copyOnly(ghostItem)
        XCTAssertFalse(copySuccess, "丢失载荷文件的图片条目复制必须安全返回 false")

        // 2. paste 必须安全返回 false，不得触发键盘模拟事件
        let pasteSuccess = pasteService.paste(ghostItem)
        XCTAssertFalse(pasteSuccess, "丢失载荷文件的图片条目粘贴必须安全返回 false")

        // 3. 底层 preparePastePayload 必须抛出明确的 CorruptedImagePayload 错误
        let rustStore = store.rustStore
        XCTAssertThrowsError(
            try rustStore.engine.preparePastePayload(id: ghostItem.id.uuidString, plainTextOnly: false)
        ) { error in
            guard let nookError = error as? NookClipError,
                  case .CorruptedImagePayload = nookError else {
                XCTFail("预期抛出 CorruptedImagePayload，实际抛出: \(error)")
                return
            }
        }
    }

    // MARK: - 3. 辅助功能运行期动态撤销测试

    func testDynamicAccessibilityRevocationDuringPaste() async throws {
        let originalChecker = PasteService.accessibilityTrustChecker
        let originalPrompter = PasteService.accessibilityPermissionPrompter
        let originalIsDefault = PasteService.accessibilityTrustCheckerIsDefault
        defer {
            PasteService.accessibilityTrustChecker = originalChecker
            PasteService.accessibilityPermissionPrompter = originalPrompter
            PasteService.accessibilityTrustCheckerIsDefault = originalIsDefault
            PasteService.postKeyEventHook = nil
        }
        PasteService.accessibilityTrustCheckerIsDefault = false

        // 1. 模拟初始处于受信任状态
        PasteService.accessibilityTrustChecker = { true }
        var keyEventPosted = false
        PasteService.postKeyEventHook = { keyEventPosted = true }

        let success1 = PasteService.shared.pasteText("Initial text", targetApplication: nil)
        XCTAssertTrue(success1)
        try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertTrue(keyEventPosted, "已授权时必须成功触发模拟按键")

        // 2. 模拟用户在应用运行期间，前往系统设置关闭了辅助功能权限
        PasteService.accessibilityTrustChecker = { false }
        var promptTriggered = false
        PasteService.accessibilityPermissionPrompter = {
            promptTriggered = true
            return false
        }

        keyEventPosted = false
        let success2 = PasteService.shared.pasteText("Denied text", targetApplication: nil)

        // 必须返回 false，触发引导弹窗，且绝不盲目发送按键
        XCTAssertFalse(success2, "辅助功能被撤销后粘贴必须返回 false")
        XCTAssertTrue(promptTriggered, "必须主动向用户触发系统辅助功能授权引导")
        XCTAssertFalse(keyEventPosted, "未授权状态下绝不可模拟按键")

        // 保护策略：文本依然要安全写入剪贴板，避免用户丢失所选文本
        let pb = PasteboardAccess.general
        XCTAssertEqual(pb.string(forType: .string), "Denied text", "粘贴失败时文本仍需写入剪贴板保底")
    }

    // MARK: - 4. 剪贴板监听高频风暴与背压队列测试

    func testRapidBurstClipboardMonitorQueue() async throws {
        let store = makeIsolatedStore()
        let rustEngine = store.rustStore.engine
        let monitor = ClipboardMonitor(rustEngine: rustEngine)

        var capturedItems: [ClipboardItem] = []
        monitor.onChange = { item in
            capturedItems.append(item)
        }

        let pb = PasteboardAccess.general
        // 快速模拟连续 10 次外部复制事件（每次写入不同内容并触发 poll）
        for i in 1...10 {
            pb.clearContents()
            pb.setString("Burst Item Text #\(i)", forType: .string)
            monitor.poll()
        }

        // 等待后台 captureChain 异步串行队列全部排空落库
        // 轮询直到 10 个条目全部处理完毕，或最多等待 3 秒
        let deadline = Date().addingTimeInterval(3.0)
        while capturedItems.count < 10 && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }

        XCTAssertEqual(capturedItems.count, 10, "高频突发复制事件必须全部被串行捕获，不能丢单")
        let dbItems = store.rustStore.page(limit: 20)
        XCTAssertGreaterThanOrEqual(dbItems.count, 10, "数据库中必须保存了全部突发条目")
    }
}
