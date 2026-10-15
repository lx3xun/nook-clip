import XCTest
@testable import NookClip

@MainActor
final class HistoryLifecycleServiceTests: XCTestCase {
    func testHardDeletePurgesItemFromStorage() throws {
        let rustStore = try RustHistoryStore(path: ":memory:", encryptionKey: Data(repeating: 0x42, count: 32))

        let item1 = ClipboardItem(type: .text, title: "A", summary: "Content A", payloadPath: "/tmp/a.txt")
        let item2 = ClipboardItem(type: .text, title: "B", summary: "Content B", payloadPath: "/tmp/b.txt")
        XCTAssertNotNil(rustStore.save(item1))
        XCTAssertNotNil(rustStore.save(item2))

        XCTAssertTrue(rustStore.purge(item1.id))
        XCTAssertNil(rustStore.item(id: item1.id), "purge 必须从 SQLite 中彻底清除记录")
        XCTAssertNotNil(rustStore.item(id: item2.id), "其他条目不得受影响")
    }

    func testExpiredTrashFiltersByGraceWindow() {
        let now = Date()
        let oldDeletedAt = now.addingTimeInterval(-TrashPurgeWindow.grace * 2)
        let freshDeletedAt = now.addingTimeInterval(-10)

        var oldItem = ClipboardItem(type: .text, title: "Old", summary: "Old deleted")
        oldItem.deletedAt = oldDeletedAt

        var freshItem = ClipboardItem(type: .text, title: "Fresh", summary: "Fresh deleted")
        freshItem.deletedAt = freshDeletedAt

        let expired = InMemoryHistoryStore.expiredTrash(in: [oldItem, freshItem], now: now)
        XCTAssertEqual(expired.count, 1)
        XCTAssertEqual(expired.first?.id, oldItem.id, "仅超过撤销宽限期的软删除条目被判定为过期")
    }

    func testDiskLimitEvictionsFollowsLRUAndExemptsFavorites() throws {
        let rustStore = try RustHistoryStore(path: ":memory:", encryptionKey: Data(repeating: 0x42, count: 32))

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("nook_lru_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileSize: Int = 1_500_000
        let dummyData = Data(repeating: 0xAA, count: fileSize)

        let pathFav = tempDir.appendingPathComponent("fav.bin").path
        let pathOld = tempDir.appendingPathComponent("old.bin").path
        let pathNew = tempDir.appendingPathComponent("new.bin").path

        try dummyData.write(to: URL(fileURLWithPath: pathFav))
        try dummyData.write(to: URL(fileURLWithPath: pathOld))
        try dummyData.write(to: URL(fileURLWithPath: pathNew))

        let favItem = ClipboardItem(
            type: .file,
            title: "Fav",
            summary: "Favorite",
            createdAt: Date().addingTimeInterval(-3600 * 10),
            lastUsedAt: Date().addingTimeInterval(-3600 * 10),
            isFavorite: true,
            payloadPath: pathFav
        )
        let oldItem = ClipboardItem(
            id: UUID(),
            type: .file,
            title: "Old",
            summary: "Old normal",
            createdAt: Date().addingTimeInterval(-3600),
            lastUsedAt: Date().addingTimeInterval(-3600),
            isFavorite: false,
            payloadPath: pathOld
        )
        let newItem = ClipboardItem(
            id: UUID(),
            type: .file,
            title: "New",
            summary: "New normal",
            createdAt: Date(),
            lastUsedAt: Date(),
            isFavorite: false,
            payloadPath: pathNew
        )

        XCTAssertNotNil(rustStore.save(favItem))
        XCTAssertNotNil(rustStore.save(oldItem))
        XCTAssertNotNil(rustStore.save(newItem))

        let evictions = rustStore.enforceDiskLimit(managedDir: tempDir.path, limitMB: 2)

        XCTAssertFalse(evictions.contains { $0.id == favItem.id.uuidString }, "收藏条目必须豁免磁盘限额淘汰")
        XCTAssertTrue(evictions.contains { $0.id == oldItem.id.uuidString }, "最久未使用的非收藏项必须被淘汰")
        XCTAssertEqual(evictions.first?.id, oldItem.id.uuidString, "淘汰列表首项必须为最久未使用的条目 (LRU)")
        XCTAssertNil(rustStore.item(id: oldItem.id), "被淘汰条目已从 SQLite 物理删除")
        XCTAssertNotNil(rustStore.item(id: favItem.id), "收藏条目保留")
    }
}
