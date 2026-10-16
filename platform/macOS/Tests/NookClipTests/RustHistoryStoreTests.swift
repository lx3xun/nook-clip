import XCTest
@testable import NookClip

final class RustHistoryStoreTests: XCTestCase {
    private var tempDBURL: URL!
    private var store: RustHistoryStore!

    override func setUpWithError() throws {
        let tempDir = FileManager.default.temporaryDirectory
        tempDBURL = tempDir.appendingPathComponent("test_\(UUID().uuidString).db")
        let key = Data(repeating: 0x55, count: 32)
        store = try RustHistoryStore(databaseURL: tempDBURL, encryptionKey: key)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDBURL)
    }

    func testSaveAndPage() {
        let item1 = ClipboardItem(
            id: UUID(),
            type: .text,
            title: "Hello World",
            summary: "Hello World Summary",
            createdAt: Date(),
            lastUsedAt: Date(timeIntervalSince1970: 1000),
            copyCount: 1,
            isFavorite: false,
            payloadPath: nil,
            ocrText: nil,
            sourceAppBundleId: "com.apple.Safari",
            sourceAppName: "Safari",
            isSensitive: false,
            encryptedContent: nil,
            metadata: ClipboardMetadata()
        )
        let item2 = ClipboardItem(
            id: UUID(),
            type: .text,
            title: "Second Entry",
            summary: "Second Summary",
            createdAt: Date(),
            lastUsedAt: Date(timeIntervalSince1970: 2000),
            copyCount: 1,
            isFavorite: false,
            payloadPath: nil,
            ocrText: nil,
            sourceAppBundleId: "com.apple.Terminal",
            sourceAppName: "Terminal",
            isSensitive: false,
            encryptedContent: nil,
            metadata: ClipboardMetadata()
        )

        XCTAssertNotNil(store.save(item1, rawText: "Hello World Full"))
        XCTAssertNotNil(store.save(item2, rawText: "Second Entry Full"))

        let list = store.page(limit: 10, offset: 0)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].id, item2.id) // Ordered by lastUsedAt DESC
        XCTAssertEqual(list[1].id, item1.id)

        let detail = store.getDetail(id: item1.id)
        XCTAssertNotNil(detail)
        XCTAssertEqual(detail?.rawText, "Hello World Full")
    }

    func testFavoriteToggle() {
        let id = UUID()
        let item = ClipboardItem(
            id: id,
            type: .text,
            title: "Favorite Test",
            summary: "Fav",
            createdAt: Date(),
            lastUsedAt: Date(),
            copyCount: 1,
            isFavorite: false,
            payloadPath: nil,
            ocrText: nil,
            sourceAppBundleId: nil,
            sourceAppName: nil,
            isSensitive: false,
            encryptedContent: nil,
            metadata: ClipboardMetadata()
        )
        store.save(item)

        XCTAssertTrue(store.toggleFavorite(id))
        var list = store.page()
        XCTAssertTrue(list[0].isFavorite)

        XCTAssertTrue(store.toggleFavorite(id))
        list = store.page()
        XCTAssertFalse(list[0].isFavorite)
    }

    func testSoftDeleteAndRestore() {
        let id = UUID()
        let item = ClipboardItem(
            id: id,
            type: .text,
            title: "Delete Test",
            summary: "Del",
            createdAt: Date(),
            lastUsedAt: Date(),
            copyCount: 1,
            isFavorite: false,
            payloadPath: nil,
            ocrText: nil,
            sourceAppBundleId: nil,
            sourceAppName: nil,
            isSensitive: false,
            encryptedContent: nil,
            metadata: ClipboardMetadata()
        )
        store.save(item)

        XCTAssertTrue(store.delete(id))
        XCTAssertEqual(store.page().count, 0)
        XCTAssertEqual(store.trashItems().count, 1)

        XCTAssertTrue(store.restore(id))
        XCTAssertEqual(store.page().count, 1)
        XCTAssertEqual(store.trashItems().count, 0)
    }

    func testSearchSubstring() {
        let item = ClipboardItem(
            id: UUID(),
            type: .text,
            title: "Rust内核重构",
            summary: "将剪贴板接口层重构为高性能Rust核心",
            createdAt: Date(),
            lastUsedAt: Date(),
            copyCount: 1,
            isFavorite: false,
            payloadPath: nil,
            ocrText: nil,
            sourceAppBundleId: nil,
            sourceAppName: "Xcode",
            isSensitive: false,
            encryptedContent: nil,
            metadata: ClipboardMetadata()
        )
        store.save(item)

        let hits = store.search(query: "高性能")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].id, item.id)

        let miss = store.search(query: "Python")
        XCTAssertEqual(miss.count, 0)
    }

    func testSensitiveDataProtection() {
        let id = UUID()
        let secret = "sk-live-test-super-secret-key-12345"
        let item = ClipboardItem(
            id: id,
            type: .text,
            title: "Secret Key",
            summary: "••••••••",
            createdAt: Date(),
            lastUsedAt: Date(),
            copyCount: 1,
            isFavorite: false,
            payloadPath: nil,
            ocrText: nil,
            sourceAppBundleId: nil,
            sourceAppName: nil,
            isSensitive: true,
            encryptedContent: nil,
            metadata: ClipboardMetadata()
        )
        store.save(item, rawText: secret)

        let list = store.page()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].summary, "••••••••")
        XCTAssertTrue(list[0].isSensitive)

        // Detail returns decrypted plaintext
        let detail = store.getDetail(id: id)
        XCTAssertEqual(detail?.rawText, secret)

        // FTS search does NOT match secret key plaintext
        let ftsHits = store.search(query: "secret")
        XCTAssertEqual(ftsHits.count, 0)
    }

    func testOCRUpdateAndSearch() {
        let id = UUID()
        let item = ClipboardItem(
            id: id,
            type: .image,
            title: "Screenshot",
            summary: "Image 640x480",
            createdAt: Date(),
            lastUsedAt: Date(),
            copyCount: 1,
            isFavorite: false,
            payloadPath: nil,
            ocrText: nil,
            sourceAppBundleId: nil,
            sourceAppName: nil,
            isSensitive: false,
            encryptedContent: nil,
            metadata: ClipboardMetadata()
        )
        store.save(item)

        XCTAssertEqual(store.search(query: "NetworkTimeout").count, 0)

        XCTAssertTrue(store.updateOCR(id: id, ocrText: "Fatal Error: NetworkTimeout connecting to gateway"))

        let hits = store.search(query: "NetworkTimeout")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].id, id)
    }

    func testRustSyncPushAndPullRoundtrip() throws {
        let syncDir = FileManager.default.temporaryDirectory.appendingPathComponent("nook_sync_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: syncDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: syncDir) }

        let item = ClipboardItem(
            id: UUID(),
            type: .text,
            title: "Sync Test Item",
            summary: "Sync Content",
            createdAt: Date(),
            lastUsedAt: Date(),
            isFavorite: false
        )
        XCTAssertNotNil(store.save(item))

        let pushReport = try store.syncPush(syncDir: syncDir.path, deviceId: "device-A", localAssetsDir: "")
        XCTAssertEqual(pushReport.pushedCount, 1)

        let packPath = syncDir.appendingPathComponent("devices/device-A.pack")
        XCTAssertTrue(FileManager.default.fileExists(atPath: packPath.path))

        let dbB = FileManager.default.temporaryDirectory.appendingPathComponent("test_b_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: dbB) }
        let storeB = try RustHistoryStore(databaseURL: dbB, encryptionKey: Data(repeating: 0x55, count: 32))

        let pullReport = try storeB.syncPull(syncDir: syncDir.path, deviceId: "device-B", localAssetsDir: "")
        XCTAssertEqual(pullReport.pulledCount, 1)

        let itemsB = storeB.page(limit: 10, offset: 0)
        XCTAssertEqual(itemsB.count, 1)
        XCTAssertEqual(itemsB.first?.id, item.id)
        XCTAssertEqual(itemsB.first?.summary, "Sync Content")
    }

    /// 安全不变量：同步不推送敏感条目
    func testSyncPushExcludesSensitiveItems() throws {
        let syncDir = FileManager.default.temporaryDirectory.appendingPathComponent("nook_sync_nosensitive_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: syncDir) }

        let secret = "sk-proj-default-exclude-test"
        let detection = SensitiveDataDetector.detect(text: secret)!
        let sensitiveItem = ClipboardItem(
            type: .text,
            title: "",
            summary: detection.maskedText,
            isSensitive: true,
            encryptedContent: KeychainCryptoService.shared.encrypt(text: secret)
        )
        let normalItem = ClipboardItem(
            type: .text,
            title: "Normal",
            summary: "Normal Content"
        )
        XCTAssertNotNil(store.save(sensitiveItem))
        XCTAssertNotNil(store.save(normalItem))

        // 敏感条目绝不入 pack
        let pushReport = try store.syncPush(syncDir: syncDir.path, deviceId: "device-A", localAssetsDir: "")
        XCTAssertEqual(pushReport.pushedCount, 1, "仅普通条目入 pack")

        let dbB = FileManager.default.temporaryDirectory.appendingPathComponent("test_nosens_b_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: dbB) }
        let storeB = try RustHistoryStore(databaseURL: dbB, encryptionKey: Data(repeating: 0x55, count: 32))
        _ = try storeB.syncPull(syncDir: syncDir.path, deviceId: "device-B", localAssetsDir: "")

        let itemsB = storeB.page(limit: 10, offset: 0)
        XCTAssertEqual(itemsB.count, 1)
        XCTAssertEqual(itemsB.first?.id, normalItem.id)
        XCTAssertFalse(itemsB.contains { $0.isSensitive }, "敏感条目绝不上云")
    }

    // MARK: - 列表 summary 截断与按需全文（内存优化回归）

    /// 列表查询只载入 summary 前缀；item(id:) 按 id 返回全文。
    /// 粘贴/预览/回存的全文契约依赖此行为
    func testPageTruncatesLongSummaryWhileItemByIDReturnsFullText() {
        let longText = String(repeating: "全文内容", count: 200) // 800 字符
        let item = ClipboardItem(
            id: UUID(),
            type: .text,
            title: "",
            summary: longText,
            lastUsedAt: Date(timeIntervalSince1970: 1000)
        )
        XCTAssertNotNil(store.save(item))

        let page = store.page(limit: 10, offset: 0)
        XCTAssertEqual(page.count, 1)
        XCTAssertTrue(page[0].summaryIsTruncated, "超长 summary 的列表条目必须标记截断")
        XCTAssertEqual(page[0].summary.count, RustHistoryStore.summaryPrefixLimit)
        XCTAssertEqual(page[0].summary, String(longText.prefix(RustHistoryStore.summaryPrefixLimit)))

        let full = store.item(id: item.id)
        XCTAssertEqual(full?.summary, longText, "按 id 取回必须是全文")
        XCTAssertEqual(full?.summaryIsTruncated, false)
    }

    // MARK: - 生产打开入口（密钥迁移）

    /// 旧版固定密钥（0x42×32）库经 openProduction 迁移到钥匙串密钥后，
    /// 敏感载荷必须仍可解密；迁移标记写入后不重复轮换
    func testOpenProductionMigratesLegacyKeyDatabase() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let secret = "sk-proj-migrate-me-12345"
        let detection = SensitiveDataDetector.detect(text: secret)!
        let sensitiveItem = ClipboardItem(
            type: .text,
            title: "",
            summary: detection.maskedText,
            isSensitive: true,
            encryptedContent: nil
        )
        // 旧库：固定密钥 0x42
        let legacy = try RustHistoryStore(databaseURL: dbURL, encryptionKey: Data(repeating: 0x42, count: 32))
        XCTAssertNotNil(legacy.save(sensitiveItem, rawText: secret))

        // 生产入口：隔离钥匙串 + 隔离 defaults
        let keyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keychain_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: keyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: keyDir) }
        let keychain = KeychainCryptoService(
            keyFileURL: keyDir.appendingPathComponent("master.key"),
            keychainService: "test.nook.\(UUID().uuidString)"
        )
        let suiteName = "test.nook.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let migrated = RustHistoryStore.openProduction(
            databaseURL: dbURL,
            keychain: keychain,
            defaults: defaults
        )
        // 敏感条目全文经新密钥可解密
        let detail = migrated.getDetail(id: sensitiveItem.id)
        XCTAssertEqual(detail?.rawText, secret)
        // 迁移标记已写入
        XCTAssertTrue(defaults.bool(forKey: "nook.db.keychainKeyMigrated"))

        // 二次打开：直接用钥匙串密钥（不重复迁移），数据仍可读
        let reopened = RustHistoryStore.openProduction(
            databaseURL: dbURL,
            keychain: keychain,
            defaults: defaults
        )
        XCTAssertEqual(reopened.getDetail(id: sensitiveItem.id)?.rawText, secret)
    }

    @MainActor
    func testOpenProductionResetsOnboardingFlagsWhenDatabaseFileIsNewlyCreated() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fresh_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let keyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keychain_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: keyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: keyDir) }
        let keychain = KeychainCryptoService(
            keyFileURL: keyDir.appendingPathComponent("master.key"),
            keychainService: "test.nook.\(UUID().uuidString)"
        )
        let suiteName = "test.nook.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // 模拟用户之前开发/旧版本遗留的已播种与已启动标记
        defaults.set(true, forKey: InMemoryHistoryStore.demoSeededKey)
        defaults.set(true, forKey: UserDefaultsKey.hasLaunchedBefore.rawValue)

        // 首次打开全新不存在的库文件
        let store = RustHistoryStore.openProduction(
            databaseURL: dbURL,
            keychain: keychain,
            defaults: defaults
        )
        XCTAssertNotNil(store)
        XCTAssertFalse(defaults.bool(forKey: InMemoryHistoryStore.demoSeededKey), "全新库创建时应清除 demoSeededKey 标记以允许播种示例数据")
        XCTAssertFalse(defaults.bool(forKey: UserDefaultsKey.hasLaunchedBefore.rawValue), "全新库创建时应清除 hasLaunchedBefore 标记以允许触发首启引导")

        // 再次设置标记模拟已完成首启和播种
        defaults.set(true, forKey: InMemoryHistoryStore.demoSeededKey)
        defaults.set(true, forKey: UserDefaultsKey.hasLaunchedBefore.rawValue)

        // 二次打开已有库文件：标记不应被清除
        let reopened = RustHistoryStore.openProduction(
            databaseURL: dbURL,
            keychain: keychain,
            defaults: defaults
        )
        XCTAssertNotNil(reopened)
        XCTAssertTrue(defaults.bool(forKey: InMemoryHistoryStore.demoSeededKey), "已有库文件再次打开不应清除 demoSeededKey")
        XCTAssertTrue(defaults.bool(forKey: UserDefaultsKey.hasLaunchedBefore.rawValue), "已有库文件再次打开不应清除 hasLaunchedBefore")
    }

    func testCategorySearchSingleImageFileMatchesImageCategoryAndNotFileCategory() {
        let imageFile = ClipboardItem(
            id: UUID(),
            type: .file,
            title: "nookclip.png",
            summary: "/path/to/nookclip.png",
            createdAt: Date(),
            lastUsedAt: Date(),
            payloadPath: "/path/to/nookclip.png"
        )
        let nonImageFile = ClipboardItem(
            id: UUID(),
            type: .file,
            title: "document.pdf",
            summary: "/path/to/document.pdf",
            createdAt: Date(),
            lastUsedAt: Date(),
            payloadPath: "/path/to/document.pdf"
        )
        XCTAssertNotNil(store.save(imageFile))
        XCTAssertNotNil(store.save(nonImageFile))

        // Category 2: Image
        let imageResults = store.search(query: "", categoryID: 2)
        XCTAssertEqual(imageResults.count, 1)
        XCTAssertEqual(imageResults.first?.id, imageFile.id)

        // Category 3: File
        let fileResults = store.search(query: "", categoryID: 3)
        XCTAssertEqual(fileResults.count, 1)
        XCTAssertEqual(fileResults.first?.id, nonImageFile.id)
    }

    func testToggleSensitiveCyclesState() {
        let id = UUID()
        let secret = "df94e2db9bd390a1dc28792f6cee9434"
        let item = ClipboardItem(
            id: id,
            type: .text,
            title: "",
            summary: secret,
            createdAt: Date(),
            lastUsedAt: Date(),
            isSensitive: false
        )
        XCTAssertNotNil(store.save(item, rawText: secret))
        XCTAssertEqual(store.search(query: "df94e2db").count, 1)

        // 1. Toggle to sensitive
        let toggled = store.toggleSensitive(id)
        XCTAssertNotNil(toggled)
        XCTAssertTrue(toggled?.isSensitive == true)
        XCTAssertEqual(toggled?.summary, "df94••••••••9434")
        XCTAssertEqual(store.getDetail(id: id)?.rawText, secret)
        XCTAssertEqual(store.search(query: "df94e2db").count, 0)

        // 2. Toggle back to plain
        let reverted = store.toggleSensitive(id)
        XCTAssertNotNil(reverted)
        XCTAssertFalse(reverted?.isSensitive == true)
        XCTAssertEqual(reverted?.summary, secret)
        XCTAssertEqual(store.search(query: "df94e2db").count, 1)
    }
}
