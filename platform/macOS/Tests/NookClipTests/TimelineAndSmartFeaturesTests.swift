import AppKit
import SwiftUI
import XCTest
@testable import NookClip

final class TimelineAndSmartFeaturesTests: XCTestCase {
    func testSmartExtractorLanguageClassification() {
        let engine = (try! RustHistoryStore(path: ":memory:", encryptionKey: Data(repeating: 0x42, count: 32))).engine
        let swiftCode = """
        public class ChengQiApiApplication {
            func start() {}
        }
        """
        let extracted = engine.analyzeContent(text: swiftCode)
        XCTAssertEqual(extracted.detectedLanguage, "swift")

        let javaFunc = """
        public ResponseDTO<Void> loginUser(LoginRequest req) {
            return ResponseDTO.ok();
        }
        """
        let extractedFunc = engine.analyzeContent(text: javaFunc)
        XCTAssertNotEqual(extractedFunc.detectedLanguage, "swift")
    }

    func testSmartExtractorURLMetadata() {
        let engine = (try! RustHistoryStore(path: ":memory:", encryptionKey: Data(repeating: 0x42, count: 32))).engine
        let urlText = "https://github.com/apple/swift"
        let extracted = engine.analyzeContent(text: urlText)
        XCTAssertTrue(extracted.isUrl)
    }

    func testSmartExtractorPlainTextNotCode() {
        let engine = (try! RustHistoryStore(path: ":memory:", encryptionKey: Data(repeating: 0x42, count: 32))).engine
        let text = """
        第一行标题内容
        第二行细节描述
        第三行更多内容
        """
        let extracted = engine.analyzeContent(text: text)
        XCTAssertNil(extracted.detectedLanguage)
    }


    @MainActor
    func testSearchQueryParserWithAppMatchesDirectly() {
        let keywords = tokenizeSearchKeywords(query: "Code payment")
        XCTAssertEqual(keywords, ["Code", "payment"])

        let store = makeIsolatedStore()
        let item = ClipboardItem(
            type: .text,
            title: "ProcessPayment",
            summary: "payment handler",
            sourceAppName: "Visual Studio Code"
        )
        store.save(item)
        XCTAssertEqual(store.rustStore.search(query: "Code payment").count, 1)
    }


    @MainActor
    func testMultiItemDeletionRestoreAndPermanentDelete() {
        let dbPath = NSTemporaryDirectory() + "test_batch_delete_\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let store = makeIsolatedStore()

        let item1 = ClipboardItem(type: .text, title: "Item 1", summary: "Content 1")
        let item2 = ClipboardItem(type: .text, title: "Item 2", summary: "Content 2")
        let item3 = ClipboardItem(type: .text, title: "Item 3", summary: "Content 3")

        store.save(item1)
        store.save(item2)
        store.save(item3)

        XCTAssertTrue(store.items.contains(where: { $0.id == item1.id }))
        XCTAssertTrue(store.items.contains(where: { $0.id == item2.id }))
        XCTAssertTrue(store.items.contains(where: { $0.id == item3.id }))

        // 批量删除 = 移入回收站（软删除）
        store.deleteMultiple([item1.id, item2.id])
        XCTAssertFalse(store.items.contains(where: { $0.id == item1.id }))
        XCTAssertFalse(store.items.contains(where: { $0.id == item2.id }))
        XCTAssertTrue(store.items.contains(where: { $0.id == item3.id }))
        XCTAssertEqual(store.trashItems.count, 2)
        XCTAssertNotNil(store.trashItems.first?.deletedAt)

        // 回收站恢复：回到活跃列表
        store.restoreFromTrash([item1.id, item2.id])
        XCTAssertTrue(store.items.contains(where: { $0.id == item1.id }))
        XCTAssertTrue(store.items.contains(where: { $0.id == item2.id }))
        XCTAssertTrue(store.items.contains(where: { $0.id == item3.id }))
        XCTAssertTrue(store.trashItems.isEmpty)

        // 再删一次后窗口过期清除：本地与数据库都消失（写墓碑）
        store.deleteMultiple([item1.id, item2.id])
        store.purgeExpiredTrash(now: Date().addingTimeInterval(TrashPurgeWindow.grace + 1))
        XCTAssertFalse(store.items.contains(where: { $0.id == item1.id }))
        XCTAssertFalse(store.trashItems.contains(where: { $0.id == item1.id }))
        XCTAssertFalse(store.rustStore.page(limit: 10, offset: 0).contains(where: { $0.id == item1.id || $0.id == item2.id }))
    }

    /// markUsed 合并数据库中的重复行：保留收藏、物理行合一；
    /// 软删除与恢复不写墓碑，彻底删除才写（C5 契约）。
    /// 注：读取层（items(from:)）按内容去重，重复行的代表是 lastUsedAt 最新者。
    @MainActor
    func testMarkUsedMergesDuplicatesKeepingFavorite() async throws {
        let syncDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NookMarkUsedTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: syncDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: syncDir) }
        let engine = ICloudDriveSyncEngine(customBaseURL: syncDir, defaults: makeIsolatedDefaults())
        engine.isEnabled = true

        // 直接写库预置两条内容重复的行（绕开 store 层 save 去重）：
        let store = makeIsolatedStore(syncEngine: engine)
        let newer = Date().addingTimeInterval(60)
        let favorite = ClipboardItem(
            type: .text, title: "收藏副本", summary: "markused_needle",
            createdAt: newer, lastUsedAt: newer, isFavorite: true
        )
        let plain = ClipboardItem(type: .text, title: "普通副本", summary: "markused_needle")
        store.save(favorite)
        store.save(plain)
        XCTAssertEqual(store.items.count, 1, "读取层按内容去重，页面只见一条")

        // markUsed：合并重复行——物理行合一，合并结果保留任一重复行的收藏状态
        store.markUsed(plain.id)
        XCTAssertEqual(store.items.count, 1, "markUsed 后仍只有一条")
        XCTAssertTrue(store.items[0].isFavorite, "合并应保留任一重复行的收藏状态")
        XCTAssertEqual(store.rustStore.page(limit: 10, offset: 0).count, 1, "存储层物理行合并为一行")
    }
}
