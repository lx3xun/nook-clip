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
        let engine = ICloudDriveSyncEngine(customBaseURL: syncDir, defaults: defaults, secretsNamespace: "test.nook.reset.\(UUID().uuidString)")
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
        let engine = ICloudDriveSyncEngine(defaults: defaults, secretsNamespace: "test.iso.\(UUID().uuidString)")

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

    // MARK: - 同步通道入口收敛（本地目录映射 / WebDAV 暂时关闭）

    /// 设置页「同步方式」只应出现用户可见的通道；引擎能力本身仍然保留。
    func testOnlyICloudIsUserSelectableSyncMode() {
        XCTAssertEqual(CloudSyncMode.userSelectableModes, [.iCloudDrive])
        XCTAssertTrue(CloudSyncMode.iCloudDrive.isUserSelectable)
        XCTAssertFalse(CloudSyncMode.localDirectory.isUserSelectable)
        XCTAssertFalse(CloudSyncMode.webdav.isUserSelectable)
        // 引擎仍能构造三条通道的后端选项（入口关闭 ≠ 能力删除）
        XCTAssertEqual(CloudSyncMode.allCases.count, 3)
    }

    /// 入口关闭后，legacy 停在 WebDAV / 本地目录映射的用户在启动时收敛回 iCloud，
    /// 否则设置页选不到通道、实际同步却仍在走 WebDAV 轮询或自定义目录。
    /// 同时必须关掉同步开关：不能把原本只发往自建 WebDAV 的数据默默改道 iCloud。
    func testLegacyUnsupportedSyncModeMigratesToICloud() {
        let defaults = makeIsolatedDefaults()
        // 模拟旧版本留下的状态：通道 = webdav，且通道专属配置齐全
        defaults.set("webdav", forKey: "nook.sync.mode")
        defaults.set("https://dav.example.com", forKey: "nook.sync.webdav.url")
        defaults.set("alice", forKey: "nook.sync.webdav.username")
        defaults.set(true, forKey: "enableICloudSync")

        let engine = ICloudDriveSyncEngine(
            defaults: defaults,
            secretsNamespace: "test.nook.migrate.\(UUID().uuidString)"
        )

        XCTAssertEqual(engine.syncMode, .iCloudDrive, "不可选通道必须收敛回 iCloud")
        XCTAssertEqual(defaults.string(forKey: "nook.sync.mode"), "icloud")
        XCTAssertFalse(engine.isEnabled, "迁移不得把数据默默改道 iCloud，同步开关需用户自己重新打开")
        // 通道专属配置原样保留，后续版本重新放开时用户不必重配
        XCTAssertEqual(engine.webDavURL, "https://dav.example.com")
        XCTAssertEqual(engine.webDavUsername, "alice")
    }

    /// 本地目录映射同样是不可选通道，迁移到 iCloud 后自定义目录配置不得被清零。
    func testLegacyLocalDirectorySyncModeMigratesToICloudKeepingDirectoryConfig() {
        let defaults = makeIsolatedDefaults()
        defaults.set("local_dir", forKey: "nook.sync.mode")
        defaults.set("/tmp/nook-custom-sync", forKey: "iCloudSyncDirectoryCustomPath")

        let engine = ICloudDriveSyncEngine(
            defaults: defaults,
            secretsNamespace: "test.nook.migrate.\(UUID().uuidString)"
        )

        XCTAssertEqual(engine.syncMode, .iCloudDrive)
        XCTAssertEqual(
            defaults.string(forKey: "iCloudSyncDirectoryCustomPath"),
            "/tmp/nook-custom-sync",
            "自定义目录配置属于通道专属设置，迁移时不得清除"
        )
    }

    /// iCloud 是可选通道：构造引擎不得改写它（迁移逻辑只处理不可选通道）。
    func testSupportedSyncModeIsNotRewrittenOnInit() {
        let defaults = makeIsolatedDefaults()
        defaults.set("icloud", forKey: "nook.sync.mode")

        let engine = ICloudDriveSyncEngine(
            defaults: defaults,
            secretsNamespace: "test.nook.migrate.\(UUID().uuidString)"
        )

        XCTAssertEqual(engine.syncMode, .iCloudDrive)
        XCTAssertEqual(defaults.string(forKey: "nook.sync.mode"), "icloud")
    }

    // MARK: - E2EE 敏感同步：判定口径与一次性引导

    /// 新增回归：仅勾选 E2EE 但口令为空时，界面文案不得声称「已加密同步」，
    /// 同步层也必须继续过滤敏感条目（此前 `isE2EEEnabled && syncSensitiveItems` 会误判）。
    func testSensitiveSyncRequiresPassphraseNotJustE2EEToggle() {
        let defaults = makeIsolatedDefaults()
        let engine = ICloudDriveSyncEngine(
            defaults: defaults,
            secretsNamespace: "test.nook.sensitive.\(UUID().uuidString)"
        )
        engine.isEnabled = true
        engine.syncMode = .webdav
        engine.isE2EEEnabled = true
        engine.syncSensitiveItems = true
        engine.e2eePassphrase = ""

        // 勾了 E2EE + 开了敏感同步，但没有口令 → 不生效
        XCTAssertFalse(engine.isE2EESensitiveSyncActive)
        XCTAssertFalse(engine.makeSyncOptions(deviceId: "mac-1", localAssetsDir: "/tmp/assets").allowSensitive)

        // 口令为纯空白同样不生效，防止 trim 后为空的边界
        engine.e2eePassphrase = "   "
        XCTAssertFalse(engine.isE2EESensitiveSyncActive)

        // 补齐口令后才真正生效
        engine.e2eePassphrase = "a-real-passphrase-2026"
        XCTAssertTrue(engine.isE2EESensitiveSyncActive)
        let opts = engine.makeSyncOptions(deviceId: "mac-1", localAssetsDir: "/tmp/assets")
        XCTAssertTrue(opts.allowSensitive)
        XCTAssertEqual(opts.passphrase, "a-real-passphrase-2026")

        // 关闭 E2EE 立刻回到安全默认
        engine.isE2EEEnabled = false
        XCTAssertFalse(engine.isE2EESensitiveSyncActive)
        XCTAssertFalse(engine.makeSyncOptions(deviceId: "mac-1", localAssetsDir: "/tmp/assets").allowSensitive)
    }

    /// 同步整体关闭时，敏感同步必然不生效，且不得为了回答这个问题去读口令。
    /// 这是「首次启动就弹钥匙串密码」的直接根因回归测试。
    func testSensitiveSyncInactiveWhenSyncDisabledAndSecretNotRead() {
        let defaults = makeIsolatedDefaults()
        var legacyReadCount = 0
        let engine = ICloudDriveSyncEngine(
            defaults: defaults,
            secretsNamespace: "test.nook.disabled.\(UUID().uuidString)",
            legacySecretReader: { _, _ in
                legacyReadCount += 1
                return nil
            }
        )
        engine.syncMode = .iCloudDrive
        engine.isE2EEEnabled = true
        engine.syncSensitiveItems = true
        engine.e2eePassphrase = "should-not-be-read"

        // 同步关闭：既不算敏感同步生效，也不碰旧钥匙串
        XCTAssertFalse(engine.isEnabled)
        XCTAssertFalse(engine.isE2EESensitiveSyncActive)
        XCTAssertEqual(legacyReadCount, 0)

        // 打开同步后同一口令才被认可（iCloud 通道的 E2EE 已在上面显式开启）
        engine.isEnabled = true
        XCTAssertTrue(engine.isE2EESensitiveSyncActive)
    }

    /// 口令必须落到 0600 本地文件，且不再写入系统钥匙串。
    func testSyncPassphraseStoredInRestrictedFile() throws {
        let defaults = makeIsolatedDefaults()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("nook-secret-store-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let engine = ICloudDriveSyncEngine(
            defaults: defaults,
            secretsNamespace: "store",
            secretStoreDirectory: dir,
            legacySecretReader: { _, _ in nil }
        )
        engine.isEnabled = true
        engine.syncMode = .webdav
        engine.e2eePassphrase = "file-backed-passphrase"

        XCTAssertEqual(engine.e2eePassphrase, "file-backed-passphrase")

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(files.count, 1, "同步口令应落在一个本地文件里")
        let fileURL = dir.appendingPathComponent(files[0])
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perms, 0o600, "同步口令文件的权限必须是 0600")

        // 新实例（模拟重启）能读回，证明不依赖内存缓存
        let reopened = ICloudDriveSyncEngine(
            defaults: defaults,
            secretsNamespace: "store",
            secretStoreDirectory: dir,
            legacySecretReader: { _, _ in nil }
        )
        XCTAssertEqual(reopened.e2eePassphrase(for: .webdav), "file-backed-passphrase")
    }

    /// 旧钥匙串里是按通道存的（账号名 sync_passphrase_<通道>），
    /// 迁移时必须逐通道搬迁，不能只找更早的单通道账号。
    func testLegacyPerChannelPassphraseMigratesIntoFile() {
        let defaults = makeIsolatedDefaults()
        let legacyStore = ["sync_passphrase_webdav": "webdav-legacy-pass"]
        let namespace = "test.nook.perchannel.\(UUID().uuidString)"
        var readAccounts: [String] = []
        let engine = ICloudDriveSyncEngine(
            defaults: defaults,
            secretsNamespace: namespace,
            legacySecretReader: { _, account in
                readAccounts.append(account)
                return legacyStore[account]
            }
        )
        engine.isEnabled = true
        engine.syncMode = .webdav

        XCTAssertEqual(engine.e2eePassphrase(for: .webdav), "webdav-legacy-pass")
        XCTAssertTrue(readAccounts.contains("sync_passphrase_webdav"), "必须按通道账号尝试迁移")

        // 已落盘：换成「读旧钥匙串必失败」的引擎，也照样读得到
        let afterRestart = ICloudDriveSyncEngine(
            defaults: defaults,
            secretsNamespace: namespace,
            legacySecretReader: { _, _ in nil }
        )
        XCTAssertEqual(afterRestart.e2eePassphrase(for: .webdav), "webdav-legacy-pass")

        // 用户主动清空口令后重启：即便旧钥匙串里仍保留条目（供回退旧版本使用），
        // 也不得再次从旧钥匙串复活口令，也不得重复穿透查询旧钥匙串。
        afterRestart.setE2EEPassphrase("", for: .webdav)
        XCTAssertEqual(afterRestart.e2eePassphrase(for: .webdav), "")

        var postClearLegacyReads = 0
        let afterClearRestart = ICloudDriveSyncEngine(
            defaults: defaults,
            secretsNamespace: namespace,
            legacySecretReader: { _, account in
                postClearLegacyReads += 1
                return legacyStore[account]
            }
        )
        afterClearRestart.isEnabled = true
        XCTAssertEqual(
            afterClearRestart.e2eePassphrase(for: .webdav),
            "",
            "用户清空口令后重启不得从旧钥匙串复活旧口令"
        )
        XCTAssertEqual(postClearLegacyReads, 0, "已完成迁移的账号不得再次穿透读取旧钥匙串")
    }

    /// 同步开启但旧钥匙串与本地均无口令时，迁移探测最多执行一次，后续读取不得反复穿透查询钥匙串。
    func testEmptyLegacyPassphraseProbesKeychainAtMostOnce() {
        let defaults = makeIsolatedDefaults()
        let namespace = "test.nook.emptyprobe.\(UUID().uuidString)"
        var readAccounts: [String] = []
        let engine = ICloudDriveSyncEngine(
            defaults: defaults,
            secretsNamespace: namespace,
            legacySecretReader: { _, account in
                readAccounts.append(account)
                return nil
            }
        )
        engine.isEnabled = true
        engine.syncMode = .iCloudDrive

        XCTAssertEqual(engine.e2eePassphrase(for: .iCloudDrive), "")
        let firstPassReads = readAccounts.count
        XCTAssertGreaterThan(firstPassReads, 0, "首次读取应尝试一次性旧钥匙串迁移")

        // 同一实例再次读取 & 重建实例（模拟重启）再次读取：均不得再穿透旧钥匙串
        XCTAssertEqual(engine.e2eePassphrase(for: .iCloudDrive), "")
        XCTAssertEqual(readAccounts.count, firstPassReads, "空口令完成一次性探测后应命中缓存/迁移标记")

        let reopened = ICloudDriveSyncEngine(
            defaults: defaults,
            secretsNamespace: namespace,
            legacySecretReader: { _, account in
                readAccounts.append(account)
                return nil
            }
        )
        reopened.isEnabled = true
        XCTAssertEqual(reopened.e2eePassphrase(for: .iCloudDrive), "")
        XCTAssertEqual(readAccounts.count, firstPassReads, "重启后也不得重复查询旧钥匙串")
    }

    /// 一次性引导：未决策前为 false；记录后为 true；且必须按通道独立。
    func testSensitiveSyncDecisionIsRecordedOncePerMode() {
        let suite = "com.nook.test.sensitivedecided.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let engine = ICloudDriveSyncEngine(
            defaults: defaults,
            secretsNamespace: "test.nook.sensitivedecided.\(UUID().uuidString)"
        )

        XCTAssertFalse(engine.hasDecidedSensitiveSync(for: .iCloudDrive))
        engine.markSensitiveSyncDecided(for: .iCloudDrive)
        XCTAssertTrue(engine.hasDecidedSensitiveSync(for: .iCloudDrive))

        // 其他通道不受影响，避免 iCloud 决策泄漏到 WebDAV
        XCTAssertFalse(engine.hasDecidedSensitiveSync(for: .webdav))
        XCTAssertFalse(engine.hasDecidedSensitiveSync(for: .localDirectory))

        // 决策标记必须持久化，App 重启后不再重复弹窗
        let reloaded = ICloudDriveSyncEngine(
            defaults: UserDefaults(suiteName: suite)!,
            secretsNamespace: "test.nook.sensitivedecided.reload"
        )
        XCTAssertTrue(reloaded.hasDecidedSensitiveSync(for: .iCloudDrive))
    }

    /// 预览区胶囊文案必须跟随「敏感同步是否真的生效」：开启后不得再声称「绝不上云」。
    @MainActor
    func testPreviewSensitiveBadgeFollowsSensitiveSyncState() {
        XCTAssertEqual(
            PreviewPane.sensitiveSyncBadgeKey(isSensitiveSyncActive: false),
            "preview.sensitive.local_only",
            "未开启敏感同步时保持本地边界承诺"
        )
        XCTAssertEqual(
            PreviewPane.sensitiveSyncBadgeKey(isSensitiveSyncActive: true),
            "preview.sensitive.e2ee_sync",
            "已开启端到端加密跨端同步后，胶囊必须改成加密同步文案"
        )
    }

    /// 设置写入必须让可观测版本号自增，否则预览区胶囊拿不到失效通知（会一直显示旧文案）。
    @MainActor
    func testSensitiveSyncConfigWritesBumpObservableRevision() {
        let suite = "com.nook.test.sensitiverevision.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let engine = ICloudDriveSyncEngine(
            defaults: defaults,
            secretsNamespace: "test.nook.sensitiverevision.\(UUID().uuidString)"
        )

        let start = engine.sensitiveSyncConfigRevision
        engine.isE2EEEnabled = true
        XCTAssertGreaterThan(engine.sensitiveSyncConfigRevision, start, "E2EE 开关写入必须触发重算")

        let afterToggle = engine.sensitiveSyncConfigRevision
        engine.syncSensitiveItems = true
        XCTAssertGreaterThan(engine.sensitiveSyncConfigRevision, afterToggle, "敏感同步开关写入必须触发重算")

        let afterSensitive = engine.sensitiveSyncConfigRevision
        engine.e2eePassphrase = "a-real-passphrase-2026"
        XCTAssertGreaterThan(engine.sensitiveSyncConfigRevision, afterSensitive, "口令写入必须触发重算")

        let afterPass = engine.sensitiveSyncConfigRevision
        engine.syncMode = .webdav
        XCTAssertGreaterThan(engine.sensitiveSyncConfigRevision, afterPass, "切换同步通道必须触发重算")
    }
}
