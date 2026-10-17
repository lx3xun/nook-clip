import XCTest
@testable import NookClip

/// 复制链查询预算（接缝 B：持久化边界调用计数）。
/// save 是最高频写入入口（每次复制触发），预算 = 1 次保存 FFI + 0 次查询：
/// 整页重查（page）与回收站重查（trashItems）属于启动/删除路径的职责，
/// 不得出现在 save 路径上。镜像状态正确性由接缝 A 的行为规格测试保障，
/// 这里只锁定调用预算。
final class QueryCountingHistoryStore: RustHistoryStore, @unchecked Sendable {
    private(set) var pageCallCount = 0
    private(set) var trashItemsCallCount = 0

    override func page(limit: Int = 1000, offset: Int = 0, truncatingSummary: Bool = true) -> [ClipboardItem] {
        pageCallCount += 1
        return super.page(limit: limit, offset: offset, truncatingSummary: truncatingSummary)
    }

    override func trashItems() -> [ClipboardItem] {
        trashItemsCallCount += 1
        return super.trashItems()
    }

    private(set) var pruneExpiredCallCount = 0
    private(set) var purgeCallCount = 0

    override func pruneExpired(days: Int?, maxCount: Int?) -> [PrunedItemRecord] {
        pruneExpiredCallCount += 1
        return super.pruneExpired(days: days, maxCount: maxCount)
    }

    override func purge(_ id: UUID) -> Bool {
        purgeCallCount += 1
        return super.purge(id)
    }

    override init(engine: NookClipHistoryEngine) {
        super.init(engine: engine)
    }

    convenience init() throws {
        let engine = try NookClipHistoryEngine(
            dbPath: ":memory:",
            masterKey: Data(repeating: 0x42, count: 32)
        )
        self.init(engine: engine)
    }
}

/// 引擎级敏感明文解密计数：getItemDetail 是列表路径逐条解密的入口
/// （后续接 Keychain 重加密），懒解密契约 = 列表/保存路径 0 次，
/// 全文契约（item(withID:)）按需 1 次
final class DetailCountingEngine: NookClipHistoryEngine, @unchecked Sendable {
    private(set) var getItemDetailCount = 0

    required public init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
        super.init(unsafeFromRawPointer: pointer)
    }

    init(cloneOf base: NookClipHistoryEngine) {
        super.init(unsafeFromRawPointer: base.uniffiClonePointer())
    }

    override func getItemDetail(id: String) throws -> ClipItemDetail {
        getItemDetailCount += 1
        return try super.getItemDetail(id: id)
    }
}

@MainActor
final class SavePathQueryBudgetTests: XCTestCase {

    func test_saveIssuesNoPageOrTrashRequery() throws {
        let spy = try QueryCountingHistoryStore()
        let store = makeIsolatedStore(rustStore: spy)
        // 基线：init 完成首次加载（空白清理 + 首页 + 演示播种等）
        let baselinePage = spy.pageCallCount
        let baselineTrash = spy.trashItemsCallCount
        XCTAssertGreaterThan(baselinePage, 0, "前置：init 已完成首次分页加载")

        store.save(ClipboardItem(type: .text, title: "预算条目 A", summary: "budget a"))
        store.save(ClipboardItem(type: .text, title: "预算条目 B", summary: "budget b"))
        // 重复内容捕获（去重合并路径）
        store.save(ClipboardItem(type: .text, title: "预算条目 A", summary: "budget a"))

        XCTAssertEqual(spy.pageCallCount, baselinePage, "save 不得整页重查镜像")
        XCTAssertEqual(spy.trashItemsCallCount, baselineTrash, "save 不得重查回收站")
        XCTAssertFalse(store.items.isEmpty, "前置：镜像确实收到保存的条目")
    }

    /// 懒解密契约（接缝 B）：保存与列表路径不得逐条解密敏感明文
    /// （getItemDetail + Keychain 重加密的 N+1 大头）；全文契约
    /// （item(withID:)，粘贴/预览消费面）按需解密一次
    func test_saveAndListPathNeverDecryptSensitivePlaintext() throws {
        let baseEngine = try NookClipHistoryEngine(
            dbPath: ":memory:",
            masterKey: Data(repeating: 0x42, count: 32)
        )
        let countingEngine = DetailCountingEngine(cloneOf: baseEngine)
        let spy = QueryCountingHistoryStore(engine: countingEngine)
        let store = makeIsolatedStore(rustStore: spy)
        let baseline = countingEngine.getItemDetailCount

        let secret = "sk-proj-9876543210abcdef0123456789"
        let detection = try XCTUnwrap(SensitiveDataDetector.detect(text: secret))
        let encrypted = try XCTUnwrap(KeychainCryptoService.shared.encrypt(text: secret))
        store.save(ClipboardItem(
            type: .text,
            title: "",
            summary: detection.maskedText,
            isSensitive: true,
            encryptedContent: encrypted
        ))
        XCTAssertEqual(countingEngine.getItemDetailCount - baseline, 0, "保存路径不得解密敏感明文")

        _ = spy.page(limit: 50, offset: 0)
        XCTAssertEqual(countingEngine.getItemDetailCount - baseline, 0, "列表路径不得逐条解密敏感明文")

        // 全文契约：粘贴/预览经 item(withID:) 按需解密
        let id = try XCTUnwrap(store.items.first?.id)
        let full = store.item(withID: id)
        XCTAssertEqual(countingEngine.getItemDetailCount - baseline, 1, "全文取回恰好解密一次")
        XCTAssertEqual(full?.revealPlainContent(), secret, "全文契约必须能还原明文")
    }

    /// 启动预算（接缝 B）：init 不得同步执行保留期清理与空白行清理
    /// （万级历史下 prune + 1000 行扫描是启动主线程卡顿大头）。
    /// 维护本体经 performStartupMaintenance() 显式驱动
    func test_initPerformsNoSynchronousHeavyMaintenance() throws {
        let spy = try QueryCountingHistoryStore()
        // 默认保留期（defaults 未设置）
        _ = makeIsolatedStore(rustStore: spy)

        XCTAssertEqual(spy.pruneExpiredCallCount, 0, "init 不得同步执行保留期清理")
        XCTAssertEqual(spy.purgeCallCount, 0, "init 不得同步执行空白行清理")
    }

    /// 启动维护功能规格（接缝 A）：过期条目被清理出库与镜像，载荷同步清删
    func test_startupMaintenancePurgesExpiredItemsAndPayloads() async throws {
        let spy = try QueryCountingHistoryStore()
        let defaults = makeIsolatedDefaults()
        defaults.set(30, forKey: RetentionPolicy.defaultsKey)
        // 载荷须在受管目录内（FileStore.remove 只删受管文件，防误删用户原始文件）
        let payloadDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nook_payload_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: payloadDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: payloadDir) }
        let payloadStore = FileStore(directory: payloadDir)
        let store = InMemoryHistoryStore(
            rustStore: spy,
            syncEngine: makeDisabledSyncEngine(),
            defaults: defaults,
            payloadStore: payloadStore
        )

        // 播种一条 40 天前的过期条目（带载荷）+ 一条新条目
        let payloadPath = payloadDir.appendingPathComponent("expired-payload.txt").path
        try "payload".write(toFile: payloadPath, atomically: true, encoding: .utf8)
        let expiredID = UUID()
        _ = spy.save(ClipboardItem(
            id: expiredID,
            type: .text,
            title: "过期",
            summary: "expired needle",
            lastUsedAt: Date(timeIntervalSinceNow: -40 * 86400),
            payloadPath: payloadPath
        ))
        _ = spy.save(ClipboardItem(type: .text, title: "新鲜", summary: "fresh needle"))

        // init 已完成（同步路径不含清理）；驱动维护
        await store.performStartupMaintenance()

        XCTAssertEqual(spy.pruneExpiredCallCount, 1, "维护执行保留期清理")
        XCTAssertNil(store.item(withID: expiredID), "过期条目被清理")
        XCTAssertEqual(store.items.first(where: { $0.summary == "fresh needle" })?.summary, "fresh needle", "未过期条目保留")
        XCTAssertFalse(FileManager.default.fileExists(atPath: payloadPath), "被清理条目的载荷文件同步删除")
    }
}
