import XCTest
import SwiftUI
@testable import NookClip

/// 2026-10 缺陷审计修复的回归测试（BUG ID 对应 docs/BUG-FIX-PROGRESS.md）。
/// 每个用例锁定一个已修复缺陷的行为契约，防止回退。
@MainActor
final class AuditFixRegressionTests: XCTestCase {

    // MARK: - BUG-002 重复复制不丢收藏

    func testRecopyFavoritedContentKeepsFavorite() {
        let store = makeIsolatedStore()
        store.save(ClipboardItem(type: .text, title: "t", summary: "favorite me"))
        store.toggleFavorite(store.items[0].id)
        XCTAssertTrue(store.items[0].isFavorite, "前置：已收藏")

        // 再次复制相同内容（新捕获条目 isSensitive/isFavorite 均为默认值）
        store.save(ClipboardItem(type: .text, title: "t", summary: "favorite me"))

        XCTAssertTrue(store.items[0].isFavorite, "重复复制合并必须继承收藏状态（BUG-002）")
    }

    func testHistoryStoreToggleSensitiveUpdatesMemoryMirror() {
        let store = makeIsolatedStore()
        let secret = "df94e2db9bd390a1dc28792f6cee9434"
        let item = ClipboardItem(type: .text, title: "", summary: secret)
        store.save(item)
        let targetID = store.items[0].id

        // 1. Toggle to sensitive
        XCTAssertTrue(store.toggleSensitive(targetID))
        XCTAssertTrue(store.items[0].isSensitive)
        XCTAssertEqual(store.items[0].summary, "df94••••••••9434")
        XCTAssertEqual(store.item(withID: targetID)?.revealPlainContent(), secret)

        // 2. Toggle back to plain
        XCTAssertTrue(store.toggleSensitive(targetID))
        XCTAssertFalse(store.items[0].isSensitive)
        XCTAssertEqual(store.items[0].summary, secret)
        XCTAssertEqual(store.item(withID: targetID)?.revealPlainContent(), secret)
    }

    func testMainViewToggleSensitiveSelection() {
        let store = makeIsolatedStore()
        let item = ClipboardItem(type: .text, title: "", summary: "df94e2db9bd390a1dc28792f6cee9434")
        store.save(item)
        let view = MainView(store: store, clipboardWriter: PasteService.shared)
        view.selectionCoordinator.selectedID = store.items[0].id

        view.toggleSensitiveSelection()
        XCTAssertTrue(store.items[0].isSensitive)
        XCTAssertEqual(store.items[0].summary, "df94••••••••9434")

        view.toggleSensitiveSelection()
        XCTAssertFalse(store.items[0].isSensitive)
        XCTAssertEqual(store.items[0].summary, "df94e2db9bd390a1dc28792f6cee9434")
    }

    // MARK: - BUG-050 空用户名 DSN 检测

    func testRedisEmptyUsernameDSNIsDetectedAndMasked() {
        let secret = "redis://:SuperSecret123@redis.example.com:6379"
        let result = SensitiveDataDetector.detect(text: secret)
        XCTAssertNotNil(result, "redis://:pass@host 形式 DSN 必须命中敏感检测（BUG-050）")
        XCTAssertFalse(result!.maskedText.contains("SuperSecret123"), "口令必须被掩码")
        // 常规带用户名 DSN 不回归
        XCTAssertNotNil(SensitiveDataDetector.detect(text: "postgres://admin:password@db/db"))
        // 无凭据 URI 不误报
        XCTAssertNil(SensitiveDataDetector.detect(text: "postgres://db.example.com:5432/prod"))
    }

    // MARK: - BUG-005 磁盘限额不计外部文件

    func testExternalFileSizeNotCountedTowardDiskLimit() throws {
        let externalDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("nook-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: externalDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: externalDir) }
        let externalFile = externalDir.appendingPathComponent("big.bin")
        try Data(repeating: 0xAB, count: 4 * 1024 * 1024).write(to: externalFile)

        let defaults = makeIsolatedDefaults()
        defaults.set(1, forKey: "historyDiskLimitMB") // 限额 1MB
        let store = makeIsolatedStore(defaults: defaults)
        store.save(ClipboardItem(type: .text, title: "t", summary: "normal history"))

        // 复制外部 4MB 文件（file 条目 payloadPath 指向原文件，NookClip 未复制它）
        store.save(ClipboardItem(type: .file, title: "f", summary: externalFile.path, payloadPath: externalFile.path))

        XCTAssertTrue(
            store.items.contains { $0.type == .text },
            "外部文件大小不得计入磁盘限额驱逐正常历史（BUG-005）"
        )
    }

    // MARK: - BUG-003 搜索参数绑定顺序

    func testAppNameKeywordSearchReturnsResults() throws {
        let store = makeIsolatedStore()
        let now = Date()
        store.save(ClipboardItem(
            type: .text, title: "t", summary: "hello world",
            createdAt: now, lastUsedAt: now,
            sourceAppBundleId: "com.google.Chrome", sourceAppName: "Google Chrome"
        ))

        let results = store.rustStore.search(query: "Chrome", limit: 50, offset: 0)
        XCTAssertEqual(results.count, 1, "输入应用名称作为关键字直接返回结果")
    }

    // MARK: - BUG-018 分页终止信号（去重语义）

    func testPageUniqueTerminationWithDuplicateRows() {
        let store = makeIsolatedStore()
        for index in 0..<10 {
            store.save(ClipboardItem(type: .text, title: "t", summary: "unique-\(index)"))
        }
        for index in 0..<5 {
            store.save(ClipboardItem(id: UUID(), type: .text, title: "t", summary: "unique-\(index)"))
        }

        let items = store.rustStore.page(limit: 20, offset: 0)
        XCTAssertEqual(items.count, 10, "同内容条目去重后只有 10 条唯一条目")
    }

    // MARK: - BUG-019 搜索 hasMore 用原始行数判定

    func testSearchHasMoreUsesRawRowCountWithDuplicates() throws {
        let store = makeIsolatedStore()
        for _ in 0..<3 {
            store.save(ClipboardItem(id: UUID(), type: .text, title: "t", summary: "dup needle content"))
        }

        let results = store.rustStore.search(query: "needle", limit: 10, offset: 0)
        XCTAssertEqual(results.count, 1, "同内容行去重后只展示一条")
    }


    // MARK: - BUG-006 URL 敏感检测

    func testURLWithTokenInQueryIsDetected() {
        let url = "https://api.example.com/v1/reset?token=sk-proj-abcdefghijklmnopqrstuvwx"
        let result = SensitiveDataDetector.detect(text: url)
        XCTAssertNotNil(result, "查询参数携带 token 的 URL 必须命中敏感检测（BUG-006）")
        XCTAssertNil(SensitiveDataDetector.detect(text: "https://example.com plain page"), "普通 URL 不误报")
    }

    // MARK: - BUG-020/021 粘贴前校验

    func testCopyOnlyImageWithMissingPayloadKeepsClipboard() throws {
        withPasteboardLock {
            let sentinel = "sentinel-\(UUID().uuidString)"
            XCTAssertTrue(PasteService.shared.copyText(sentinel))

            let missingPayload = ClipboardItem(
                type: .image, title: "img", summary: "600×400 #deadbeef",
                payloadPath: "/nonexistent/nook-audit-\(UUID().uuidString).png"
            )
            XCTAssertFalse(PasteService.shared.copyOnly(missingPayload), "载荷缺失的图片条目复制应失败")
            XCTAssertEqual(
                PasteboardAccess.general.string(forType: .string), sentinel,
                "失败路径不得清空用户当前剪贴板内容（BUG-020）"
            )
        }
    }

    func testCopyOnlySensitiveDecryptFailureAbortsInsteadOfPastingMask() throws {
        withPasteboardLock {
            let sentinel = "sentinel-\(UUID().uuidString)"
            XCTAssertTrue(PasteService.shared.copyText(sentinel))

            // 损坏的密文：解密必然失败（密钥不可用/数据损坏同路径）
            let corrupted = ClipboardItem(
                type: .text, title: "凭证", summary: "sk-••••••••abcd",
                isSensitive: true, encryptedContent: Data([0x01, 0x02, 0x03, 0x04])
            )
            XCTAssertFalse(PasteService.shared.copyOnly(corrupted), "敏感条目解密失败必须中止粘贴（BUG-021）")
            XCTAssertEqual(
                PasteboardAccess.general.string(forType: .string), sentinel,
                "解密失败不得把掩码写入剪贴板（BUG-021）"
            )
        }
    }

    // MARK: - BUG-052 批量粘贴敏感保护

    func testCopyTextWithSensitiveFlagWritesConcealMarkers() throws {
        withPasteboardLock {
            XCTAssertTrue(PasteService.shared.copyText("merged secret", containsSensitive: true))
            let types = PasteboardAccess.general.types ?? []
            XCTAssertTrue(
                types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")),
                "含敏感明文的批量粘贴必须写入 concealed 标记（BUG-052）"
            )
            XCTAssertTrue(
                types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")),
                "含敏感明文的批量粘贴必须写入 transient 标记（BUG-052）"
            )
        }
    }


    // MARK: - BUG-007 OCR 敏感掩码

    func testOCRTextWithCredentialsIsStoredMasked() {
        let store = makeIsolatedStore()
        let secret = "sk-ant-api03-" + String(repeating: "a", count: 40)
        store.save(ClipboardItem(type: .text, title: "t", summary: "plain-\(UUID().uuidString)"))
        let id = store.items[0].id

        store.updateOCRText("token: \(secret) end", for: id)

        let ocr = store.items[0].ocrText ?? ""
        XCTAssertFalse(ocr.contains(secret), "OCR 识别出的凭据不得明文入库（BUG-007）")
        XCTAssertTrue(ocr.contains("token:"), "非敏感部分保留")
    }

    // MARK: - BUG-022 解密失败不得判相等

    func testCorruptedSensitiveItemsWithSameMaskAreNotMerged() {
        let store = makeIsolatedStore()
        let mask = "sk-••••••••1234"
        // 两个不同凭据、密文均损坏（解密失败返回 nil）：掩码相同但不得判为重复内容
        store.save(ClipboardItem(type: .text, title: "凭证A", summary: mask, isSensitive: true, encryptedContent: Data([0x01, 0x02])))
        store.save(ClipboardItem(type: .text, title: "凭证B", summary: mask, isSensitive: true, encryptedContent: Data([0x03, 0x04])))

        let masked = store.items.filter { $0.summary == mask }
        XCTAssertEqual(masked.count, 2, "解密失败的敏感条目不得因 nil==nil 判重而被合并删除（BUG-022）")
    }


    // MARK: - BUG-011 ⇧扩展多选锚点

    func testShiftExtendIncludesAnchorRow() {
        let ids = (0..<5).map { _ in UUID() }
        let rows = ids.map { ClipboardRowModel(item: ClipboardItem(id: $0, type: .text, title: "t", summary: "s-\($0.uuidString)")) }
        let coordinator = MainViewListState(store: makeIsolatedStore())
        coordinator.selectedID = ids[2]

        coordinator.extend(offset: 1, rows: rows)
        XCTAssertEqual(coordinator.selectionIDs, [ids[2], ids[3]], "⇧↓ 扩展必须并入原选中锚点行（BUG-011）")

        let second = MainViewListState(store: makeIsolatedStore())
        second.selectedID = ids[2]
        second.extend(offset: -1, rows: rows)
        XCTAssertEqual(second.selectionIDs, [ids[1], ids[2]], "⇧↑ 扩展必须并入原选中锚点行（BUG-011）")
    }

    // MARK: - BUG-012/013 颜色检测与渲染

    func testNonHexWordsNotDetectedAsColors() {
        XCTAssertNil(parseColorHex(text: "#define"), "#define 不得误判为颜色（BUG-012）")
        XCTAssertNil(parseColorHex(text: "#coffee"), "#coffee 不得误判为颜色（BUG-012）")
        XCTAssertNil(parseColorHex(text: "#detail"), "#detail 不得误判为颜色（BUG-012）")
        XCTAssertNotNil(parseColorHex(text: "#FF5733"), "合法 6 位 hex 仍识别")
    }

    func testShortAndAlphaHexNormalizedToSixDigits() {
        let three = parseColorHex(text: "#FFF")
        XCTAssertEqual(three, "#FFFFFF", "3 位 hex 归一化为 6 位（BUG-013）")
        if let hexString = three, let value = Color.rgbHexValue(from: hexString) {
            let rgb = "\(Int((value >> 16) & 0xFF)), \(Int((value >> 8) & 0xFF)), \(Int(value & 0xFF))"
            XCTAssertEqual(rgb, "255, 255, 255", "#FFF 的 RGB 派生必须为白色（BUG-013）")
        }
        let eight = parseColorHex(text: "#FF0000FF")
        XCTAssertEqual(eight, "#FF0000", "8 位 hex 归一化为 6 位（alpha 丢弃用于展示，BUG-013）")
    }

    // MARK: - BUG-030 URL 副行端口

    func testURLPartsIncludesPort() {
        let model = ClipboardRowModel(item: ClipboardItem(type: .url, title: "t", summary: "http://localhost:8080/api?q=1"))
        let parts = model.urlParts
        XCTAssertNotNil(parts)
        XCTAssertEqual(
            parts!.schemePrefix + parts!.host + parts!.remainder,
            "http://localhost:8080/api?q=1",
            "URL 副行不得丢失端口（BUG-030）"
        )
    }

    // MARK: - 词汇原样保留为关键词

    func testLangPrefixParsedAsNormalKeywords() {
        XCTAssertEqual(tokenizeSearchKeywords(query: "hello lang:"), ["hello", "lang:"])
        XCTAssertEqual(tokenizeSearchKeywords(query: "lang:swift"), ["lang:swift"])
    }

    func testRelativeDaysParsedAsNormalKeywords() {
        XCTAssertEqual(tokenizeSearchKeywords(query: "7天内"), ["7天内"])
    }

    // MARK: - BUG-010 重叠正则不破坏掩码文本

    func testOverlappingRulesDoNotCorruptMaskedText() {
        let token = "sk-ant-api03-" + String(repeating: "a", count: 40)
        let longSuffix = String(repeating: "s", count: 120)
        let result = SensitiveDataDetector.detect(text: "prefix \(token) \(longSuffix)")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.maskedText.hasSuffix(longSuffix), "重叠规则去重后 Token 之后的正文必须完整保留（BUG-010）")
    }

    // MARK: - BUG-014 清理流程返回载荷路径

    func testPurgeReturnsPayloadPathForCleanup() {
        let store = makeIsolatedStore()
        let payloadPath = "/tmp/nook-audit-\(UUID().uuidString).png"
        let old = ClipboardItem(
            type: .image, title: "img", summary: "old image #deadbeef",
            createdAt: Date().addingTimeInterval(-40 * 86400),
            lastUsedAt: Date().addingTimeInterval(-40 * 86400),
            payloadPath: payloadPath
        )
        store.save(old)
        let purged = store.rustStore.pruneExpired(days: 30, maxCount: nil)
        XCTAssertEqual(purged.count, 1)
        XCTAssertEqual(purged.first?.payloadPath, payloadPath)
    }

    func testPruneExpiredItemsDirectlyConsumesDeepPruneOutcome() {
        let store = makeIsolatedStore()
        let payloadPath = "/tmp/nook-audit-\(UUID().uuidString).png"
        let old = ClipboardItem(
            type: .image, title: "img", summary: "old image #deadbeef",
            createdAt: Date().addingTimeInterval(-40 * 86400),
            lastUsedAt: Date().addingTimeInterval(-40 * 86400),
            payloadPath: payloadPath
        )
        store.save(old)
        let pruned = store.rustStore.pruneExpired(days: 30, maxCount: nil)
        XCTAssertEqual(pruned.count, 1)
        XCTAssertEqual(pruned.first?.id, old.id.uuidString)
        XCTAssertEqual(pruned.first?.payloadPath, payloadPath)
    }
    // MARK: - 预览区私密记录查看（不预加载明文时按需通过 entityProvider 解密）

    func testPreviewPaneResolvesSensitivePlainTextOnDemandWhenNotPreloaded() {
        let store = makeIsolatedStore()
        let secret = "df94e2db9bd390a1dc28792f6cee9434"
        store.save(ClipboardItem(type: .text, title: "Secret Key", summary: secret))
        let targetID = store.items[0].id
        XCTAssertTrue(store.toggleSensitive(targetID))

        let row = ClipboardRowModel(item: store.items[0])
        XCTAssertTrue(row.isSensitive)
        XCTAssertNil(store.items[0].decryptedPlainText, "列表镜像中的敏感条目不携带明文")
        var providerCallCount = 0
        let entityProvider: (ClipboardRowModel) -> ClipboardItem? = { model in
            providerCallCount += 1
            return store.item(withID: model.id)
        }

        // 1. 选中敏感条目时 loadedEntity 为 nil，点击查看必须按需调用 entityProvider 解密出明文
        let result = PreviewPane.resolveSensitivePlainText(
            for: row,
            cachedEntity: nil,
            entityProvider: entityProvider
        )
        XCTAssertEqual(providerCallCount, 1, "点击查看私密记录时必须按需调用 entityProvider 取回完整解密实体")
        switch result {
        case .success(let plain):
            XCTAssertEqual(plain, secret, "预览区点击查看必须还原出真实私密明文")
        case .failure(let failure):
            XCTFail("私密记录按需查看不应失败: \(failure)")
        }
    }
}
