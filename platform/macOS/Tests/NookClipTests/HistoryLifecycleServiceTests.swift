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

    func testMaxItemsPolicyDefaultsTo500() {
        let defaults = makeIsolatedDefaults()
        let policy = HistoryMaxItemsPolicy(defaults: defaults)
        XCTAssertEqual(policy.maxItems, 500, "未设置 historyMaxItemCount 时默认应为 500 条")
        XCTAssertEqual(HistoryMaxItemsPolicy.defaultMaxItems, 500)

        defaults.set(1000, forKey: HistoryMaxItemsPolicy.defaultsKey)
        XCTAssertEqual(HistoryMaxItemsPolicy(defaults: defaults).maxItems, 1000, "用户显式档位必须被读回")
    }

    /// 「无限制」已退役：0/负数与超硬上限的遗留值都必须收敛到硬上限 1000 条
    func testMaxItemsPolicyClampsRetiredUnlimitedToHardCap() {
        let defaults = makeIsolatedDefaults()
        defaults.set(0, forKey: HistoryMaxItemsPolicy.defaultsKey)
        XCTAssertEqual(HistoryMaxItemsPolicy(defaults: defaults).maxItems, 1000,
                       "旧版「无限制」迁移为硬上限 1000 条")
        XCTAssertEqual(HistoryMaxItemsPolicy(maxItems: 0).maxItems, 1000, "构造函数同语义收敛")
        XCTAssertEqual(HistoryMaxItemsPolicy(maxItems: -5).maxItems, 1000, "负数同样收敛到硬上限")
        XCTAssertEqual(HistoryMaxItemsPolicy(maxItems: 5000).maxItems, 1000, "超过硬上限的档位被收敛")
        XCTAssertEqual(HistoryMaxItemsPolicy(maxItems: 200).maxItems, 200, "合法档位原样保留")

        // 硬上限即最高档位：档位表不得再出现「无限制」或超过硬上限的值
        XCTAssertEqual(HistoryMaxItemsPolicy.hardCap, 1000)
        XCTAssertEqual(HistoryMaxItemsPolicy.presets, [100, 200, 500, 1000])
        XCTAssertEqual(HistoryMaxItemsPolicy.presets.last, HistoryMaxItemsPolicy.hardCap)
        XCTAssertFalse(HistoryMaxItemsPolicy.presets.contains(0), "档位表不得含「无限制」")
        XCTAssertFalse(HistoryMaxItemsPolicy.presets.contains(5000), "档位表不得含超过硬上限的档位")
    }

    /// 旧版「保留天数 = 0（无限制）」的用户升级后不能被突然裁到默认 500 条
    func testMaxItemsPolicyMigratesLegacyUnlimitedRetention() {
        let defaults = makeIsolatedDefaults()
        defaults.set(0, forKey: HistoryMaxItemsPolicy.legacyRetentionDaysKey)
        XCTAssertEqual(HistoryMaxItemsPolicy(defaults: defaults).maxItems, 1000,
                       "旧版显式关闭清理的用户迁移为硬上限（尽可能多保留）")

        // 旧版用过任何正数天数 → 走新版默认档位（取消按天清理，改用条数上限）
        let legacy = makeIsolatedDefaults()
        legacy.set(180, forKey: HistoryMaxItemsPolicy.legacyRetentionDaysKey)
        XCTAssertEqual(HistoryMaxItemsPolicy(defaults: legacy).maxItems, 500,
                       "旧版按天数清理的用户迁移为默认 500 条")

        // 新键一旦写入，旧键不再有影响
        defaults.set(200, forKey: HistoryMaxItemsPolicy.defaultsKey)
        XCTAssertEqual(HistoryMaxItemsPolicy(defaults: defaults).maxItems, 200,
                       "新键优先于旧键")
    }

    func testDiskLimitPolicyDefaultLimitIs5GB() {
        let defaults = makeIsolatedDefaults()
        let policy = DiskLimitPolicy(defaults: defaults)
        XCTAssertEqual(policy.limitMB, 5120, "未设置 historyDiskLimitMB 时默认应为 5120MB（5GB）")
        XCTAssertEqual(DiskLimitPolicy.defaultLimitMB, 5120)
        XCTAssertEqual(policy.maxDiskBytes, 5120 * 1024 * 1024)

        XCTAssertEqual(DiskLimitPolicy.presets, [512, 1024, 2048, 5120, 10240, 20480],
                       "磁盘档位为 512MB/1GB/2GB/5GB/10GB/20GB，不含「无限制」")
        XCTAssertEqual(DiskLimitPolicy.presets.last, DiskLimitPolicy.hardCapMB)
    }

    /// 「无限制」已退役：磁盘上限 0/负数与超最大档的遗留值都收敛到最大档 20GB
    func testDiskLimitPolicyClampsRetiredUnlimitedToHardCap() {
        let defaults = makeIsolatedDefaults()
        defaults.set(0, forKey: DiskLimitPolicy.defaultsKey)
        let unlimited = DiskLimitPolicy(defaults: defaults)
        XCTAssertEqual(unlimited.limitMB, 20480, "旧版「无限制」迁移为最大档 20GB")
        XCTAssertEqual(unlimited.maxDiskBytes, 20480 * 1024 * 1024)

        XCTAssertEqual(DiskLimitPolicy(limitMB: -1).limitMB, 20480, "负数同样收敛到最大档")
        XCTAssertEqual(DiskLimitPolicy(limitMB: 102400).limitMB, 20480, "超过最大档被收敛")
        XCTAssertEqual(DiskLimitPolicy(limitMB: 1024).limitMB, 1024, "合法档位原样保留")
    }
}
