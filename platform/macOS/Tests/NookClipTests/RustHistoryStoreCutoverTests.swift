import XCTest
@testable import NookClip

final class RustHistoryStoreCutoverTests: XCTestCase {
    @MainActor
    func testStoreReadsDirectlyFromRustStoreWithoutSQLiteStore() throws {
        let tempDB = NSTemporaryDirectory() + "nook_cutover_\(UUID().uuidString).sqlite"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tempDB) }

        // 1. 创建纯净独立的 RustHistoryStore
        let rustStore = try RustHistoryStore(path: tempDB, encryptionKey: Data(repeating: 0x42, count: 32))

        // 2. 构造 InMemoryHistoryStore，注入 rustStore，且底层完全不依赖旧 SQLiteHistoryStore 的实际数据
        let defaults = makeIsolatedDefaults()
        // 设置禁用 demoItems 播种
        defaults.set(true, forKey: InMemoryHistoryStore.demoSeededKey)

        let store = InMemoryHistoryStore(
            rustStore: rustStore,
            syncEngine: makeDisabledSyncEngine(),
            defaults: defaults
        )

        // 3. 直接通过 store.save 保存条目
        let item1 = ClipboardItem(type: .text, title: "Title 1", summary: "Rust Cutover Item 1")
        let item2 = ClipboardItem(type: .text, title: "Title 2", summary: "Rust Cutover Item 2")
        store.save(item1)
        store.save(item2)

        // 4. 断言内存与 Rust 实例数据对齐
        XCTAssertEqual(store.items.count, 2)

        // 5. 新建一个只持有相同 Rust 库的 store，验证读取完全来自 Rust 引擎
        let reloadedStore = InMemoryHistoryStore(
            rustStore: rustStore,
            syncEngine: makeDisabledSyncEngine(),
            defaults: defaults
        )
        // 关键断言：重新初始化的 store 其 items 必须直接从 rustStore.page() 读出，不能依赖旧 database
        XCTAssertEqual(reloadedStore.items.count, 2, "重新加载时必须从 RustHistoryStore 读取历史条目")
        XCTAssertTrue(reloadedStore.items.contains { $0.summary == "Rust Cutover Item 1" })
        XCTAssertTrue(reloadedStore.items.contains { $0.summary == "Rust Cutover Item 2" })

        // 6. 验证软删除与回收站也完全由 Rust 驱动
        reloadedStore.delete(item1.id)
        XCTAssertEqual(reloadedStore.items.count, 1)
        XCTAssertEqual(reloadedStore.trashItems.count, 1)

        let trashReloadedStore = InMemoryHistoryStore(
            rustStore: rustStore,
            syncEngine: makeDisabledSyncEngine(),
            defaults: defaults
        )
        XCTAssertEqual(trashReloadedStore.trashItems.count, 1, "重新加载时回收站条目必须从 RustHistoryStore 读取")
        XCTAssertEqual(trashReloadedStore.trashItems.first?.id, item1.id)
    }
    @MainActor
    func testSearchAndPaginationDirectlyFromRustStore() async throws {
        let tempDB = NSTemporaryDirectory() + "nook_search_cutover_\(UUID().uuidString).sqlite"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tempDB) }

        let rustStore = try RustHistoryStore(path: tempDB, encryptionKey: Data(repeating: 0x42, count: 32))
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: InMemoryHistoryStore.demoSeededKey)

        let store = InMemoryHistoryStore(
            rustStore: rustStore,
            syncEngine: makeDisabledSyncEngine(),
            defaults: defaults
        )

        let item1 = ClipboardItem(type: .text, title: "Apple Swift", summary: "func swiftCode() -> Void")
        let item2 = ClipboardItem(type: .text, title: "Rust Cargo", summary: "fn rust_code() -> ()")
        store.save(item1)
        store.save(item2)

        let outcome = await store.searchHistory(queryText: "Swift", categoryID: 0, limit: 10)
        XCTAssertEqual(outcome.items.count, 1)
        XCTAssertEqual(outcome.items.first?.title, "Apple Swift")
        XCTAssertFalse(outcome.failed)
    }
    @MainActor
    func testMakeIsolatedStoreDefaultFactoryUsesRustStore() {
        let store = makeIsolatedStore()
        XCTAssertNotNil(store.rustStore, "makeIsolatedStore() 必须内置装配独立的 RustHistoryStore")
        
        let item = ClipboardItem(type: .text, title: "Test", summary: "Isolated Store Item")
        store.save(item)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.rustStore.page(limit: 10, offset: 0).count, 1)
    }
    @MainActor
    func testItemWithIDFindsBeyondFirstPageAndAllowsDelete() throws {
        let tempDB = NSTemporaryDirectory() + "nook_beyond1000_\(UUID().uuidString).sqlite"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tempDB) }

        let rustStore = try RustHistoryStore(path: tempDB, encryptionKey: Data(repeating: 0x42, count: 32))
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: InMemoryHistoryStore.demoSeededKey)

        let store = InMemoryHistoryStore(
            rustStore: rustStore,
            syncEngine: makeDisabledSyncEngine(),
            defaults: defaults
        )

        // Seed an older item directly into rustStore
        let oldItem = ClipboardItem(type: .text, title: "Old Secret Note", summary: "Old content beyond memory page")
        XCTAssertNotNil(rustStore.save(oldItem))

        // Query via store.item(withID:) - must fall back to rustStore even if items array is empty
        let found = store.item(withID: oldItem.id)
        XCTAssertNotNil(found, "item(withID:) 必须在内存页未命中时回捞 Rust 存储引擎")
        XCTAssertEqual(found?.summary, "Old content beyond memory page")

        // Deleting old item must succeed and update rustStore
        store.delete(oldItem.id)
        let inTrash = store.trashItems.first { $0.id == oldItem.id }
        XCTAssertNotNil(inTrash, "删除 1000 条外的条目必须进入 trashItems")
    }

    @MainActor
    func testMemoryDatabaseDoesNotCreatePhysicalFileOnDisk() throws {
        let store = try RustHistoryStore(path: ":memory:", encryptionKey: Data(repeating: 0x42, count: 32))
        let testItem = ClipboardItem(type: .text, title: "Mem Note", summary: "Mem Content")
        XCTAssertNotNil(store.save(testItem))
        XCTAssertEqual(store.page(limit: 10, offset: 0).count, 1)

        // Verify that no file named ":memory:" was created in current working directory
        let cwdMemoryFile = FileManager.default.currentDirectoryPath + "/:memory:"
        XCTAssertFalse(FileManager.default.fileExists(atPath: cwdMemoryFile), "使用 :memory: 时不得在仓库根目录下创建物理文件")
    }
    @MainActor
    func testStoreInitializationWithoutExplicitRustStoreDoesNotTouchProductionDatabase() throws {
        let tempDir = NSTemporaryDirectory() + "nook_prod_isolation_\(UUID().uuidString)/"
        let isolatedDBURL = URL(fileURLWithPath: tempDir).appendingPathComponent("library.db")
        try FileManager.default.createDirectory(at: isolatedDBURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        AppPaths.databaseURLOverride = isolatedDBURL
        addTeardownBlock {
            AppPaths.databaseURLOverride = nil
            try? FileManager.default.removeItem(atPath: tempDir)
        }

        // Create a simulated production engine in the isolated temp dir and seed a canary item
        let prodEngine = try RustHistoryStore(databaseURL: isolatedDBURL, encryptionKey: Data(repeating: 0x42, count: 32))
        let canary = ClipboardItem(type: .text, title: "Canary", summary: "Production Canary \(UUID().uuidString)")
        XCTAssertNotNil(prodEngine.save(canary))
        let countBefore = prodEngine.countItems()
        XCTAssertGreaterThan(countBefore, 0)

        // Create store with test defaults / syncEngine only, without passing rustStore
        let testStore = InMemoryHistoryStore(
            syncEngine: makeDisabledSyncEngine(),
            defaults: makeIsolatedDefaults()
        )

        // If testStore wrongly points to prodDB, clearHistory will wipe out the canary
        testStore.clearHistory(keepFavorites: false)

        let countAfter = prodEngine.countItems()
        XCTAssertEqual(countAfter, countBefore, "测试用例或未显式指定生产环境时，不得连接或清空生产库 library.db")
    }

    @MainActor
    func testImportFromJSONCorruptedDataDoesNotCorruptStore() throws {
        let store = makeIsolatedStore()
        let initialItem = ClipboardItem(type: .text, title: "Initial", summary: "Keep this safe")
        store.save(initialItem)
        XCTAssertEqual(store.items.count, 1)

        // 1. 截断/损坏的 JSON 数据：必须向上抛出错误供 UI 提示失败，且不得污染既有历史条目
        let corruptedData = "{ \"version\": 1, \"items\": [ { \"id\": ".data(using: .utf8)!
        XCTAssertThrowsError(try store.importFromJSON(corruptedData))
        XCTAssertEqual(store.items.count, 1, "导入损坏数据不得修改既有历史条目")
        XCTAssertEqual(store.items.first?.summary, "Keep this safe")

        // 2. 底层 Rust 引擎直接调用损坏 JSON 必须抛出明确的错误而非静默成功
        XCTAssertThrowsError(try store.rustStore.engine.importJson(jsonContent: "{ bad_json")) { error in
            XCTAssertTrue(error is NookClipError, "底层 Rust 引擎必须抛出 NookClipError")
        }
    }

    @MainActor
    func testGeneratedTestDataMatchesAllCategories() throws {
        let tempDir = NSTemporaryDirectory() + "nook_test_seed_\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        let tempDB = tempDir + "test_seed.db"
        let contentDir = tempDir + "Content"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tempDir) }

        // 1. 初始化数据库表结构
        let store = try RustHistoryStore(path: tempDB, encryptionKey: Data(repeating: 0x42, count: 32))
        XCTAssertEqual(store.countItems(), 0)

        // 2. 调用生成脚本注入 1000 条全分类测试数据
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        let scriptPath = repoRoot + "/scripts/generate-test-data.py"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3",
            scriptPath,
            "--db", tempDB,
            "--content-dir", contentDir,
            "--count", "1000",
            "--no-backup"
        ]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        // 3. 用 RustHistoryStore 重新读取验证
        let loadedStore = try RustHistoryStore(path: tempDB, encryptionKey: Data(repeating: 0x42, count: 32))
        let allItems = loadedStore.page(limit: 1000, offset: 0)
        XCTAssertEqual(allItems.count, 1000)

        // 4. 转换为 UI 层 ClipboardRowModel 并核验 8 种分类
        let rowModels = allItems.map { ClipboardRowModel(item: $0) }
        let categories = SidebarCategories.categories(for: rowModels)
        let categoryMap = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.count) })

        XCTAssertEqual(categoryMap[0], 1000, "全部 (0) 必须包含 1000 条")
        XCTAssertEqual(categoryMap[1], 150, "文本分类 (1) 必须包含 150 条")
        XCTAssertEqual(categoryMap[2], 150, "图片分类 (2) 必须包含 150 条")
        XCTAssertEqual(categoryMap[3], 150, "文件分类 (3) 必须包含 150 条")
        XCTAssertEqual(categoryMap[4], 150, "链接分类 (4) 必须包含 150 条")
        XCTAssertEqual(categoryMap[5], 200, "代码分类 (5) 必须包含 200 条")
        XCTAssertEqual(categoryMap[6], 100, "颜色分类 (6) 必须包含 100 条")
        XCTAssertEqual(categoryMap[7], 100, "敏感分类 (7) 必须包含 100 条")
        XCTAssertEqual(categoryMap[8], 143, "收藏分类 (8) 必须包含 143 条")

        // 5. 验证 FTS 全文检索
        let ftsHits = loadedStore.search(query: "Swift", limit: 50)
        XCTAssertFalse(ftsHits.isEmpty, "FTS 搜索 Swift 必须命中条目")

        // 6. 验证敏感数据在 Rust 引擎解密正常
        let sensitiveItem = allItems.first(where: { $0.isSensitive })
        XCTAssertNotNil(sensitiveItem)
        if let sensitiveItem {
            let detail = loadedStore.getDetail(id: sensitiveItem.id)
            XCTAssertNotNil(detail?.rawText, "敏感条目经 Rust 引擎主密钥必须成功解密")
        }
    }

    /// 内存优化回归：列表镜像只持有 summary 前缀时，粘贴/预览经
    /// item(withID:) 取回全文；markUsed 回存不得用截断前缀重建 FTS 索引
    @MainActor
    func testTruncatedMirrorYieldsFullTextForPasteAndKeepsFTSIntact() async throws {
        let tempDB = NSTemporaryDirectory() + "nook_trunc_\(UUID().uuidString).sqlite"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tempDB) }

        let rustStore = try RustHistoryStore(path: tempDB, encryptionKey: Data(repeating: 0x42, count: 32))
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: InMemoryHistoryStore.demoSeededKey)
        let store = InMemoryHistoryStore(
            rustStore: rustStore,
            syncEngine: makeDisabledSyncEngine(),
            defaults: defaults
        )

        let deepMarker = String(repeating: "a", count: 400) + "深处的关键词"
        let item = ClipboardItem(type: .text, title: "", summary: deepMarker)
        store.save(item)

        // 内存镜像只持有前缀
        XCTAssertEqual(store.items.first?.summaryIsTruncated, true)
        XCTAssertNotEqual(store.items.first?.summary, deepMarker)

        // 粘贴/预览契约：item(withID:) 必须返回全文
        XCTAssertEqual(store.item(withID: item.id)?.summary, deepMarker)

        // markUsed 回存后 FTS 仍能命中前缀之外的关键词（截断前缀回存会破坏索引）
        store.markUsed(item.id)
        let hits = rustStore.search(query: "深处的关键词", limit: 10)
        XCTAssertEqual(hits.first?.id, item.id, "markUsed 后 FTS 索引必须保留全文")
    }

    /// 回归 P0-1：敏感条目与同步/导入长文本在 markUsed 后不丢失密文与全文
    @MainActor
    func testMarkUsedPreservesSensitivePlaintextAndImportedFullText() throws {
        let store = makeIsolatedStore()

        // 1. 敏感条目 markUsed 后仍可正常解密
        let secret = "sk-proj-preserve-across-mark-used-1234567890"
        let det = try XCTUnwrap(SensitiveDataDetector.detect(text: secret))
        let enc = try XCTUnwrap(KeychainCryptoService.shared.encrypt(text: secret))
        let sensItem = ClipboardItem(
            type: .text,
            title: "",
            summary: det.maskedText,
            isSensitive: true,
            encryptedContent: enc
        )
        store.save(sensItem)
        store.markUsed(sensItem.id)

        let fetchedSens = try XCTUnwrap(store.item(withID: sensItem.id))
        XCTAssertEqual(fetchedSens.copyCount, 2)
        XCTAssertEqual(fetchedSens.revealPlainContent(), secret, "markUsed 不得用掩码覆盖敏感条目密文")

        // 2. HTTP Bearer 与配置密码赋值检测回归（P2-3）
        let bearer = SensitiveDataDetector.detect(text: "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9_token_xyz")
        XCTAssertNotNil(bearer, "HTTP Bearer 鉴权头应被识别为敏感凭据")
        let pwdAssign = SensitiveDataDetector.detect(text: "db_password = \"MySuperSecret99!\"")
        XCTAssertNotNil(pwdAssign, "配置密码赋值应被识别为敏感凭据")
    }

    /// 验证首次启动空库自动播种 7 条核心 Demo 数据（覆盖引导、敏感加密、代码/JSON、图片 OCR、链接二维码、颜色、快捷键速查）
    @MainActor
    func testSeedDemoItemsCoversCoreCategoriesAndDecryptsSensitive() throws {
        let tempDB = NSTemporaryDirectory() + "nook_demo_seed_\(UUID().uuidString).sqlite"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tempDB) }

        let rustStore = try RustHistoryStore(path: tempDB, encryptionKey: Data(repeating: 0x42, count: 32))
        let defaults = makeIsolatedDefaults()
        // 不设置 demoSeededKey，模拟全新首次启动
        let store = InMemoryHistoryStore(
            rustStore: rustStore,
            syncEngine: makeDisabledSyncEngine(),
            defaults: defaults
        )

        XCTAssertTrue(defaults.bool(forKey: InMemoryHistoryStore.demoSeededKey))
        XCTAssertEqual(store.items.count, 7, "首次启动应播种 7 条精选演示数据（JSON 与代码合二为一）")

        let counts = rustStore.countCategories()
        XCTAssertEqual(counts.total, 7)
        XCTAssertEqual(counts.favorite, 3)
        XCTAssertEqual(counts.text, 2)
        XCTAssertEqual(counts.sensitive, 1)
        XCTAssertEqual(counts.code, 1)
        XCTAssertEqual(counts.image, 1)
        XCTAssertEqual(counts.url, 1)
        XCTAssertEqual(counts.color, 1)

        // 验证敏感凭证条目可通过 item(withID:) 正常解密出明文
        let sensitiveRow = try XCTUnwrap(store.items.first(where: { $0.isSensitive }))
        let fullSensitive = try XCTUnwrap(store.item(withID: sensitiveRow.id))
        XCTAssertEqual(fullSensitive.revealPlainContent(), "sk-proj-NookDemoKeyForLocalEncryption256GCM")

        // 验证图片条目载荷文件真实存在且尺寸有效
        let imageRow = try XCTUnwrap(store.items.first(where: { $0.type == .image }))
        let imagePath = try XCTUnwrap(imageRow.payloadPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imagePath))
    }

    @MainActor
    func testSeedDemoItemsWithForceTrueSeedsEvenWhenDemoSeededKeyIsTrue() throws {
        let tempDB = NSTemporaryDirectory() + "nook_force_seed_\(UUID().uuidString).sqlite"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tempDB) }

        let rustStore = try RustHistoryStore(path: tempDB, encryptionKey: Data(repeating: 0x42, count: 32))
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: InMemoryHistoryStore.demoSeededKey)

        let store = InMemoryHistoryStore(
            rustStore: rustStore,
            syncEngine: makeDisabledSyncEngine(),
            defaults: defaults
        )
        XCTAssertEqual(store.items.count, 0, "设置 demoSeededKey 时初始不播种")

        // 强制重新播种
        store.seedDemoItemsIfNeeded(force: true)
        XCTAssertEqual(store.items.count, 7, "force = true 时即使 demoSeededKey 为 true 也能重新导入演示数据")
    }
}
