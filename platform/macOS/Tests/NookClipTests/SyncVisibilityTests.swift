import AppKit
import XCTest
@testable import NookClip

/// US3「数据相关失败可感知」回归（T025/T027，FR-011/FR-011a/FR-011b，R8/D10）：
/// 1) 载荷保存失败拒存（图片条目不入库、无崩溃）；
/// 2) SyncResult 状态机（idle → success 含时间 / failure 含原因）。
final class SyncVisibilityTests: XCTestCase {

    /// 保存必抛错的载荷替身（T025：注入 ClipboardMonitor 验证拒存路径）
    final class ThrowingPayloadStore: PayloadStore {
        var directory: URL { FileManager.default.temporaryDirectory }
        @discardableResult
        func save(data: Data, preferredExtension: String) throws -> String {
            throw NSError(domain: "nook.test", code: 1, userInfo: [NSLocalizedDescriptionKey: "disk full"])
        }
        func load(path: String) -> Data? { nil }
        func remove(path: String?) {}
        func isManaged(_ path: String) -> Bool { false }
    }

    private static func tinyPNGData() -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        return rep.representation(using: .png, properties: [:])!
    }

    // MARK: - T025 载荷保存失败拒存（R8/FR-011）

    /// 图片载荷保存失败：条目不入库（onChange 不触发）、不崩溃、轮询循环不受影响
    @MainActor
    func testImagePayloadSaveFailureRejectsItem() async throws {
        let monitor = ClipboardMonitor(payloadStore: ThrowingPayloadStore())
        var captured: ClipboardItem?
        monitor.onChange = { captured = $0 }
        monitor.start()
        defer { monitor.stop() }

        try await withPasteboardLock {
            let pb = PasteboardAccess.general
            pb.clearContents()
            XCTAssertTrue(pb.setData(Self.tinyPNGData(), forType: .png))
            try await Task.sleep(nanoseconds: 1_200_000_000)

            XCTAssertNil(captured, "载荷保存失败时图片条目必须拒存（不入库）")
        }

        // 拒存不得中断轮询：换入文本后监控仍能正常捕获
        try await withPasteboardLock {
            let pb = PasteboardAccess.general
            pb.clearContents()
            XCTAssertTrue(pb.setString("still-alive-\(UUID().uuidString)", forType: .string))
            try await Task.sleep(nanoseconds: 1_200_000_000)
        }
        XCTAssertEqual(captured?.type, .text, "拒存后轮询循环必须继续工作")
    }

    // MARK: - T027 SyncResult 状态机（D10/data-model §2）

    /// 初始 idle；同步未启用时 syncNow 不改变结果
    @MainActor
    func testSyncResultStartsIdle() async throws {
        let store = makeIsolatedStore()
        XCTAssertEqual(store.lastSyncResult.outcome, .idle, "初始状态必须为 idle")
        await store.syncNow()
        XCTAssertEqual(store.lastSyncResult.outcome, .idle, "同步未启用时不得产生结果")
    }

    /// 同步成功 → success(Date)，时间为近期
    @MainActor
    func testSyncResultSuccess() async throws {
        let syncDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("nook-syncresult-ok-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: syncDir) }
        let engine = ICloudDriveSyncEngine(customBaseURL: syncDir, defaults: makeIsolatedDefaults())
        engine.isEnabled = true
        try engine.ensureDirectoriesExist()

        let store = makeIsolatedStore(syncEngine: engine)
        await store.syncNow()

        guard case .success(let date) = store.lastSyncResult.outcome else {
            return XCTFail("同步成功后必须为 success(Date)，实际：\(store.lastSyncResult.outcome)")
        }
        XCTAssertGreaterThan(date.timeIntervalSinceNow, -60, "success 必须携带同步完成时间")
    }

    /// 同步失败 → failure(reason, Date)：目录不可写（基路径是普通文件）触发失败，reason 粗分为 unknown
    @MainActor
    func testSyncResultFailure() async throws {
        let badBase = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nook-syncresult-bad-\(UUID().uuidString)")
        try Data("not-a-directory".utf8).write(to: badBase)
        defer { try? FileManager.default.removeItem(at: badBase) }

        let engine = ICloudDriveSyncEngine(customBaseURL: badBase, defaults: makeIsolatedDefaults())
        engine.isEnabled = true

        let store = makeIsolatedStore(syncEngine: engine)
        await store.syncNow()

        guard case .failure(let reason, let date) = store.lastSyncResult.outcome else {
            return XCTFail("同步失败后必须为 failure(reason, Date)，实际：\(store.lastSyncResult.outcome)")
        }
        XCTAssertEqual(reason, .unknown, "非 NSURLErrorDomain 错误粗分为 unknown")
        XCTAssertGreaterThan(date.timeIntervalSinceNow, -60, "failure 必须携带失败时间")
    }

    // MARK: - Rust Packfile Sync Cutover (Seam B & Seam C)

    @MainActor
    func testTwoStoresSyncRoundtripViaRustPackfiles() async throws {
        let syncDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("nook-pack-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: syncDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: syncDir) }

        let defaultsA = makeIsolatedDefaults()
        defaultsA.set("device-A", forKey: "nook.sync.deviceID")
        let engineA = ICloudDriveSyncEngine(customBaseURL: syncDir, defaults: defaultsA)
        engineA.isEnabled = true
        let storeA = makeIsolatedStore(syncEngine: engineA, defaults: defaultsA)

        let defaultsB = makeIsolatedDefaults()
        defaultsB.set("device-B", forKey: "nook.sync.deviceID")
        let engineB = ICloudDriveSyncEngine(customBaseURL: syncDir, defaults: defaultsB)
        engineB.isEnabled = true
        let storeB = makeIsolatedStore(syncEngine: engineB, defaults: defaultsB)

        let itemA = ClipboardItem(
            id: UUID(),
            type: .text,
            title: "Cross Device Note",
            summary: "Hello from device A",
            createdAt: Date(),
            lastUsedAt: Date(),
            isFavorite: false
        )
        storeA.save(itemA)

        await storeA.syncNow()

        let packA = syncDir.appendingPathComponent("devices/device-A.pack")
        XCTAssertTrue(FileManager.default.fileExists(atPath: packA.path), "Device A must push packfile to devices/device-A.pack")

        await storeB.syncNow()

        XCTAssertTrue(storeB.items.contains { $0.id == itemA.id }, "Store B must pull and load itemA into items")
        XCTAssertEqual(storeB.items.first { $0.id == itemA.id }?.summary, "Hello from device A")
    }

    @MainActor
    func testDeletionSyncRoundtripViaRustPackfiles() async throws {
        let syncDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("nook-pack-del-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: syncDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: syncDir) }

        let defaultsA = makeIsolatedDefaults()
        defaultsA.set("device-A", forKey: "nook.sync.deviceID")
        let engineA = ICloudDriveSyncEngine(customBaseURL: syncDir, defaults: defaultsA)
        engineA.isEnabled = true
        let storeA = makeIsolatedStore(syncEngine: engineA, defaults: defaultsA)

        let defaultsB = makeIsolatedDefaults()
        defaultsB.set("device-B", forKey: "nook.sync.deviceID")
        let engineB = ICloudDriveSyncEngine(customBaseURL: syncDir, defaults: defaultsB)
        engineB.isEnabled = true
        let storeB = makeIsolatedStore(syncEngine: engineB, defaults: defaultsB)

        let item = ClipboardItem(
            id: UUID(),
            type: .text,
            title: "To Be Deleted",
            summary: "Will be deleted",
            createdAt: Date(),
            lastUsedAt: Date(),
            isFavorite: false
        )
        storeA.save(item)
        await storeA.syncNow()
        await storeB.syncNow()
        XCTAssertTrue(storeB.items.contains { $0.id == item.id })

        storeA.delete(item.id)
        XCTAssertFalse(storeA.items.contains { $0.id == item.id })

        await storeA.syncNow()
        await storeB.syncNow()

        XCTAssertFalse(storeB.items.contains { $0.id == item.id })
    }

    /// 安全不变量：默认同步不推送敏感条目（即便本地已加密入库）
    @MainActor
    func testSyncNowExcludesSensitiveItemsByDefault() async throws {
        let syncDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("nook_sync_sensitive_guard_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: syncDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: syncDir) }

        let suiteA = "nook_test_sync_sens_a_\(UUID().uuidString)"
        let defaultsA = UserDefaults(suiteName: suiteA)!
        defaultsA.set("device-A", forKey: "nook.sync.deviceID")
        let engineA = ICloudDriveSyncEngine(customBaseURL: syncDir, defaults: defaultsA)
        engineA.isEnabled = true
        let storeA = makeIsolatedStore(syncEngine: engineA, defaults: defaultsA)

        let suiteB = "nook_test_sync_sens_b_\(UUID().uuidString)"
        let defaultsB = UserDefaults(suiteName: suiteB)!
        defaultsB.set("device-B", forKey: "nook.sync.deviceID")
        let engineB = ICloudDriveSyncEngine(customBaseURL: syncDir, defaults: defaultsB)
        engineB.isEnabled = true
        let storeB = makeIsolatedStore(syncEngine: engineB, defaults: defaultsB)

        let secret = "sk-proj-sync-privacy-token-998877"
        let detection = SensitiveDataDetector.detect(text: secret)!
        let sensitiveItem = ClipboardItem(
            id: UUID(),
            type: .text,
            title: "",
            summary: detection.maskedText,
            isSensitive: true,
            encryptedContent: KeychainCryptoService.shared.encrypt(text: secret)
        )
        let normalItem = ClipboardItem(
            id: UUID(),
            type: .text,
            title: "Normal",
            summary: "Public content safe to sync"
        )
        storeA.save(sensitiveItem)
        storeA.save(normalItem)

        await storeA.syncNow()
        await storeB.syncNow()

        XCTAssertTrue(storeB.items.contains { $0.id == normalItem.id }, "普通条目应成功同步到设备 B")
        XCTAssertFalse(storeB.items.contains { $0.id == sensitiveItem.id }, "敏感条目绝不上云，设备 B 不得拉取到")
        XCTAssertFalse(storeB.items.contains { $0.isSensitive }, "设备 B 同步集内不含任何敏感条目")
    }

    @MainActor
    func testSyncDeviceIDUsesComputerNameAndMigratesLegacyPlaceholder() {
        let suite = "com.nook.test.deviceid.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!

        // 1. 无初始配置时，应以本机名称开头，而不是硬编码的 "device-"
        let store = makeIsolatedStore(defaults: defaults)
        let deviceID = store.syncDeviceID
        XCTAssertFalse(deviceID.hasPrefix("device-"), "设备标识必须使用电脑名称，不得以硬编码 'device-' 开头: \(deviceID)")

        // 2. 模拟旧版硬编码的占位符 "device-A8E3C1C5"，应自动平滑升级为电脑名称并保留哈希后缀
        defaults.set("device-A8E3C1C5", forKey: "nook.sync.deviceID")
        let migratedID = store.syncDeviceID
        XCTAssertTrue(migratedID.hasSuffix("-A8E3C1C5"), "应保留原有短哈希后缀: \(migratedID)")
        XCTAssertFalse(migratedID.hasPrefix("device-"), "升级后不得保留 'device-' 占位前缀: \(migratedID)")
    }

    func testCloudFileRepositoryDefaultBaseDirectoryURL() {
        let defaults = makeIsolatedDefaults()
        let repo = CloudFileRepository(defaults: defaults)
        let path = repo.baseDirectoryURL.path
        XCTAssertTrue(path.hasSuffix("Library/Mobile Documents/com~apple~CloudDocs/NookClip"), "默认同步目录必须为 CloudDocs/NookClip: \(path)")

        let explicitURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let repoExplicit = CloudFileRepository(defaults: defaults, customBaseURL: explicitURL)
        XCTAssertEqual(repoExplicit.baseDirectoryURL, explicitURL)
    }
}
