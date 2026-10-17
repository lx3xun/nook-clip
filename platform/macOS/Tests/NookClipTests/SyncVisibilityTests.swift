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
        XCTAssertFalse(reason.localizedDescription.isEmpty, "失败原因必须包含描述信息，不可为空")
        XCTAssertGreaterThan(date.timeIntervalSinceNow, -60, "failure 必须携带失败时间")
    }

    func testSyncFailureReasonFromErrors() {
        let authErr = NookClipError.SyncTransportError("status code 401: Unauthorized")
        XCTAssertEqual(SyncFailureReason.from(error: authErr, syncMode: .webdav), .custom(L10n.tr("sync.fail.webdav_auth")))

        let notFoundErr = NookClipError.SyncTransportError("status code 404: Not Found")
        XCTAssertEqual(SyncFailureReason.from(error: notFoundErr, syncMode: .webdav), .custom(L10n.tr("sync.fail.not_found")))

        let timeoutErr = NookClipError.SyncTransportError("connection timed out")
        XCTAssertEqual(SyncFailureReason.from(error: timeoutErr, syncMode: .webdav), .custom(L10n.tr("sync.fail.timeout")))

        let cryptoErr = NookClipError.CryptoError("Passphrase mismatch")
        XCTAssertEqual(SyncFailureReason.from(error: cryptoErr, syncMode: .webdav), .custom(L10n.tr("sync.fail.passphrase_mismatch")))
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

    func testSourceDeviceDisplayNameFormatting() {
        let itemIOS = ClipboardItem(
            type: .text,
            title: "Note",
            summary: "Content",
            sourceAppName: "Safari",
            sourceDeviceId: "iphone-1",
            sourceDeviceName: "iPhone 16",
            sourcePlatform: "ios"
        )
        let rowIOS = ClipboardRowModel(item: itemIOS)
        XCTAssertEqual(rowIOS.sourceDisplayName, "📱 iPhone 16 · Safari")

        let itemWin = ClipboardItem(
            type: .text,
            title: "Code",
            summary: "Content",
            sourceAppName: "VS Code",
            sourceDeviceId: "win-1",
            sourceDeviceName: "Workstation",
            sourcePlatform: "windows"
        )
        let rowWin = ClipboardRowModel(item: itemWin)
        XCTAssertEqual(rowWin.sourceDisplayName, "🪟 Workstation · VS Code")

        let itemLocal = ClipboardItem(
            type: .text,
            title: "Local",
            summary: "Content",
            sourceAppName: "Xcode"
        )
        let rowLocal = ClipboardRowModel(item: itemLocal)
        XCTAssertEqual(rowLocal.sourceDisplayName, "Xcode")
    }

    func testSyncOptionsCreationAndCloudSyncMode() {
        let suite = "com.nook.test.syncopts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let engine = ICloudDriveSyncEngine(defaults: defaults)

        // Default is iCloudDrive
        XCTAssertEqual(engine.syncMode, .iCloudDrive)
        let opts1 = engine.makeSyncOptions(deviceId: "mac-1", localAssetsDir: "/tmp/assets")
        XCTAssertEqual(opts1.deviceId, "mac-1")
        XCTAssertEqual(opts1.localAssetsDir, "/tmp/assets")
        XCTAssertNil(opts1.passphrase)
        XCTAssertFalse(opts1.allowSensitive)

        // Switch to WebDAV with E2EE
        engine.syncMode = .webdav
        engine.webDavURL = "https://dav.example.com"
        engine.webDavUsername = "alice"
        engine.isE2EEEnabled = true
        engine.e2eePassphrase = "passphrase-12345"
        engine.syncSensitiveItems = true

        let opts2 = engine.makeSyncOptions(deviceId: "mac-1", localAssetsDir: "/tmp/assets")
        XCTAssertEqual(opts2.passphrase, "passphrase-12345")
        XCTAssertTrue(opts2.allowSensitive)
        if case .webDav(let url, let user, _, _) = opts2.backend {
            XCTAssertEqual(url, "https://dav.example.com")
            XCTAssertEqual(user, "alice")
        } else {
            XCTFail("Backend must be WebDav")
        }
    }
    @MainActor
    func testResetSyncPassphraseCycle() async throws {
        let syncDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("nook-reset-pass-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: syncDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: syncDir) }

        let defaults = makeIsolatedDefaults()
        defaults.set("device-reset-1", forKey: "nook.sync.deviceID")
        let engine = ICloudDriveSyncEngine(customBaseURL: syncDir, defaults: defaults, keychainServicePrefix: "test.nook.reset.\(UUID().uuidString)")
        engine.isEnabled = true
        engine.isE2EEEnabled = true
        engine.e2eePassphrase = "initial-passphrase-2026"

        let store = makeIsolatedStore(syncEngine: engine, defaults: defaults)

        // 1. 插入测试条目并用 initial-passphrase 首次同步
        let item1 = ClipboardItem(
            id: UUID(),
            type: .text,
            title: "Initial Item",
            summary: "Initial Secret",
            createdAt: Date(),
            lastUsedAt: Date(),
            isFavorite: false
        )
        store.save(item1)
        await store.syncNow()
        guard case .success = store.lastSyncResult.outcome else {
            return XCTFail("首次同步必须成功")
        }

        // 2. 更改口令为新口令：直接同步会因为与云端 initial-passphrase 不符而失败
        engine.e2eePassphrase = "brand-new-passphrase-2027"
        await store.syncNow()
        guard case .failure(let reason, _) = store.lastSyncResult.outcome else {
            return XCTFail("口令不一致时常规同步必须失败")
        }
        XCTAssertTrue(reason.localizedDescription.contains(L10n.tr("sync.fail.passphrase_mismatch")))

        // 3. 执行 resetSyncPassphrase：重置云端 manifest 并用新口令重新加密推送
        try await store.resetSyncPassphrase()
        guard case .success = store.lastSyncResult.outcome else {
            return XCTFail("resetSyncPassphrase 必须成功更新云端凭证与加密推送")
        }

        // 4. 后续常规同步使用新口令应顺利通过
        await store.syncNow()
        guard case .success = store.lastSyncResult.outcome else {
            return XCTFail("重置后常规同步使用新口令必须成功通过")
        }
    }
    func testSyncModeConfigurationIsolation() {
        let suite = "com.nook.test.syncopts.isolation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let engine = ICloudDriveSyncEngine(defaults: defaults, keychainServicePrefix: "test.iso.\(UUID().uuidString)")

        // 1. 初始为 iCloudDrive：默认未启用加密，口令为空
        XCTAssertEqual(engine.syncMode, .iCloudDrive)
        XCTAssertFalse(engine.isE2EEEnabled)
        XCTAssertEqual(engine.e2eePassphrase, "")

        // 2. 切到 WebDAV：默认开启加密，配置专属口令
        engine.syncMode = .webdav
        XCTAssertTrue(engine.isE2EEEnabled)
        engine.e2eePassphrase = "webdav-passphrase-999"
        engine.syncSensitiveItems = true

        // 3. 切到本地目录映射：默认也开启加密，配置专属口令
        engine.syncMode = .localDirectory
        XCTAssertTrue(engine.isE2EEEnabled)
        engine.e2eePassphrase = "local-dir-passphrase-888"
        engine.syncSensitiveItems = false
        // 4. 切回 iCloudDrive：必须保持 iCloud 专属状态（未启用加密，无口令）
        engine.syncMode = .iCloudDrive
        XCTAssertFalse(engine.isE2EEEnabled)
        XCTAssertEqual(engine.e2eePassphrase, "")
        XCTAssertFalse(engine.syncSensitiveItems)

        // 5. 切回 WebDAV：必须恢复 WebDAV 专属配置
        engine.syncMode = .webdav
        XCTAssertTrue(engine.isE2EEEnabled)
        XCTAssertEqual(engine.e2eePassphrase, "webdav-passphrase-999")
        XCTAssertTrue(engine.syncSensitiveItems)

        // 6. 切回本地目录映射：必须恢复本地目录专属配置
        engine.syncMode = .localDirectory
        XCTAssertTrue(engine.isE2EEEnabled)
        XCTAssertEqual(engine.e2eePassphrase, "local-dir-passphrase-888")
        XCTAssertFalse(engine.syncSensitiveItems)
    }
}
