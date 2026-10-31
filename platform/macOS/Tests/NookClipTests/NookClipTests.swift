import AppKit
import Carbon.HIToolbox
import SQLite3
import SwiftUI
import XCTest
@testable import NookClip

@MainActor
final class NookClipTests: XCTestCase {
    func testSensitiveDataDetectorAndCrypto() {
        // 1. SensitiveDataDetector tests
        let openAIKey = "sk-proj-1234567890abcdef1234567890"
        let openAIResult = SensitiveDataDetector.detect(text: openAIKey)
        XCTAssertNotNil(openAIResult)
        XCTAssertTrue(openAIResult!.isSensitive)
        XCTAssertEqual(openAIResult!.category, "API Key")

        XCTAssertTrue(openAIResult!.maskedText.hasPrefix("sk-proj-"))
        XCTAssertTrue(openAIResult!.maskedText.hasSuffix("7890"))
        XCTAssertFalse(openAIResult!.maskedText.contains("abcdef"))

        let awsKey = "AKIAIOSFODNN7EXAMPLE"
        let awsResult = SensitiveDataDetector.detect(text: awsKey)
        XCTAssertNotNil(awsResult)
        XCTAssertEqual(awsResult!.category, "AWS")
        XCTAssertEqual(awsResult!.maskedText, "AKIA••••••••MPLE")

        let dbURL = "postgres://root:supersecret123@10.0.0.1:5432/production"
        let dbResult = SensitiveDataDetector.detect(text: dbURL)
        XCTAssertNotNil(dbResult)
        XCTAssertEqual(dbResult!.category, "Database")
        XCTAssertEqual(dbResult!.maskedText, "postgres://root:••••••••@10.0.0.1:5432/production")

        let normalCode = "func calculateSum(a: Int, b: Int) -> Int { return a + b }"
        XCTAssertNil(SensitiveDataDetector.detect(text: normalCode))

        // 2. KeychainCryptoService encrypt & decrypt tests
        let crypto = KeychainCryptoService.shared
        let secret = "ghp_1234567890abcdef1234567890abcdef123456"
        guard let encrypted = crypto.encrypt(text: secret) else {
            XCTFail("Encryption returned nil")
            return
        }
        XCTAssertFalse(encrypted.isEmpty)
        let decrypted = crypto.decrypt(cipherData: encrypted)
        XCTAssertEqual(decrypted, secret)
    }

    func testLegacyMasterKeyFile() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("nook-key-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 存量文件用户：App Support 下已有 .master_key 文件（32 字节，0600）
        let keyFileURL = tempDir.appendingPathComponent(".master_key")
        let legacyKeyData = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        try! legacyKeyData.write(to: keyFileURL, options: [.atomic])
        try! FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFileURL.path)

        let keychainService = "test.nook.crypto.\(UUID().uuidString)"
        let legacy = KeychainCryptoService(keyFileURL: keyFileURL, keychainService: keychainService)
        let secret = "sk-proj-legacy-file-key-secret-123456"
        guard let cipher = legacy.encrypt(text: secret) else {
            XCTFail("Existing file key must remain usable")
            return
        }

        // 模拟重启后的新实例：文件密钥是唯一运行时来源，历史密文仍可解密
        let reloaded = KeychainCryptoService(keyFileURL: keyFileURL, keychainService: keychainService)
        XCTAssertEqual(reloaded.decrypt(cipherData: cipher), secret,
                       "Ciphertext must stay decryptable across instances via file key")

        // 文件保留且权限仍为 0600（存在即用，绝不迁移删除）
        XCTAssertTrue(FileManager.default.fileExists(atPath: keyFileURL.path),
                      "File master key must be retained as the runtime source")
        let attrs = try! FileManager.default.attributesOfItem(atPath: keyFileURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.int16Value, 0o600)
    }

    func testNewMasterKeyIsPersistedBeforeUse() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("nook-key-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 全新环境：无旧文件、独立 Keychain service
        let keyFileURL = tempDir.appendingPathComponent(".master_key")
        let keychainService = "test.nook.crypto.\(UUID().uuidString)"
        let service = KeychainCryptoService(keyFileURL: keyFileURL, keychainService: keychainService)
        defer { service.deleteKeychainItemForTesting() }

        let secret = "sk-proj-new-key-persist-secret-654321"
        guard let cipher = service.encrypt(text: secret) else {
            XCTFail("New key must be created and persisted before use")
            return
        }

        // 新密钥必须先原子落盘 0600 文件才能使用，绝非仅内存缓存
        XCTAssertTrue(FileManager.default.fileExists(atPath: keyFileURL.path),
                      "New key must be persisted to file before use")
        let attrs = try! FileManager.default.attributesOfItem(atPath: keyFileURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.int16Value, 0o600)

        let reloaded = KeychainCryptoService(keyFileURL: keyFileURL, keychainService: keychainService)
        XCTAssertEqual(reloaded.decrypt(cipherData: cipher), secret,
                       "New key must be recoverable by a fresh instance (persisted before use)")
    }

    func testPreviouslyInitializedMasterKeyMissingRefusesReplacement() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("nook-key-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let keyFileURL = tempDir.appendingPathComponent(".master_key")
        let keychainService = "test.nook.crypto.\(UUID().uuidString)"
        let initKey = "nook.crypto.initialized.\(keychainService)"
        UserDefaults.standard.set(true, forKey: initKey)
        defer { UserDefaults.standard.removeObject(forKey: initKey) }

        // 无文件且 Keychain 缺失，但此前已标记初始化：必须拒签，严禁生成新密钥替换历史密钥
        let service = KeychainCryptoService(keyFileURL: keyFileURL, keychainService: keychainService)
        XCTAssertNil(service.getOrCreateKey(), "已初始化的主密钥丢失时必须拒绝创建替代密钥以防数据覆写")
        XCTAssertNil(service.encrypt(text: "secret"), "密钥不可用时加密应返回 nil")
    }

    func testDecryptCorruptedCiphertextReturnsNil() {
        let crypto = KeychainCryptoService.shared
        let corruptedData = Data([0x01, 0x02, 0x03, 0x04])
        XCTAssertNil(crypto.decrypt(cipherData: corruptedData), "损坏或截断密文解密必须返回 nil")
    }

    func testSQLiteSensitiveItemPersistence() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = makeIsolatedStore()
        let secret = "sk-proj-9876543210abcdef0123456789"
        let detection = SensitiveDataDetector.detect(text: secret)!
        let encrypted = KeychainCryptoService.shared.encrypt(text: secret)!

        let sensitiveItem = ClipboardItem(
            type: .text,
            title: "",
            summary: detection.maskedText,
            isSensitive: true,
            encryptedContent: encrypted
        )

        store.save(sensitiveItem)

        let all = store.items
        XCTAssertEqual(all.count, 1)
        let loaded = all.first!
        XCTAssertTrue(loaded.isSensitive)
        XCTAssertEqual(loaded.title, "")
        XCTAssertEqual(loaded.fallbackDisplayTitle, detection.maskedText, "展示回退 = 脱敏摘要")
        XCTAssertEqual(loaded.summary, detection.maskedText)
        XCTAssertNil(loaded.encryptedContent, "镜像不持有敏感明文（懒解密，列表路径不解密）")
        // 明文经全文契约按需取回（粘贴/预览统一路径）
        XCTAssertEqual(store.item(withID: loaded.id)?.revealPlainContent(), secret)
    }


    /// 旧 iCloud JSON 的 metadata 含 customTitle：解码忽略不炸（只修不加兼容读）
    func testLegacyMetadataCustomTitleIgnoredOnDecode() throws {
        let json = #"{"language":"swift","url":"https://example.com","customTitle":"旧别名"}"#
        let metadata = try JSONDecoder().decode(ClipboardMetadata.self, from: Data(json.utf8))
        XCTAssertEqual(metadata.language, "swift")
        XCTAssertEqual(metadata.url, "https://example.com")
    }

    /// 空 title 的展示回退：文本 → 内容预览并单行化；文件 → 文件名保持双行；
    /// 敏感 → 脱敏摘要
    func testRowModelEmptyTitleDisplayFallback() {
        let text = ClipboardRowModel(item: ClipboardItem(type: .text, title: "", summary: "第一行\n第二行"))
        XCTAssertEqual(text.displayTitle, "第一行\n第二行")
        XCTAssertTrue(text.isSubtitleRedundant, "回退文本即内容预览，副行重复 → 单行化")

        let file = ClipboardRowModel(item: ClipboardItem(type: .file, title: "", summary: "/tmp/a.md", payloadPath: "/tmp/a.md"))
        XCTAssertEqual(file.displayTitle, "a.md", "文件回退文件名")
        XCTAssertFalse(file.isSubtitleRedundant, "副行仍有路径/大小独立信息")

        let sensitive = ClipboardRowModel(item: ClipboardItem(type: .text, title: "", summary: "sk-••••7890", isSensitive: true))
        XCTAssertEqual(sensitive.displayTitle, "sk-••••7890", "敏感回退脱敏摘要")

        let image = ClipboardRowModel(item: ClipboardItem(type: .image, title: "", summary: "16×16 像素 · 1 KB #abcd1234"))
        XCTAssertEqual(image.displayTitle, "16×16 像素 · 1 KB", "图片回退尺寸信息（剥离 hash 尾巴）")
    }

    func testPasteServiceSensitiveCopy() throws {
        let secret = "sk-ant-api03-abcdef1234567890abcdef1234567890"
        let encrypted = KeychainCryptoService.shared.encrypt(text: secret)!
        let sensitiveItem = ClipboardItem(
            type: .text,
            title: "[Anthropic] sk-ant-...7890",
            summary: "[Anthropic] sk-ant-...7890",
            isSensitive: true,
            encryptedContent: encrypted
        )

        let pasteService = PasteService.shared
        withPasteboardLock {
            let success = pasteService.copyOnly(sensitiveItem)
            XCTAssertTrue(success)

            let pb = PasteboardAccess.general
            XCTAssertEqual(pb.string(forType: .string), secret)
            XCTAssertTrue(pb.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) == true)
            XCTAssertTrue(pb.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true)
        }
    }

    @MainActor
    func testPasteServiceWhenAccessibilityNotGrantedReturnsFalse() {
        let item = ClipboardItem(type: .text, title: "Test", summary: "Paste without accessibility")
        if !PasteService.isAccessibilityTrusted {
            withPasteboardLock {
                let success = PasteService.shared.paste(item)
                XCTAssertFalse(success, "辅助功能未授权时 paste 应返回 false")
                XCTAssertEqual(PasteboardAccess.general.string(forType: .string), "Paste without accessibility",
                               "虽未模拟击键，但内容仍应写入剪贴板以供用户手动 ⌘V")
            }
        }
    }

    @MainActor
    func testClearClipboardIfContentMatches() {
        withPasteboardLock {
            let pb = PasteboardAccess.general
            pb.clearContents()
            pb.setString("secret_token_123", forType: .string)

            // 不匹配时不清理
            PasteService.shared.clearClipboardIfContent(matches: "other_token")
            XCTAssertEqual(pb.string(forType: .string), "secret_token_123", "内容不匹配时不得清空剪贴板")

            // 匹配时清空
            PasteService.shared.clearClipboardIfContent(matches: "secret_token_123")
            XCTAssertNil(pb.string(forType: .string), "内容匹配时应彻底清空剪贴板")
        }
    }

    @MainActor
    func testSensitiveClipboardClearCancelledWhenOverwritten() async throws {
        UserDefaults.standard.set(1, forKey: "sensitiveClipboardTimeout")
        defer { UserDefaults.standard.removeObject(forKey: "sensitiveClipboardTimeout") }

        try await withPasteboardLock {
            let secret = "sk-proj-timeout-test-12345"
            _ = PasteService.shared.copyText(secret, containsSensitive: true)
            XCTAssertEqual(PasteboardAccess.general.string(forType: .string), secret)

            // 用户在自毁前写入了新内容
            PasteboardAccess.general.clearContents()
            PasteboardAccess.general.setString("user_new_copy", forType: .string)

            // 等待超过 1 秒自毁周期
            try await Task.sleep(nanoseconds: 1_200_000_000)

            // 剪贴板中用户的新内容必须完好保留，严禁误清
            XCTAssertEqual(PasteboardAccess.general.string(forType: .string), "user_new_copy", "剪贴板被新内容覆盖后自毁定时器不得误清")
        }
    }

    func testPasteServiceFileCopyValidatesExistence() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent("report.pdf")
        try Data("x".utf8).write(to: fileURL)

        let existingItem = ClipboardItem(type: .file, title: "report.pdf", summary: fileURL.path, payloadPath: fileURL.path)
        let missingPath = "/nonexistent-\(UUID().uuidString)/gone.txt"
        let missingItem = ClipboardItem(type: .file, title: "gone.txt", summary: missingPath, payloadPath: missingPath)

        // 非文件条目不受失效校验影响（不能被误拦）
        XCTAssertNil(PasteService.shared.staleFileMessage(for: ClipboardItem(type: .text, title: "t", summary: "hello")))

        withPasteboardLock {
            // 文件存在：写回文件引用（NSURL），Finder 可直接 ⌘V
            XCTAssertNil(PasteService.shared.staleFileMessage(for: existingItem))
            XCTAssertTrue(PasteService.shared.copyOnly(existingItem))
            let pb = PasteboardAccess.general
            let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
            XCTAssertEqual(urls.first?.path, fileURL.path)

            // 文件失效：返回提示（含缺失路径），且不清空剪贴板现状、不写入
            let sentinel = "sentinel-\(UUID().uuidString)"
            XCTAssertTrue(PasteService.shared.copyText(sentinel))
            XCTAssertFalse(PasteService.shared.copyOnly(missingItem))
            XCTAssertEqual(pb.string(forType: .string), sentinel)
            let message = PasteService.shared.staleFileMessage(for: missingItem)
            XCTAssertNotNil(message)
            XCTAssertTrue(message?.contains(missingPath) == true)
        }
    }
    func testPasteServiceSingleImageFileCopyProvidesImageAndTextFlavors() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pngURL = tempDir.appendingPathComponent("nookclip.png")
        let png1x1 = Data([
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
            0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89, 0x00, 0x00, 0x00,
            0x0a, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00, 0x00, 0x00, 0x00, 0x49,
            0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82
        ])
        try png1x1.write(to: pngURL)

        let imageFileItem = ClipboardItem(
            type: .file,
            title: "nookclip.png",
            summary: pngURL.path,
            payloadPath: pngURL.path
        )

        withPasteboardLock {
            let pb = PasteboardAccess.general

            // 1. 普通模式：同时提供文件引用、纯文本路径、图片数据（TIFF/PNG）
            XCTAssertTrue(PasteService.shared.copyOnly(imageFileItem, plainTextOnly: false))
            let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
            XCTAssertEqual(urls.first?.path, pngURL.path, "应包含文件对象供访达粘贴")
            XCTAssertEqual(pb.string(forType: .string), pngURL.path, "应包含纯文本路径供文本输入框粘贴")
            XCTAssertTrue(pb.types?.contains(.png) == true || pb.types?.contains(.tiff) == true, "应包含图片格式供聊天/文档软件粘贴")

            // 2. 纯文本模式：仅写入纯文本路径
            XCTAssertTrue(PasteService.shared.copyOnly(imageFileItem, plainTextOnly: true))
            XCTAssertEqual(pb.string(forType: .string), pngURL.path, "纯文本模式应提供路径文本")
            XCTAssertNil(pb.data(forType: .png), "纯文本模式不应写入图片数据")
        }
    }


    func testSensitiveFileItemPathRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        // 路径含密钥样内容：捕获侧应按敏感项处理，路径明文不落盘（payloadPath = nil）
        let secretPath = tempDir.appendingPathComponent("sk-ant-api03-1234567890abcdef1234.txt").path
        try Data("x".utf8).write(to: URL(fileURLWithPath: secretPath))
        XCTAssertNotNil(SensitiveDataDetector.detect(text: secretPath))

        let encrypted = KeychainCryptoService.shared.encrypt(text: secretPath)!
        let item = ClipboardItem(
            type: .file,
            title: "masked",
            summary: "masked",
            payloadPath: nil,
            isSensitive: true,
            encryptedContent: encrypted
        )
        XCTAssertEqual(item.revealPlainContent(), secretPath)

        withPasteboardLock {
            // 粘贴时解密还原路径并写回文件引用
            XCTAssertNil(PasteService.shared.staleFileMessage(for: item))
            XCTAssertTrue(PasteService.shared.copyOnly(item))
            let urls = PasteboardAccess.general.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
            XCTAssertEqual(urls.first?.path, secretPath)
        }
    }

    func testMultiFileCopyRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let first = tempDir.appendingPathComponent("a.pdf")
        let second = tempDir.appendingPathComponent("b.txt")
        try Data("1".utf8).write(to: first)
        try Data("22".utf8).write(to: second)
        let joined = [first.path, second.path].joined(separator: "\n")

        // 多文件条目：标题带数量（捕获侧 ClipboardMonitor 同规则），路径换行拼接
        let multiTitle = L10n.tr("item.file_multi_title", (first.path as NSString).lastPathComponent, 2)
        let item = ClipboardItem(type: .file, title: multiTitle, summary: joined, payloadPath: joined)
        XCTAssertTrue(item.title.contains("2") || item.title.contains("b.pdf"), "multi-file title should mention count: \(item.title)")
        XCTAssertEqual(PasteService.referencedFilePaths(item), [first.path, second.path])
        XCTAssertNil(PasteService.shared.staleFileMessage(for: item))

        // 任一文件缺失：整体视为失效，提示含缺失路径、不含存在路径
        try FileManager.default.removeItem(at: second)
        let message = PasteService.shared.staleFileMessage(for: item)
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains(second.path) == true)
        XCTAssertFalse(message?.contains(first.path) == true)

        // 敏感多文件：解密还原后同样按换行拆分
        let encrypted = KeychainCryptoService.shared.encrypt(text: joined)!
        let sensitiveItem = ClipboardItem(
            type: .file, title: "masked", summary: "masked",
            payloadPath: nil, isSensitive: true, encryptedContent: encrypted
        )
        XCTAssertEqual(PasteService.referencedFilePaths(sensitiveItem), [first.path, second.path])
    }

    func testMultiFileCopyWritesAllFileURLs() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let first = tempDir.appendingPathComponent("a.pdf")
        let second = tempDir.appendingPathComponent("b.txt")
        try Data("1".utf8).write(to: first)
        try Data("22".utf8).write(to: second)
        let joined = [first.path, second.path].joined(separator: "\n")
        let item = ClipboardItem(type: .file, title: "a.pdf 等 2 个文件", summary: joined, payloadPath: joined)

        withPasteboardLock {
            XCTAssertTrue(PasteService.shared.copyOnly(item))
            let urls = PasteboardAccess.general.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
            XCTAssertEqual(Set(urls.map(\.path)), Set([first.path, second.path]))

            // 部分失效：不写入（Finder ⌘V 不会只贴出子集），剪贴板现状保留
            let sentinel = "sentinel-\(UUID().uuidString)"
            XCTAssertTrue(PasteService.shared.copyText(sentinel))
            try? FileManager.default.removeItem(at: second)
            XCTAssertFalse(PasteService.shared.copyOnly(item))
            XCTAssertEqual(PasteboardAccess.general.string(forType: .string), sentinel)
        }
    }

    @MainActor
    func testClipboardMonitorCapturesAllFilesInMultiFileCopy() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let first = tempDir.appendingPathComponent("first.md")
        let second = tempDir.appendingPathComponent("second.txt")
        try Data("1".utf8).write(to: first)
        try Data("22".utf8).write(to: second)

        let monitor = ClipboardMonitor()
        var captured: ClipboardItem?
        monitor.onChange = { captured = $0 }
        monitor.start()
        defer { monitor.stop() }

        // 模拟 Finder 多选复制：多个文件 URL + 一个非文件 URL 混入
        try await withPasteboardLock {
            let pb = PasteboardAccess.general
            pb.clearContents()
            XCTAssertTrue(pb.writeObjects([
                first as NSURL,
                second as NSURL,
                URL(string: "https://example.com")! as NSURL
            ]))
            try await Task.sleep(nanoseconds: 1_200_000_000)
        }

        XCTAssertNotNil(captured, "monitor should capture multi-file copy")
        XCTAssertEqual(captured?.type, .file)
        XCTAssertEqual(captured?.payloadPath, [first.path, second.path].joined(separator: "\n"), "both files should be recorded, non-file URL skipped")
        XCTAssertEqual(captured?.summary, [first.path, second.path].joined(separator: "\n"))
        XCTAssertTrue(captured?.title.contains("first.md") == true)
        XCTAssertTrue(captured?.title.contains("2") == true, "title should mention file count: \(captured?.title ?? "")")
    }

    /// 关闭敏感保护后：敏感内容不进入历史，但系统剪贴板原样保留（可直接 ⌘V 粘贴）
    @MainActor
    func testSensitiveItemSkippedWhenProtectionDisabled() async throws {
        let defaults = makeIsolatedDefaults()
        defaults.set(false, forKey: "enableSensitiveProtection")

        let monitor = ClipboardMonitor(defaults: defaults)
        var captured: ClipboardItem?
        monitor.onChange = { captured = $0 }
        monitor.start()
        defer { monitor.stop() }

        let secret = "sk-ant-api03-abcdef1234567890abcdef"
        try await withPasteboardLock {
            let pb = PasteboardAccess.general
            pb.clearContents()
            XCTAssertTrue(pb.setString(secret, forType: .string))
            try await Task.sleep(nanoseconds: 1_200_000_000)

            XCTAssertNil(captured, "关闭敏感保护后敏感内容不得进入历史")
            XCTAssertEqual(pb.string(forType: .string), secret, "系统剪贴板必须原样保留，可直接粘贴")
        }
    }

    // MARK: - 图片默认标题命名（URL 文件名 / url-name / 尺寸回退）

    private static func tinyPNGData(pixel: UInt8 = 0) -> Data {
        let w = 4 + Int(pixel % 4)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        return rep.representation(using: .png, properties: [:])!
    }
    @MainActor
    func testClipboardMonitorImageTitleFromURLFilename() async throws {
        let monitor = ClipboardMonitor()
        var captured: ClipboardItem?
        monitor.onChange = { captured = $0 }
        monitor.start()
        defer {
            monitor.stop()
            PasteboardAccess.general.clearContents()
        }
        let exp1 = expectation(description: "captured filename title")
        monitor.onChange = { item in
            captured = item
            exp1.fulfill()
        }
        await withPasteboardLock {
            captured = nil
            let pb = PasteboardAccess.general
            pb.clearContents()
            XCTAssertTrue(pb.setData(Self.tinyPNGData(pixel: 0x98), forType: .png))
            XCTAssertTrue(pb.writeObjects([URL(string: "https://example.com/img/my%20photo.jpg")! as NSURL]))
            monitor.poll()
            await fulfillment(of: [exp1], timeout: 2.0)
        }
        XCTAssertEqual(captured?.type, .image)
        XCTAssertEqual(captured?.title, "my photo.jpg", "URL 文件名（百分号解码后）作为图片默认标题")
    }

    @MainActor
    func testClipboardMonitorCapturesAnchorTextAsURLTitle() async throws {
        let monitor = ClipboardMonitor()
        var captured: ClipboardItem?
        monitor.onChange = { captured = $0 }
        monitor.start()
        defer { monitor.stop() }

        try await withPasteboardLock {
            let pb = PasteboardAccess.general
            pb.clearContents()
            let htmlType = NSPasteboard.PasteboardType("public.html")
            pb.declareTypes([.string, htmlType], owner: nil)
            XCTAssertTrue(pb.setString("https://example.com/docs", forType: .string))
            XCTAssertTrue(pb.setData(
                Data(#"<a href="https://example.com/docs">示例页面标题</a>"#.utf8),
                forType: htmlType
            ))
            try await Task.sleep(nanoseconds: 1_200_000_000)
        }

        XCTAssertEqual(captured?.type, .url)
        XCTAssertEqual(captured?.title, "示例页面标题", "富文本锚文本作为捕获标题")
    }

    @MainActor
    func testClipboardMonitorPlainURLTitleEmpty() async throws {
        let monitor = ClipboardMonitor()
        var captured: ClipboardItem?
        monitor.onChange = { captured = $0 }
        monitor.start()
        defer { monitor.stop() }

        try await withPasteboardLock {
            let pb = PasteboardAccess.general
            pb.clearContents()
            pb.setString("https://example.com/plain", forType: .string)
            try await Task.sleep(nanoseconds: 1_200_000_000)
        }

        XCTAssertEqual(captured?.type, .url)
        XCTAssertEqual(captured?.title, "", "纯 URL 无富文本锚文本时置空")
    }

    @MainActor
    func testClipboardMonitorImageTitleFromURLName() async throws {
        let monitor = ClipboardMonitor()
        var captured: ClipboardItem?
        monitor.onChange = { captured = $0 }
        monitor.start()
        defer {
            monitor.stop()
            PasteboardAccess.general.clearContents()
        }
        let exp2 = expectation(description: "captured urlName title")
        monitor.onChange = { item in
            captured = item
            exp2.fulfill()
        }
        await withPasteboardLock {
            captured = nil
            let pb = PasteboardAccess.general
            pb.clearContents()
            let urlNameType = NSPasteboard.PasteboardType("public.url-name")
            pb.declareTypes([.png, urlNameType], owner: nil)
            XCTAssertTrue(pb.setData(Self.tinyPNGData(pixel: 0x99), forType: .png))
            XCTAssertTrue(pb.setString("链接里的图名", forType: urlNameType))
            monitor.poll()
            await fulfillment(of: [exp2], timeout: 2.0)
        }
        XCTAssertEqual(captured?.type, .image)
        XCTAssertEqual(captured?.title, "链接里的图名", "粘贴板自带的 url-name 优先于 URL 文件名")
    }

    @MainActor
    func testClipboardMonitorImageTitleFallsBackToDefault() async throws {
        let monitor = ClipboardMonitor()
        var captured: ClipboardItem?
        monitor.onChange = { captured = $0 }
        monitor.start()
        defer {
            monitor.stop()
            PasteboardAccess.general.clearContents()
        }

        try await withPasteboardLock {
            let pb = PasteboardAccess.general
            pb.clearContents()
            XCTAssertTrue(pb.setData(Self.tinyPNGData(pixel: 0x97), forType: .png))
            // 无扩展名 slug（"def"）不作为标题来源
            XCTAssertTrue(pb.writeObjects([URL(string: "https://example.com/abc/def")! as NSURL]))
            monitor.poll()
            try await Task.sleep(nanoseconds: 1_200_000_000)
        }

        XCTAssertEqual(captured?.type, .image)
        XCTAssertEqual(captured?.title, L10n.tr("item.type_image"), "无可用文件名时回退默认标题「图片」，格式走徽标")
        // 格式以行内徽标展示（取载荷扩展名；系统粘贴板会把 PNG 数据换出 TIFF，与具体编码解耦）
        if let captured {
            XCTAssertNotNil(ClipboardRowModel(item: captured).badge, "图片行必有格式徽标（PNG/TIFF）")
        } else {
            XCTFail("图片条目未捕获，徽标断言无从谈起")
        }
        XCTAssertTrue(captured?.fallbackDisplayTitle.contains("4") == true,
                      "展示回退携带尺寸信息: \(captured?.fallbackDisplayTitle ?? "")")
    }

    @MainActor
    func testClipboardMonitorRTFPayloadSaveFailureFallsBackToPlainText() async throws {
        final class ThrowingPayloadStore: PayloadStore {
            var directory: URL { FileManager.default.temporaryDirectory }
            func save(data: Data, preferredExtension: String) throws -> String {
                throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "disk full"])
            }
            func load(path: String) -> Data? { nil }
            func remove(path: String?) {}
            func isManaged(_ path: String) -> Bool { false }
        }

        let monitor = ClipboardMonitor(payloadStore: ThrowingPayloadStore())
        var captured: ClipboardItem?
        monitor.onChange = { captured = $0 }
        monitor.start()
        defer { monitor.stop() }

        let uniqueText = "RTFFallbackText-\(UUID().uuidString)"
        try await withPasteboardLock {
            let pb = PasteboardAccess.general
            pb.clearContents()
            let rtfData = "{\\rtf1\\ansi Hello}".data(using: .utf8)!
            pb.declareTypes([.string, .rtf], owner: nil)
            XCTAssertTrue(pb.setString(uniqueText, forType: .string))
            XCTAssertTrue(pb.setData(rtfData, forType: .rtf))
            try await Task.sleep(nanoseconds: 1_200_000_000)
        }

        XCTAssertNotNil(captured, "RTF 载荷保存失败时条目仍应降级存入")
        XCTAssertEqual(captured?.type, .text)
        XCTAssertEqual(captured?.summary, uniqueText)
        XCTAssertNil(captured?.payloadPath, "降级纯文本后 payloadPath 必须为 nil")
    }

    @MainActor
    func testClipboardMonitorIgnoresPasswordManagerTransientTypes() async throws {
        let monitor = ClipboardMonitor()
        var captured: ClipboardItem?
        monitor.onChange = { captured = $0 }
        monitor.start()
        defer { monitor.stop() }

        let onePasswordType = NSPasteboard.PasteboardType("com.agilebits.onepassword")
        let secretText = "SuperSecretPassword-\(UUID().uuidString)"

        try await withPasteboardLock {
            let pb = PasteboardAccess.general
            pb.clearContents()
            pb.declareTypes([.string, onePasswordType], owner: nil)
            XCTAssertTrue(pb.setString(secretText, forType: .string))
            XCTAssertTrue(pb.setData(Data(), forType: onePasswordType))
            try await Task.sleep(nanoseconds: 1_200_000_000)
        }

        XCTAssertNil(captured, "携带 1Password 敏感标记的剪贴板内容必须被忽略不捕获")
    }

    @MainActor
    func testClipboardMonitorSkipsSensitiveFileWhenProtectionDisabled() async throws {
        let defaults = makeIsolatedDefaults()
        defaults.set(false, forKey: "enableSensitiveProtection")

        let monitor = ClipboardMonitor(defaults: defaults)
        var captured: ClipboardItem?
        monitor.onChange = { captured = $0 }
        monitor.start()
        defer { monitor.stop() }

        let sensitiveFileName = "sk-proj-99988877766655544433221100_backup.txt"
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(sensitiveFileName)
        try "credentials".data(using: .utf8)?.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        try await withPasteboardLock {
            let pb = PasteboardAccess.general
            pb.clearContents()
            XCTAssertTrue(pb.writeObjects([tempFile as NSURL]))
            try await Task.sleep(nanoseconds: 1_200_000_000)
        }

        XCTAssertNil(captured, "敏感保护关闭时，含凭据的文件条目绝不进入历史")
    }


    func testClipboardItemCreation() {
        let item = ClipboardItem(type: .text, title: "Test", summary: "Sample text")
        XCTAssertEqual(item.type, .text)
        XCTAssertEqual(item.title, "Test")
        XCTAssertEqual(item.summary, "Sample text")
        XCTAssertFalse(item.isFavorite)
        XCTAssertNil(item.payloadPath)
    }

    func testFileStoreSaveAndLoad() throws {
        let testData = "Test file content".data(using: .utf8)!
        let path = try FileStore.shared.save(data: testData, preferredExtension: "txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        let loaded = FileStore.shared.load(path: path)
        XCTAssertEqual(loaded, testData)

        FileStore.shared.remove(path: path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testStoreBasicOperations() {
        let store = makeIsolatedStore()
        let id = UUID()
        let item = ClipboardItem(
            id: id,
            type: .text,
            title: "Unit Test Item",
            summary: "Unit test summary \(UUID().uuidString)",
            createdAt: .now,
            lastUsedAt: .now
        )

        store.save(item)
        XCTAssertTrue(store.items.contains(where: { $0.id == id }))

        store.delete(id)
        XCTAssertFalse(store.items.contains(where: { $0.id == id }))
    }

    func testHistoryStoreMaxItemsCap() {
        let store = makeIsolatedStore()
        let oldDate = Date(timeIntervalSinceNow: -40 * 86400) // 40 days ago
        let oldItem = ClipboardItem(
            id: UUID(),
            type: .text,
            title: "Old Item",
            summary: "Old summary \(UUID().uuidString)",
            createdAt: oldDate,
            lastUsedAt: oldDate
        )
        let favoriteOldItem = ClipboardItem(
            id: UUID(),
            type: .text,
            title: "Favorite Old Item",
            summary: "Favorite old summary \(UUID().uuidString)",
            createdAt: oldDate,
            lastUsedAt: oldDate,
            isFavorite: true
        )
        let freshItem = ClipboardItem(
            id: UUID(),
            type: .text,
            title: "Fresh Item",
            summary: "Fresh summary \(UUID().uuidString)"
        )

        store.save(oldItem)
        store.save(favoriteOldItem)
        store.save(freshItem)

        // 上限 1 条：非收藏 2 条超限 1 条，淘汰最久未使用的 oldItem
        store.pruneToMaxItems(1)

        XCTAssertFalse(store.items.contains(where: { $0.id == oldItem.id }), "超限时淘汰最久未使用的非收藏条目")
        XCTAssertTrue(store.items.contains(where: { $0.id == favoriteOldItem.id }), "收藏条目豁免条数上限裁剪")
        XCTAssertTrue(store.items.contains(where: { $0.id == freshItem.id }), "未超限的最新条目保留")
    }

    /// 「无限制」已退役：0/负数不再跳过裁剪，而是收敛到硬上限 1000 条
    func testHistoryStoreMaxItemsRetiredUnlimitedClampsToHardCap() {
        XCTAssertEqual(HistoryMaxItemsPolicy.clamp(0), 1000, "0（旧版无限制）收敛到硬上限")
        XCTAssertEqual(HistoryMaxItemsPolicy.clamp(-1), 1000, "负数同样收敛到硬上限")
        XCTAssertEqual(HistoryMaxItemsPolicy.clamp(5000), 1000, "超过硬上限的遗留档位被收敛")

        let store = makeIsolatedStore()
        let oldDate = Date(timeIntervalSinceNow: -40 * 86400)
        let items = (0..<5).map { i in
            ClipboardItem(type: .text, title: "Item \(i)", summary: "Summary \(i)-\(UUID().uuidString)",
                          createdAt: oldDate, lastUsedAt: oldDate)
        }
        items.forEach { store.save($0) }

        // 条数远小于硬上限：即使传 0（旧版无限制）也一条都不会被裁
        store.pruneToMaxItems(0)
        XCTAssertEqual(store.items.count, items.count, "5 条远低于硬上限，传 0 也无需裁剪")

        // 传入超过硬上限的档位时按硬上限处理，仍不需要裁剪
        store.pruneToMaxItems(5000)
        XCTAssertEqual(store.items.count, items.count, "超过硬上限的档位收敛后仍不裁剪")
    }

    func testHistoryStoreMaxItemsPruneResetsHasMoreSignal() {
        let store = makeIsolatedStore()
        // 先塞满一页多，让翻页信号为 true
        let total = InMemoryHistoryStore.pageSize + 20
        for i in 0..<total {
            store.save(ClipboardItem(
                id: UUID(),
                type: .text,
                title: "条目 \(i)",
                summary: "has-more needle \(i)"
            ))
        }
        XCTAssertTrue(store.hasMoreItems, "超过一页时应有翻页信号")

        // 裁到远小于一页：库内只剩 10 条，翻页信号必须跟着熄灭
        store.pruneToMaxItems(10)

        XCTAssertEqual(store.items.count, 10, "裁剪后镜像只保留上限内条目")
        XCTAssertFalse(store.hasMoreItems, "裁剪后必须重算翻页信号，否则会残留翻不动的「还有更多」")
        XCTAssertNil(store.items.first(where: { $0.title == "条目 0" }), "淘汰最久未使用的条目")
    }

    func testHistoryStoreClearHistory() {
        let store = makeIsolatedStore()
        let normalId = UUID()
        let favId = UUID()

        let normalItem = ClipboardItem(id: normalId, type: .text, title: "Normal", summary: "Normal \(UUID().uuidString)")
        let favItem = ClipboardItem(id: favId, type: .text, title: "Fav", summary: "Fav \(UUID().uuidString)", isFavorite: true)

        store.save(normalItem)
        store.save(favItem)

        store.clearHistory(keepFavorites: true)
        XCTAssertFalse(store.items.contains(where: { $0.id == normalId }))
        XCTAssertTrue(store.items.contains(where: { $0.id == favId }))
    }

    /// 回归：旧库 pinned 列应在打开时并入 favorite 后删除（置顶功能移除）


    func testHotKeyShortcutHelpers() {
        let def = HotKeyShortcut.defaultShortcut
        XCTAssertEqual(def.displayString, "⌘ ⇧ V")

        let display = HotKeyShortcut.displayString(keyCode: 9, modifierFlags: [.command, .shift])
        XCTAssertEqual(display, "⌘ ⇧ V")

        let spaceDisplay = HotKeyShortcut.displayString(keyCode: 49, modifierFlags: [.option])
        XCTAssertEqual(spaceDisplay, "⌥ Space")

        let carbonMods = HotKeyShortcut.carbonModifiers(from: [.command, .shift])
        XCTAssertEqual(carbonMods, UInt32(cmdKey | shiftKey))
    }

    @MainActor
    func testHotKeyManagerUpdateAndNotification() {
        let manager = HotKeyManager.shared
        let original = manager.currentShortcut

        var notificationFired = false
        let observer = NotificationCenter.default.addObserver(
            forName: .hotKeyDidChange,
            object: nil,
            queue: nil
        ) { _ in
            notificationFired = true
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            manager.update(shortcut: original)
        }

        let newShortcut = HotKeyShortcut(
            keyCode: UInt32(kVK_ANSI_C),
            carbonModifiers: UInt32(cmdKey | shiftKey),
            displayString: "⌘ ⇧ C"
        )
        let success = manager.update(shortcut: newShortcut)
        XCTAssertTrue(success, "有效快捷键更新应成功")
        XCTAssertTrue(notificationFired, "更新成功必须发出 .hotKeyDidChange 通知")
        XCTAssertEqual(manager.currentShortcut.displayString, "⌘ ⇧ C")
        XCTAssertEqual(UserDefaults.standard.string(forKey: UserDefaultsKey.hotkeyDisplay.rawValue), "⌘ ⇧ C")
    }

    @MainActor
    func testHotKeyManagerUpdateFailureRollsBack() {
        let manager = HotKeyManager.shared
        let original = manager.currentShortcut
        let originalDisplay = original.displayString

        manager.simulatedRegistrationFailure = true
        defer {
            manager.simulatedRegistrationFailure = false
            manager.update(shortcut: original)
        }

        // 模拟快捷键注册失败，manager 尝试更新应失败并回滚
        let conflictSuccess = manager.update(keyCode: UInt32(kVK_ANSI_X), carbonModifiers: UInt32(cmdKey | shiftKey), displayString: "⌘ ⇧ X")
        XCTAssertFalse(conflictSuccess, "注册失败必须返回 false")
        XCTAssertEqual(manager.currentShortcut.keyCode, original.keyCode)
        XCTAssertEqual(manager.currentShortcut.carbonModifiers, original.carbonModifiers)
        XCTAssertEqual(manager.currentShortcut.displayString, originalDisplay)
        XCTAssertEqual(UserDefaults.standard.string(forKey: UserDefaultsKey.hotkeyDisplay.rawValue), originalDisplay)
    }

    @MainActor
    func testExcludedAppsManager() {
        let suite = "test_nook_excluded_apps_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let manager = ExcludedAppsManager(defaults: defaults)

        XCTAssertTrue(manager.apps.isEmpty)
        XCTAssertFalse(manager.isExcluded(bundleIdentifier: "com.apple.Terminal"))

        // Add app
        manager.add(bundleIdentifier: "com.apple.Terminal", name: "Terminal")
        XCTAssertEqual(manager.apps.count, 1)
        XCTAssertTrue(manager.isExcluded(bundleIdentifier: "com.apple.Terminal"))
        // Case-insensitivity test
        XCTAssertTrue(manager.isExcluded(bundleIdentifier: "COM.APPLE.TERMINAL"))

        // Duplicate add is ignored
        manager.add(bundleIdentifier: "com.apple.Terminal", name: "Terminal")
        XCTAssertEqual(manager.apps.count, 1)

        // Add second app
        manager.add(bundleIdentifier: "com.agilebits.onepassword7", name: "1Password")
        XCTAssertEqual(manager.apps.count, 2)
        XCTAssertTrue(manager.isExcluded(bundleIdentifier: "com.agilebits.onepassword7"))

        // Remove app
        manager.remove(bundleIdentifier: "com.apple.Terminal")
        XCTAssertEqual(manager.apps.count, 1)
        XCTAssertFalse(manager.isExcluded(bundleIdentifier: "com.apple.Terminal"))

        // Reload from defaults to verify persistence
        let reloadedManager = ExcludedAppsManager(defaults: defaults)
        XCTAssertEqual(reloadedManager.apps.count, 1)
        XCTAssertTrue(reloadedManager.isExcluded(bundleIdentifier: "com.agilebits.onepassword7"))

        // Clear all
        manager.removeAll()
        XCTAssertTrue(manager.apps.isEmpty)
        defaults.removePersistentDomain(forName: suite)
    }



    @MainActor
    func testAppBrandingProductIcons() {
        let appIcon = AppBranding.appIcon
        XCTAssertGreaterThan(appIcon.size.width, 0, "App icon should have positive width")
        XCTAssertGreaterThan(appIcon.size.height, 0, "App icon should have positive height")

        let menuBarIcon = AppBranding.menuBarIcon
        XCTAssertEqual(menuBarIcon.size.width, 18, "Menu bar icon width should be 18pt")
        XCTAssertEqual(menuBarIcon.size.height, 18, "Menu bar icon height should be 18pt")

        let iconView = AppBranding.iconView(size: 30)
        let hosting = NSHostingController(rootView: iconView)
        XCTAssertNotNil(hosting.view)
        hosting.view.layoutSubtreeIfNeeded()
    }



    @MainActor
    func testDraggablePanelResizeDirections() {
        let panel = DraggablePanel(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        // 四角判断（包含左上角）
        XCTAssertEqual(panel.resizeDirection(at: NSPoint(x: 5, y: 595)), .topLeft)
        XCTAssertEqual(panel.resizeDirection(at: NSPoint(x: 795, y: 595)), .topRight)
        XCTAssertEqual(panel.resizeDirection(at: NSPoint(x: 5, y: 5)), .bottomLeft)
        XCTAssertEqual(panel.resizeDirection(at: NSPoint(x: 795, y: 5)), .bottomRight)

        // 四边判断
        XCTAssertEqual(panel.resizeDirection(at: NSPoint(x: 400, y: 596)), .top)
        XCTAssertEqual(panel.resizeDirection(at: NSPoint(x: 400, y: 4)), .bottom)
        XCTAssertEqual(panel.resizeDirection(at: NSPoint(x: 4, y: 300)), .left)
        XCTAssertEqual(panel.resizeDirection(at: NSPoint(x: 796, y: 300)), .right)

        // 中间区域不触发缩放
        XCTAssertNil(panel.resizeDirection(at: NSPoint(x: 400, y: 300)))
    }

    @MainActor
    func testDraggablePanelInteractiveAreasAndHeaderDrag() {
        let panel = DraggablePanel(
            contentRect: NSRect(x: 100, y: 100, width: 1000, height: 640),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        // 1. 顶格搜索框区域（左上角及左栏顶格铺满）：属于交互控件，用户点击输入搜索
        let searchTopLeftPoint = NSPoint(x: 40, y: 615)
        XCTAssertTrue(panel.isInteractiveArea(at: searchTopLeftPoint), "顶格搜索框属于交互区")
        XCTAssertFalse(panel.isHeaderDragArea(at: searchTopLeftPoint))

        // 2. 搜索框主体（左栏宽度内）：属于交互控件，避免点击输入被误判为拖拽
        let searchBodyPoint = NSPoint(x: 130, y: 615)
        XCTAssertTrue(panel.isInteractiveArea(at: searchBodyPoint), "搜索框主体属于交互区")
        XCTAssertFalse(panel.isHeaderDragArea(at: searchBodyPoint))

        // 3. 检索框主体及清除按钮区域（中间列顶部）：应属于交互控件，严禁作为窗口拖动拦截
        let searchInputPoint = NSPoint(x: 350, y: 605)
        XCTAssertTrue(panel.isInteractiveArea(at: searchInputPoint), "Search text field must be interactive")
        XCTAssertFalse(panel.isHeaderDragArea(at: searchInputPoint), "Search text field must not be intercepted as window drag")

        let searchClearButtonPoint = NSPoint(x: 580, y: 605)
        XCTAssertTrue(panel.isInteractiveArea(at: searchClearButtonPoint), "Search clear button must be interactive")
        XCTAssertFalse(panel.isHeaderDragArea(at: searchClearButtonPoint), "Search clear button must not be intercepted as window drag")

        // 4. 预览区右上角操作按钮（专注按钮等）：应属于交互控件
        let previewActionPoint = NSPoint(x: 960, y: 615)
        XCTAssertTrue(panel.isInteractiveArea(at: previewActionPoint))
        XCTAssertFalse(panel.isHeaderDragArea(at: previewActionPoint))

        // 5. 预览区标题及自定义编辑区域（铅笔修改按钮、双击编辑、文本框等）：应属于交互控件，严禁作为窗口拖动拦截
        let previewTitlePoint = NSPoint(x: 750, y: 615)
        XCTAssertTrue(panel.isInteractiveArea(at: previewTitlePoint), "Preview title and edit button must be interactive")
        XCTAssertFalse(panel.isHeaderDragArea(at: previewTitlePoint), "Preview title must not be intercepted as window drag")
    }

    @MainActor
    func testDraggablePanelResizeAndDragStateSafety() {
        let panel = DraggablePanel(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        // 验证初始状态下未处于缩放或拖拽状态
        XCTAssertFalse(panel.isResizing, "Panel initially should not be in resizing state")
        XCTAssertFalse(panel.isDragging, "Panel initially should not be in dragging state")
    }

    @MainActor
    func testPasteServiceCopyTextAndInternalMarker() throws {
        let text = "UniqueTestString-\(UUID().uuidString)"
        withPasteboardLock {
            let success = PasteService.shared.copyText(text)
            XCTAssertTrue(success)
            let pasteboard = PasteboardAccess.general
            XCTAssertEqual(pasteboard.string(forType: .string), text)
            XCTAssertTrue(pasteboard.types?.contains(PasteService.internalMarker) == true)
            XCTAssertEqual(pasteboard.changeCount, PasteService.lastInternalChangeCount)
        }
    }

    @MainActor
    func testPasteDoesNotTriggerClipboardMonitorOrAddDuplicate() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let syncEngine = ICloudDriveSyncEngine(customBaseURL: tempDir.appendingPathComponent("icloud"), defaults: makeIsolatedDefaults())
        let store = makeIsolatedStore(syncEngine: syncEngine)
        let item = ClipboardItem(type: .text, title: "Test Item", summary: "Test Summary \(UUID().uuidString)")
        store.save(item)
        let initialCount = store.items.count

        let monitor = ClipboardMonitor()
        var onChangeCount = 0
        monitor.onChange = { newItem in
            onChangeCount += 1
            store.save(newItem)
        }
        monitor.start()
        defer { monitor.stop() }

        // Create an active window with an NSTextView to receive the paste
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        textView.string = "SelectedTextToReplace"
        textView.selectAll(nil)
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(textView)

        // Trigger paste（持剪贴板锁：防止并行 worker 同时写系统剪贴板干扰监控断言）
        try await withPasteboardLock {
            _ = PasteService.shared.paste(item)
            try await Task.sleep(nanoseconds: 1_200_000_000)
            window.orderOut(nil)

            XCTAssertEqual(onChangeCount, 0, "PasteService.paste should NOT trigger ClipboardMonitor.onChange")
            XCTAssertEqual(store.items.count, initialCount, "Store item count should not increase on paste")
        }
    }

    func testFileStoreThumbnailCacheSelectiveEviction() throws {
        let testImage1 = NSImage(size: NSSize(width: 200, height: 200))
        testImage1.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 200, height: 200))
        testImage1.unlockFocus()
        let tiffData1 = testImage1.tiffRepresentation!

        let testImage2 = NSImage(size: NSSize(width: 200, height: 200))
        testImage2.lockFocus()
        NSColor.blue.drawSwatch(in: NSRect(x: 0, y: 0, width: 200, height: 200))
        testImage2.unlockFocus()
        let tiffData2 = testImage2.tiffRepresentation!

        let path1 = try FileStore.shared.save(data: tiffData1, preferredExtension: "tiff")
        let path2 = try FileStore.shared.save(data: tiffData2, preferredExtension: "tiff")
        defer {
            try? FileManager.default.removeItem(atPath: path1)
            try? FileManager.default.removeItem(atPath: path2)
        }

        // 预热两个文件的缩略图缓存
        _ = FileStore.shared.thumbnail(for: path1, maxPixelSize: 80)
        _ = FileStore.shared.thumbnail(for: path2, maxPixelSize: 80)

        // 删除 path1，不应影响 path2 的缩略图生成与系统稳定性
        FileStore.shared.remove(path: path1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path2))
        XCTAssertNotNil(FileStore.shared.thumbnail(for: path2, maxPixelSize: 80))
    }


    func testV2SQLiteOCRAndMetadataPersistence() {
        let store = makeIsolatedStore()
        let id = UUID()
        let item = ClipboardItem(
            id: id,
            type: .image,
            title: "图片测试",
            summary: "像素大小",
            ocrText: "Vision OCR 离线提取成功",
            metadata: ClipboardMetadata(language: "swift")
        )

        store.save(item)
        let loadedItems = store.items
        let found = loadedItems.first(where: { $0.id == id })
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.ocrText, "Vision OCR 离线提取成功")
        XCTAssertEqual(found?.metadata.language, "swift")

        store.updateOCRText("更新后的 OCR 文字", for: id)
        let afterOCR = store.items.first(where: { $0.id == id })
        XCTAssertEqual(afterOCR?.ocrText, "更新后的 OCR 文字")
        store.delete(id)
    }
    func testV2OCREngineWithGeneratedImage() async {
        // 创建带有文本绘制的 NSImage
        let size = NSSize(width: 200, height: 60)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()

        let text = "HELLO NOOK"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 24),
            .foregroundColor: NSColor.black
        ]
        (text as NSString).draw(at: NSPoint(x: 10, y: 15), withAttributes: attrs)
        image.unlockFocus()

        // 运行 Vision OCR
        let recognized = await OCREngine.shared.recognizeText(from: image)
        XCTAssertNotNil(recognized)
        XCTAssertTrue(recognized?.contains("HELLO") == true || recognized?.contains("NOOK") == true)
    }

    func testOCREnginePreservesMultiLineAndHorizontalLayout() async {
        let size = NSSize(width: 300, height: 120)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 20),
            .foregroundColor: NSColor.black
        ]
        // 第一行绘制在偏上方（y = 70），第二行绘制在偏下方（y = 20）
        ("LINE ONE" as NSString).draw(at: NSPoint(x: 20, y: 70), withAttributes: attrs)
        ("LINE TWO" as NSString).draw(at: NSPoint(x: 20, y: 20), withAttributes: attrs)
        image.unlockFocus()

        let recognized = await OCREngine.shared.recognizeText(from: image)
        XCTAssertNotNil(recognized)
        guard let text = recognized else { return }
        // 验证第一行排在第二行之前
        let range1 = text.range(of: "ONE")
        let range2 = text.range(of: "TWO")
        XCTAssertNotNil(range1)
        XCTAssertNotNil(range2)
        if let r1 = range1, let r2 = range2 {
            XCTAssertTrue(r1.lowerBound < r2.lowerBound, "第一行必须排在第二行前面")
        }
    }

    func testOCREnginePrewarmIsIdempotentAndSafe() {
        // 多次调用 prewarm 必须是线程安全且幂等的
        OCREngine.shared.prewarm()
        OCREngine.shared.prewarm()
    }
    @MainActor
    func testManualOCRTriggersRecognitionAndSaves() async throws {
        let store = makeIsolatedStore()

        // 创建一张临时测试图片并存入文件系统
        let tempDir = NSTemporaryDirectory()
        let imagePath = (tempDir as NSString).appendingPathComponent("ocr_test_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(atPath: imagePath) }

        let size = NSSize(width: 200, height: 60)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let text = "NOOK OCR TEST"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 22),
            .foregroundColor: NSColor.black
        ]
        (text as NSString).draw(at: NSPoint(x: 10, y: 15), withAttributes: attrs)
        image.unlockFocus()
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("无法生成测试图片")
            return
        }
        try pngData.write(to: URL(fileURLWithPath: imagePath))

        let item = ClipboardItem(
            type: .image,
            title: "截图测试",
            summary: "ocr_test.png",
            payloadPath: imagePath
        )
        store.save(item)

        // 初始保存后，由于移除了自动 OCR，条目中 ocrText 必须为 nil
        let savedItem = store.item(withID: item.id)
        XCTAssertNil(savedItem?.ocrText, "新保存图片不应自动执行 OCR")

        // 手动触发 OCR 识别，并验证按需加载阶段日志回调顺序
        var observedStages: [OCRProgressStage] = []
        let result = await store.performManualOCRWithProgress(for: item.id) { stage in
            if observedStages.last != stage {
                observedStages.append(stage)
            }
        }
        XCTAssertNotNil(result, "手动 OCR 应当识别到文字")
        XCTAssertTrue(result?.contains("NOOK") == true || result?.contains("TEST") == true)
        XCTAssertTrue(observedStages.contains(.loadingEngine), "应上报加载 Apple Vision 引擎阶段")
        XCTAssertTrue(observedStages.contains(.recognizingText), "应上报识别文字阶段")
        XCTAssertTrue(observedStages.contains(.reclaimingMemory), "应上报释放缓存与回收内存阶段")

        // 验证内存与数据库已更新
        let afterOCR = store.item(withID: item.id)
        XCTAssertEqual(afterOCR?.ocrText, result)
        let rustItem = store.rustStore.page(limit: 10, offset: 0).first(where: { $0.id == item.id })
        XCTAssertEqual(rustItem?.ocrText, result)
    }

    @MainActor
    func testIdleMemoryReclamationClearsPreviewAndHighlightCaches() async {
        let sampleCode = "func hello() { print(\"world\") }"
        _ = await CodeHighlightService.outcome(for: sampleCode, forcedLanguage: "swift", dark: false)
        XCTAssertNotNil(
            CodeHighlightService.cachedOutcome(for: sampleCode, forcedLanguage: "swift", dark: false),
            "前置：代码高亮结果已进入缓存"
        )

        let store = makeIsolatedStore()
        let controller = QuickPopoverController(
            historyStore: store,
            targetApplicationProvider: { nil },
            clipboardWriter: PasteService.shared
        )
        controller.showFromMenuBar()
        XCTAssertNotNil(controller.panel, "呼出面板后应持有 NSPanel 实例")
        controller.close(restoreFocus: false)
        controller.reclaimIdleMemoryNow()

        XCTAssertNil(controller.panel, "闲置回收后应释放隐藏的 NSPanel 与 SwiftUI 宿主视图树")
        XCTAssertNil(
            CodeHighlightService.cachedOutcome(for: sampleCode, forcedLanguage: "swift", dark: false),
            "面板闲置回收后应清空代码高亮富文本与引擎缓存"
        )

        // 再次呼出面板应能无缝重建
        controller.showFromMenuBar()
        XCTAssertEqual(controller.panel?.isVisible, true, "闲置回收后再次呼出应能正常重建并显示面板")
        controller.close(restoreFocus: false)
    }

    @MainActor
    func testManualOCROnSolidColorImageMustCompleteWithNil() async throws {
        let store = makeIsolatedStore()

        // 纯色无文字图片：Vision 识别不到任何文字（用户报告的卡死场景）
        let size = NSSize(width: 200, height: 60)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("无法生成测试图片")
            return
        }
        let imagePath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ocr_blank_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(atPath: imagePath) }
        try pngData.write(to: URL(fileURLWithPath: imagePath))

        let item = ClipboardItem(
            type: .image,
            title: "纯色图",
            summary: "ocr_blank.png",
            payloadPath: imagePath
        )
        store.save(item)

        // 契约：识别不到文字时 completion 必须回调一次并回传 nil，不得永久挂起
        let completed = expectation(description: "手动 OCR completion 必定回调")
        store.performManualOCR(for: item.id) { text in
            XCTAssertNil(text, "纯色图片识别结果应为 nil")
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 30)

        // 识别失败不得污染内存与数据库
        XCTAssertNil(store.item(withID: item.id)?.ocrText)
    }

    @MainActor
    func testHistoryOCRServiceUpdateTextRejectsWhitespaceAndMasksCredentials() {
        let store = makeIsolatedStore()
        let service = HistoryOCRService(rustStore: store.rustStore)
        let item = ClipboardItem(type: .image, title: "Key Image", summary: "Key")
        store.save(item)

        // 1. 空白文本更新返回 nil，不写库
        XCTAssertNil(service.updateOCRText("   \n\t ", for: item.id), "空白 OCR 文本更新必须返回 nil")

        // 2. 识别内容含密钥凭据：必须自动脱敏后再入库
        let rawOCR = "Found secret key: sk-proj-99988877766655544433221100 in screenshot"
        let stored = service.updateOCRText(rawOCR, for: item.id)
        XCTAssertNotNil(stored)
        XCTAssertFalse(stored!.contains("99988877766655544433221100"), "OCR 回写内容严禁包含明文敏感凭据")
        XCTAssertTrue(stored!.contains("...") || stored!.contains("••••"), "回写内容必须包含脱敏掩码")

        let fromDB = store.rustStore.item(id: item.id)
        XCTAssertEqual(fromDB?.ocrText, stored, "SQLite 库内 OCR 文本必须为已脱敏文本")
    }

    func testColorDetector() {
        // Hex 6 位
        let hex = parseColorHex(text: "#FF5722")
        XCTAssertEqual(hex, "#FF5722")

        // Hex 3 位
        let shortHex = parseColorHex(text: "#0F8")
        XCTAssertNotNil(shortHex)

        // RGB 格式
        let rgb = parseColorHex(text: "rgb(33, 150, 243)")
        XCTAssertEqual(rgb, "#2196F3")

        // 非颜色文本返回 nil
        let invalid = parseColorHex(text: "Hello World")
        XCTAssertNil(invalid)
    }

    @MainActor
    func testHistoryStoreExportAndImport() throws {
        let store = makeIsolatedStore()
        let testId1 = UUID()
        let testId2 = UUID()

        let item1 = ClipboardItem(
            id: testId1,
            type: .text,
            title: "JSON Sample",
            summary: "{\"key\": \"value\"}",
            isFavorite: true,
            sourceAppBundleId: "com.apple.dt.Xcode",
            sourceAppName: "Xcode"
        )
        let item2 = ClipboardItem(
            id: testId2,
            type: .url,
            title: "Google",
            summary: "https://www.google.com",
            isFavorite: false,
            sourceAppBundleId: "com.apple.Safari",
            sourceAppName: "Safari"
        )

        store.save(item1)
        store.save(item2)

        // 1. Export to JSON
        let jsonData = try store.exportToJSON()
        XCTAssertFalse(jsonData.isEmpty)

        // 2. Export to Markdown（Rust exchange，三档敏感模式）
        let md = try store.exportToMarkdown()
        XCTAssertTrue(md.contains("# NookClip Clipboard History Export"))
        XCTAssertTrue(md.contains("JSON Sample"))
        // 3. Import deduplication test
        let freshStore = makeIsolatedStore()
        let initialCount = freshStore.totalCount
        let imported = try freshStore.importFromJSON(jsonData)
        XCTAssertEqual(imported, 2)
        XCTAssertEqual(freshStore.totalCount, initialCount + 2)

        // Importing again should import 0 because items already exist
        let reimported = try freshStore.importFromJSON(jsonData)
        XCTAssertEqual(reimported, 0)
        XCTAssertEqual(freshStore.totalCount, initialCount + 2)
    }

    @MainActor
    func testExportToMarkdownRichElements() throws {
        let store = makeIsolatedStore()

        // 1. 收藏项且多次复制 (copyCount = 3)
        let favItem = ClipboardItem(
            type: .text,
            title: "Fav Note",
            summary: "Important note content",
            isFavorite: true
        )
        store.save(favItem)
        store.save(favItem)
        store.save(favItem)

        // 2. 图片项且包含 OCR 提取文本
        let imgItem = ClipboardItem(
            type: .image,
            title: "Invoice Screenshot",
            summary: "Invoice.png",
            ocrText: "Extracted Invoice Total: $500\nDate: 2026-10-11"
        )
        store.save(imgItem)

        let md = try store.exportToMarkdown()

        XCTAssertTrue(md.contains("Fav Note"), "条目标题应输出在 Markdown 中")
        XCTAssertTrue(md.contains("Important note content"), "条目内容应输出在 Markdown 中")
        XCTAssertTrue(md.contains("**Favorite**: yes"), "收藏条目应带 Favorite 标记")
    }

    /// 列表查询只载入 summary 前缀后，Markdown 导出必须仍输出全文
    @MainActor
    func testExportToMarkdownKeepsFullTextBeyondPrefixLimit() throws {
        let store = makeIsolatedStore()
        let longText = String(repeating: "导出全文", count: 150) + "结尾标记"
        let item = ClipboardItem(type: .text, title: "", summary: longText)
        store.save(item)

        let md = try store.exportToMarkdown()
        XCTAssertTrue(md.contains(longText), "导出内容必须是全文，不得截断到前缀")
    }

    @MainActor
    func testExportToJSONSensitiveModes() throws {
        let store = makeIsolatedStore()
        let secret = "sk-proj-export-mode-secret-token"
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
            summary: "Normal public content"
        )
        store.save(sensitiveItem)
        store.save(normalItem)

        // 1. 模式 .exclude：完全排除敏感条目
        let excludeData = try store.exportToJSON(mode: .exclude)
        let excludeStr = String(data: excludeData, encoding: .utf8)!
        XCTAssertTrue(excludeStr.contains("Normal public content"))
        XCTAssertFalse(excludeStr.contains(secret))
        XCTAssertFalse(excludeStr.contains(sensitiveItem.id.uuidString), "exclude 模式下敏感条目完全不应出现在导出列表中")

        // 2. 模式 .masked：默认掩码导出（绝不包含明文密钥）
        let maskedData = try store.exportToJSON(mode: .masked)
        let maskedStr = String(data: maskedData, encoding: .utf8)!
        XCTAssertTrue(maskedStr.contains("Normal public content"))
        XCTAssertFalse(maskedStr.contains(secret), "masked 模式严禁导出明文凭据")
        XCTAssertTrue(maskedStr.contains(sensitiveItem.id.uuidString), "masked 模式应包含脱敏后的条目")

        // 3. 模式 .plaintext：明文解密导出
        let plainData = try store.exportToJSON(mode: .plaintext)
        let plainStr = String(data: plainData, encoding: .utf8)!
        XCTAssertTrue(plainStr.contains(secret), "plaintext 模式应解密输出明文凭据")
    }

    /// FR-005/FR-006：Markdown 导出同样遵循三档敏感模式
    @MainActor
    func testExportToMarkdownSensitiveModes() throws {
        let store = makeIsolatedStore()
        let secret = "sk-proj-md-export-secret-token"
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
            summary: "Normal public content"
        )
        store.save(sensitiveItem)
        store.save(normalItem)

        // .exclude：敏感条目完全不出现在 Markdown
        let excludeMd = try store.exportToMarkdown(mode: .exclude)
        XCTAssertTrue(excludeMd.contains("Normal public content"))
        XCTAssertFalse(excludeMd.contains(sensitiveItem.id.uuidString), "exclude 模式下敏感条目不应出现")

        // .masked：掩码呈现，绝无明文凭据
        let maskedMd = try store.exportToMarkdown(mode: .masked)
        XCTAssertTrue(maskedMd.contains("Normal public content"))
        XCTAssertFalse(maskedMd.contains(secret), "masked 模式严禁导出明文凭据")
        XCTAssertTrue(maskedMd.contains("••••••••"), "masked 模式应输出掩码字符")

        // .plaintext：明文解密导出
        let plainMd = try store.exportToMarkdown(mode: .plaintext)
        XCTAssertTrue(plainMd.contains(secret), "plaintext 模式应解密输出明文凭据")
    }

    func testRustHistoryStoreSourceAppPersistence() {
        let store = makeIsolatedStore()
        let id = UUID()
        let item = ClipboardItem(
            id: id,
            type: .text,
            title: "Source App Test Item",
            summary: "Source App Test Summary \(UUID().uuidString)",
            createdAt: .now,
            lastUsedAt: .now,
            sourceAppBundleId: "com.google.Chrome",
            sourceAppName: "Google Chrome"
        )

        store.save(item)
        let found = store.items.first(where: { $0.id == id })
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.sourceAppBundleId, "com.google.Chrome")
        XCTAssertEqual(found?.sourceAppName, "Google Chrome")

        store.delete(id)
    }

    @MainActor
    func testRenameWritesTitleDirectly() {
        let store = makeIsolatedStore()
        let id = UUID()
        let originalSummary = "func calculateTax() -> Double { return 0.08 }"
        let item = ClipboardItem(
            id: id,
            type: .text,
            title: "",
            summary: originalSummary,
            createdAt: .now,
            lastUsedAt: .now
        )
        store.save(item)

        // 1. 改名直写 title
        store.updateTitle("税率计算函数 (生产)", for: id)
        let modified = store.items.first(where: { $0.id == id })
        XCTAssertEqual(modified?.title, "税率计算函数 (生产)")

        // 2. 验证持久化
        let fromDb = store.rustStore.page(limit: 10, offset: 0).first(where: { $0.id == id })
        XCTAssertEqual(fromDb?.title, "税率计算函数 (生产)")
        store.updateTitle("   ", for: id)
        let restored = store.items.first(where: { $0.id == id })
        XCTAssertEqual(restored?.title, "")
        XCTAssertEqual(restored?.fallbackDisplayTitle, originalSummary, "展示回退 = 内容预览")

        store.delete(id)
    }

    @MainActor
    func testCustomTitlePreservedOnReCopy() {
        let store = makeIsolatedStore()
        let id = UUID()
        let uniqueSummary = "API_KEY_PRESERVE_TEST_\(UUID().uuidString)"
        let item1 = ClipboardItem(
            id: id,
            type: .text,
            title: "默认前缀",
            summary: uniqueSummary,
            createdAt: .now,
            lastUsedAt: .now
        )
        store.save(item1)

        // 用户自定义了标题
        store.updateTitle("★ 我的专属秘钥", for: id)
        XCTAssertEqual(store.items.first(where: { $0.id == id })?.title, "★ 我的专属秘钥")

        // 模拟用户再次复制了相同的文本内容
        let item2 = ClipboardItem(
            id: UUID(),
            type: .text,
            title: "默认重新生成的前缀",
            summary: uniqueSummary,
            createdAt: .now,
            lastUsedAt: .now
        )
        store.save(item2)

        // 验证重新复制后，保留了用户自定义的标题
        let existing = store.items.first(where: { $0.summary == uniqueSummary })
        XCTAssertEqual(existing?.title, "★ 我的专属秘钥")

        if let existingId = existing?.id {
            store.delete(existingId)
        }
    }

    @MainActor
    func testCustomTitleSearch() {
        let store = makeIsolatedStore()
        let item = ClipboardItem(
            type: .text,
            title: "财务报表2026年Q3",
            summary: "Revenue: 100M, Cost: 40M"
        )
        store.save(item)
        XCTAssertEqual(store.rustStore.search(query: "财务报表").count, 1)
        XCTAssertEqual(store.rustStore.search(query: "Q3").count, 1)
        XCTAssertEqual(store.rustStore.search(query: "nonexistent").count, 0)
    }



    /// 软删除按撤销宽限清除：过期条目被彻底清除并返回 id 供写墓碑
    @MainActor
    func testTrashPurgeByGraceWindow() {
        let store = makeIsolatedStore()
        var oldTrashed = ClipboardItem(type: .text, title: "old", summary: "purge-old-\(UUID().uuidString)")
        oldTrashed.deletedAt = Date().addingTimeInterval(-TrashPurgeWindow.grace * 2)
        var freshTrashed = ClipboardItem(type: .text, title: "fresh", summary: "purge-fresh-\(UUID().uuidString)")
        freshTrashed.deletedAt = Date().addingTimeInterval(-5)
        store.save(oldTrashed)
        store.save(freshTrashed)
        store.delete(oldTrashed.id)
        store.delete(freshTrashed.id)

        let purged = store.purgeExpiredTrash(now: Date())
        XCTAssertEqual(purged.map(\.id), [oldTrashed.id], "只有超过撤销宽限的软删除条目被清除")
        XCTAssertEqual(store.trashItems.map(\.id), [freshTrashed.id])
    }


    // MARK: - UI 完善与增强专属测试 (UI Refinement & Polish Tests)




    @MainActor
    func testSettingsViewStorageBadgesAndDesignSystemTokens() {
        let store = makeIsolatedStore()
        store.clearHistory()
        let item1 = ClipboardItem(type: .text, title: "Item 1", summary: "Item 1")
        let item2 = ClipboardItem(type: .text, title: "Item 2", summary: "Item 2")
        store.save(item1)
        store.save(item2)
        if let first = store.items.first {
            store.toggleFavorite(first.id)
        }

        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.items.filter { $0.isFavorite }.count, 1)
        let settingsView = SettingsView(historyStore: store)
        let hostingController = NSHostingController(rootView: settingsView)
        hostingController.view.frame = NSRect(x: 0, y: 0, width: 600, height: 600)
        hostingController.view.layoutSubtreeIfNeeded()
        XCTAssertNotNil(hostingController.view)
    }

    @MainActor
    func testDarkModeTokensAndSettingsTabs() {
        // 验证暗黑与浅色模式动态颜色工厂在 darkAqua 与 aqua 下表现正确
        let dynamicTestColor = NookClip.dynamicColor(
            light: NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 1),
            dark: NSColor(calibratedRed: 0, green: 0, blue: 1, alpha: 1)
        )
        XCTAssertNotNil(dynamicTestColor)

        // 验证核心 NookClip 令牌存在并可正常求值
        _ = NookClip.bgPanel
        _ = NookClip.bgContent
        _ = NookClip.bgPreview
        _ = NookClip.bgPopover
        _ = NookClip.textPrimary
        _ = NookClip.textSecondary
        _ = NookClip.textTertiary
        _ = NookClip.accent
        _ = NookClip.colorSensitive
        _ = NookClip.colorFavorite
        _ = NookClip.separator
        _ = NookClip.codeKeyword

        // 验证系统强调色动态派生令牌求值正常
        _ = NookClip.bgRowSelected
        _ = NookClip.borderRowSelected
        _ = NookClip.bgRowSelectedSubtle
        _ = NookClip.borderRowSelectedSubtle
        _ = NookClip.bgRowSelectedStrong
        _ = NookClip.bgChipSelected
        _ = NookClip.focusRing
        _ = NookClip.dynamicAccentColor(lightAlpha: 0.12, darkAlpha: 0.24)

        // 验证 SettingsTab 6 个分类齐备（通用打头，功能组按生命周期排，
        // 隐私收在功能组末尾，外观收尾）
        XCTAssertEqual(SettingsTab.allCases.count, 6)
        let expectedTabs: [SettingsTab] = [.general, .appearance, .capture, .history, .paste, .privacy]
        XCTAssertEqual(SettingsTab.allCases, expectedTabs)
        for tab in SettingsTab.allCases {
            XCTAssertFalse(tab.title.isEmpty)
            XCTAssertFalse(tab.icon.isEmpty)
        }

        // 验证外观模式通知定义
        XCTAssertEqual(Notification.Name.appearanceDidChange.rawValue, "NookClip.appearanceDidChange")
        // 验证系统颜色变更通知
        XCTAssertEqual(NSColor.systemColorsDidChangeNotification.rawValue, "NSSystemColorsDidChangeNotification")
    }


    @MainActor
    func testPasteRecordDeduplicationAndNoExtraRecord() throws {
        let store = makeIsolatedStore()
        store.clearHistory()

        let item1 = ClipboardItem(type: .text, title: "Item 1", summary: "Duplicated Content")
        let item2 = ClipboardItem(type: .text, title: "Item 1 Copy", summary: "Duplicated Content")
        
        // 模拟外部或旧版产生重复项
        store.rustStore.save(item1)
        store.rustStore.save(item2)
        XCTAssertEqual(store.rustStore.page(limit: 10, offset: 0).count, 1, "存储层应该自动去重相同内容记录")
        store.save(item1)
        store.save(item2)
        XCTAssertEqual(store.items.count, 1, "InMemory store save 应该自动去重相同内容记录")

        // 模拟粘贴并调用 markUsed（持剪贴板锁防止并行 worker 干扰）
        withPasteboardLock {
            PasteService.shared.copyOnly(store.items[0])
            store.markUsed(store.items[0].id)

            XCTAssertEqual(store.items.count, 1, "粘贴与 markUsed 不应产生多余的复制记录")
            XCTAssertEqual(PasteService.lastPastedSummary, "Duplicated Content")
            XCTAssertNotNil(PasteService.lastPastedTime)
        }
    }

    @MainActor
    func testLocalizationManagerAndSwitching() {
        let manager = LocalizationManager.shared
        let originalLanguage = manager.selectedLanguage
        defer {
            manager.selectedLanguage = originalLanguage
        }

        // 1. English verification
        manager.selectedLanguage = .en
        XCTAssertEqual(manager.effectiveLanguageCode, "en")
        XCTAssertEqual(L10n.tr("menu.open"), "Open NookClip")
        XCTAssertEqual(L10n.tr("settings.tab.general"), "General")
        XCTAssertEqual(L10n.tr("sidebar.all"), "All")
        XCTAssertEqual(L10n.tr("time.just_now"), "Just now")
        XCTAssertEqual(L10n.tr("clipboard.items_count", 5), "5 items")
        XCTAssertEqual(L10n.tr("sidebar.switch_category"), "Switch Category")
        XCTAssertEqual(L10n.tr("toast.copied_to_clipboard"), "Copied to clipboard")
        XCTAssertEqual(L10n.tr("action.clear"), "Clear");
        // 2. Simplified Chinese verification
        manager.selectedLanguage = .zhHans
        XCTAssertEqual(manager.effectiveLanguageCode, "zh-Hans")
        XCTAssertEqual(L10n.tr("menu.open"), "打开 NookClip")
        XCTAssertEqual(L10n.tr("settings.tab.general"), "通用")
        XCTAssertEqual(L10n.tr("sidebar.all"), "全部")
        XCTAssertEqual(L10n.tr("time.just_now"), "刚刚")
        XCTAssertEqual(L10n.tr("clipboard.items_count", 5), "5 条")
        XCTAssertEqual(L10n.tr("sidebar.switch_category"), "切换分类")
        XCTAssertEqual(L10n.tr("toast.copied_to_clipboard"), "已复制到剪贴板")
        XCTAssertEqual(L10n.tr("action.clear"), "清空");

        // 3. Traditional Chinese verification
        manager.selectedLanguage = .zhHant
        XCTAssertEqual(manager.effectiveLanguageCode, "zh-Hant")
        XCTAssertEqual(L10n.tr("menu.open"), "開啟 NookClip")
        XCTAssertEqual(L10n.tr("settings.tab.general"), "一般")
        XCTAssertEqual(L10n.tr("sidebar.all"), "全部")
        XCTAssertEqual(L10n.tr("time.just_now"), "剛剛")
        XCTAssertEqual(L10n.tr("clipboard.items_count", 5), "5 項")
        XCTAssertEqual(L10n.tr("sidebar.switch_category"), "切換分類")
        XCTAssertEqual(L10n.tr("toast.copied_to_clipboard"), "已複製到剪貼簿")
        XCTAssertEqual(L10n.tr("action.clear"), "清除");
        // 4. Relative time generation
        let past = Date().addingTimeInterval(-120)
        let relative = L10n.relativeTime(for: past)
        XCTAssertFalse(relative.isEmpty)
    }

    // MARK: - RowDedup 显示层去重（title/summary 重复单行化）

    func testRowDedupShortTextExactDuplicate() {
        XCTAssertTrue(RowDedup.isRedundant(kind: .text, title: "买牛奶和面包", summary: "买牛奶和面包"))
        let displayed = RowDedup.displayTitle(kind: .text, title: "买牛奶和面包", summary: "买牛奶和面包")
        XCTAssertEqual(displayed, "买牛奶和面包")
        XCTAssertFalse(displayed.hasSuffix("…"))
    }

    func testRowDedupLongTextTruncatedTitle() {
        let long = String(repeating: "字", count: 60)
        let title = String(long.prefix(48))
        XCTAssertTrue(RowDedup.isRedundant(kind: .text, title: title, summary: long))
        XCTAssertEqual(RowDedup.displayTitle(kind: .text, title: title, summary: long), title + "…")
    }

    func testRowDedupMultilineText() {
        XCTAssertTrue(RowDedup.isRedundant(kind: .text, title: "line1", summary: "line1\nline2"))
        XCTAssertEqual(RowDedup.displayTitle(kind: .text, title: "line1", summary: "line1\nline2"), "line1…")
    }

    func testRowDedupURLAlwaysShowsSubtitle() {
        // 链接副行恒展示完整 URL（scheme + 域名强调色 + 路径），不因 title=host/path 单行化
        XCTAssertFalse(RowDedup.isRedundant(kind: .url, title: "example.com/a", summary: "https://example.com/a"))
        XCTAssertEqual(RowDedup.displayTitle(kind: .url, title: "example.com/a", summary: "https://example.com/a"), "example.com/a")
        // 抓到网页 <title> 后同样保持双行
        XCTAssertFalse(RowDedup.isRedundant(kind: .url, title: "示例页面", summary: "https://example.com/a"))
    }

    func testRowDedupFilePaths() {
        // 文件行副行含大小 + 完整路径（独立信息），不再因 title=文件名单行化
        XCTAssertFalse(RowDedup.isRedundant(kind: .file, title: "report.pdf", summary: "/Users/x/report.pdf"))
        XCTAssertFalse(RowDedup.isRedundant(kind: .file, title: "report.pdf", summary: "report.pdf"))
        XCTAssertFalse(RowDedup.isRedundant(kind: .file, title: "report.pdf", summary: "/Users/x/other.txt"))
    }

    func testFileStoreRemoveOnlyDeletesManagedPaths() {
        // 数据安全：文件类条目 payloadPath 指向用户原始文件，remove 不得越界删除
        let outside = NSTemporaryDirectory() + "nook-unmanaged-\(UUID().uuidString).md"
        try? "test".data(using: .utf8)?.write(to: URL(fileURLWithPath: outside))
        FileStore.shared.remove(path: outside)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside))
        try? FileManager.default.removeItem(atPath: outside)

        // 管理目录内的载荷正常删除
        let managed = FileStore.shared.directory.appendingPathComponent("\(UUID().uuidString).txt").path
        try? "test".data(using: .utf8)?.write(to: URL(fileURLWithPath: managed))
        FileStore.shared.remove(path: managed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: managed))
    }

    func testFileStoreSweepOrphansRespectsGracePeriodAndReferences() throws {
        let fileStore = FileStore.shared
        // 1. 文件 A：有数据库引用，不论修改时间如何，必须保留
        let pathA = try fileStore.save(data: "payload data A".data(using: .utf8)!, preferredExtension: "txt")
        defer { fileStore.remove(path: pathA) }

        // 2. 文件 B：无引用且修改时间超过 24 小时宽限期，必须被删除
        let pathB = try fileStore.save(data: "payload data B".data(using: .utf8)!, preferredExtension: "txt")
        let oldDate = Date().addingTimeInterval(-48 * 3600)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: pathB)
        defer { fileStore.remove(path: pathB) }

        // 3. 文件 C：无引用但修改时间在宽限期内（刚创建），必须保留（防止并发写入中途被误删）
        let pathC = try fileStore.save(data: "payload data C".data(using: .utf8)!, preferredExtension: "txt")
        defer { fileStore.remove(path: pathC) }

        let referenced: Set<String> = [URL(fileURLWithPath: pathA).standardizedFileURL.path]
        let removedCount = fileStore.sweepOrphans(referencedPaths: referenced, olderThan: 24 * 3600)

        XCTAssertGreaterThanOrEqual(removedCount, 1, "超期无主孤儿文件必须被清理")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pathA), "有引用的文件 A 必须完好保留")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pathB), "超期无主的文件 B 必须已被删除")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pathC), "宽限期内的新建文件 C 必须完好保留")
    }

    func testRowDedupNonTextKindsNeverRedundant() {
        XCTAssertFalse(RowDedup.isRedundant(kind: .code, title: "parseConfig", summary: "func parseConfig() {\n    return 1\n}"))
        XCTAssertFalse(RowDedup.isRedundant(kind: .image, title: "图片 100×50", summary: "100×50 像素 · 3 KB #ab12cd34"))
        XCTAssertFalse(RowDedup.isRedundant(kind: .json, title: "{", summary: "{\"a\": 1}"))
        XCTAssertFalse(RowDedup.isRedundant(kind: .color, title: "#3B82F6", summary: "59, 130, 246"))
        XCTAssertFalse(RowDedup.isRedundant(kind: .sensitive, title: "sk-•••", summary: "sk-••••7890"))
    }

    func testRowDedupEmptyTitleNeverRedundant() {
        XCTAssertFalse(RowDedup.isRedundant(kind: .text, title: "", summary: "任意内容"))
        XCTAssertEqual(RowDedup.displayTitle(kind: .text, title: "", summary: "任意内容"), "")
    }

    func testRowDedupNormalize() {
        XCTAssertEqual(RowDedup.normalize("  a \n b  c \n d "), "a")
        XCTAssertEqual(RowDedup.normalize("a\t\tb   c"), "a b c")
        XCTAssertEqual(RowDedup.normalize(""), "")
    }

    func testRowDedupSensitiveMaskedDuplicate() {
        // 生成侧 title = maskedText = summary → 密文逐字重复，单行化
        let masked = "sk-proj-••••••••7890"
        XCTAssertTrue(RowDedup.isRedundant(kind: .sensitive, title: masked, summary: masked))
        XCTAssertEqual(RowDedup.displayTitle(kind: .sensitive, title: masked, summary: masked), masked)
        // 历史兜底 title（「敏感凭证」本地化标签）与密文不同 → 保持双行
        XCTAssertFalse(RowDedup.isRedundant(kind: .sensitive, title: "敏感凭证", summary: masked))
    }

    @MainActor
    func testExportIncludesItemsBeyondFirstPage() throws {
        let store = makeIsolatedStore()
        store.clearHistory(keepFavorites: false)
        for index in 0..<InMemoryHistoryStore.pageSize + 25 {
            store.save(ClipboardItem(
                type: .text,
                title: "export-\(index)",
                summary: "export-summary-\(index)"
            ))
        }

        let data = try store.exportToJSON()
        // Rust 备份契约（BackupExportRoot，serde snake_case）
        // 与 importFromJSON 的 Rust 分支互为往返
        struct ExportRoot: Decodable {
            let version: Int
            let total_count: Int
            struct Item: Decodable {
                let id: String
                let title: String
                let summary: String
            }
            let items: [Item]
        }
        let exported = try JSONDecoder().decode(ExportRoot.self, from: data)
        XCTAssertEqual(exported.version, 1)
        XCTAssertEqual(exported.total_count, InMemoryHistoryStore.pageSize + 25)
        XCTAssertEqual(exported.items.count, InMemoryHistoryStore.pageSize + 25)
        XCTAssertTrue(exported.items.contains { $0.title == "export-0" })
        XCTAssertTrue(exported.items.contains { $0.title == "export-\(InMemoryHistoryStore.pageSize + 24)" })
    }


    func testQRCodeGenerator() {
        let image = QRCodeGenerator.image(for: "https://example.com/a")
        XCTAssertNotNil(image)
        XCTAssertGreaterThanOrEqual(image!.size.width, 100)
        // 空白文本不生成
        XCTAssertNil(QRCodeGenerator.image(for: "   \n "))
    }

    @MainActor
    func testStickyGroupFollowsTopVisibleRowDuringMouseScroll() {
        let todayItem = ClipboardItem(type: .text, title: "today", summary: "today", lastUsedAt: Date())
        let yesterdayDate = Date().addingTimeInterval(-86_400)
        let yesterdayItem = ClipboardItem(type: .text, title: "yesterday", summary: "yesterday", lastUsedAt: yesterdayDate)
        let lastWeekDate = Date().addingTimeInterval(-8 * 86_400)
        let lastWeekItem = ClipboardItem(type: .text, title: "last-week", summary: "last-week", lastUsedAt: lastWeekDate)

        let groups: [TimeGroup<ClipboardItem>] = [
            TimeGroup(id: "today", title: "今天", items: [todayItem]),
            TimeGroup(id: "yesterday", title: "昨天", items: [yesterdayItem]),
            TimeGroup(id: "last-week", title: "上周", items: [lastWeekItem])
        ]
        let bounds: (top: CGFloat, bottom: CGFloat) = (top: 102, bottom: 602)

        // 场景 1：鼠标滚轮向下滚动，「今天」已被滚出视口并被 LazyVStack 回收卸载（不在 frames 中），
        // 视口顶部第一条可见行是「昨天」，但 selectedID 仍停留在「今天」首行
        let scrolledFramesUnloaded: [String: CGRect] = [
            yesterdayItem.id.uuidString: CGRect(x: 0, y: 110, width: 310, height: 50),
            lastWeekItem.id.uuidString: CGRect(x: 0, y: 160, width: 310, height: 50)
        ]
        let resolvedWhenUnloaded = MainViewFilterState.resolveStickyGroupID(
            groups: groups,
            frames: scrolledFramesUnloaded,
            bounds: bounds,
            selectedID: todayItem.id
        )
        XCTAssertEqual(
            resolvedWhenUnloaded,
            "yesterday",
            "当选中行滚出视口被 LazyVStack 卸载后，时间导航必须跟随当前视口顶部可见行（yesterday），不能死锁在 today"
        )

        // 场景 2：用户选中了列表靠下的「上周」行（仍在屏幕底部 y=520 可见），
        // 随后向上滚动鼠标使「昨天」位于视口顶部（y=105）
        let framesWithSelectedAtBottom: [String: CGRect] = [
            yesterdayItem.id.uuidString: CGRect(x: 0, y: 105, width: 310, height: 50),
            lastWeekItem.id.uuidString: CGRect(x: 0, y: 520, width: 310, height: 50)
        ]
        let resolvedWithSelectedAtBottom = MainViewFilterState.resolveStickyGroupID(
            groups: groups,
            frames: framesWithSelectedAtBottom,
            bounds: bounds,
            selectedID: lastWeekItem.id
        )
        XCTAssertEqual(
            resolvedWithSelectedAtBottom,
            "yesterday",
            "滚动时时间导航应反映视口顶部可见分组（yesterday），而非视口底部的选中行分组"
        )

        // 场景 3：初始尚未上报任何可见行坐标时，回退到 selectedID 所属分组
        let resolvedInitialFallback = MainViewFilterState.resolveStickyGroupID(
            groups: groups,
            frames: [:],
            bounds: bounds,
            selectedID: yesterdayItem.id
        )
        XCTAssertEqual(resolvedInitialFallback, "yesterday")
    }
}

