import AppKit
import XCTest
@testable import NookClip

// MARK: - 局域网扫码免安装双向快传（spec 014 · US1）核心逻辑测试
//
// 覆盖三个纯函数层（LanHTTPParser / LanQuickDropRouter / 页面生成）与网络层的
// 生命周期（端口分配、一次性令牌、超时自动释放）。不触碰 NSPasteboard。

final class LanQuickDropServerTests: XCTestCase {

    private let token = "abcdefghijklmnopqrstuvwxyz123456"

    private func makePayloadText(_ text: String = "hello from mac") -> LanSharedPayload {
        LanSharedPayload(itemId: "id-1", title: "测试文本", kind: .text, text: text)
    }

    // MARK: - Parser

    func testParseGETWithoutBody() {
        let raw = "GET /s/\(token)/payload?x=1&y=2 HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let result = LanHTTPParser.parse(Data(raw.utf8), maxBodyBytes: 1024)
        guard case .complete(let request) = result else {
            return XCTFail("应解析完成，实际：\(result)")
        }
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/s/\(token)/payload")
        XCTAssertEqual(request.query["x"], "1")
        XCTAssertEqual(request.query["y"], "2")
        XCTAssertEqual(request.headers["host"], "localhost")
        XCTAssertTrue(request.body.isEmpty)
    }

    func testParseReturnsNeedMoreForPartialBody() {
        let raw = "POST /s/\(token)/send HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc"
        let result = LanHTTPParser.parse(Data(raw.utf8), maxBodyBytes: 1024)
        XCTAssertEqual(result, .needMore)
    }

    func testParseTooLargeWhenContentLengthExceedsLimit() {
        let raw = "POST /s/\(token)/send HTTP/1.1\r\nContent-Length: 5000\r\n\r\n"
        let result = LanHTTPParser.parse(Data(raw.utf8), maxBodyBytes: 1024)
        XCTAssertEqual(result, .tooLarge)
    }

    func testParseCompleteWithBody() {
        let raw = "POST /s/\(token)/send HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello"
        let result = LanHTTPParser.parse(Data(raw.utf8), maxBodyBytes: 1024)
        guard case .complete(let request) = result else {
            return XCTFail("应解析完成，实际：\(result)")
        }
        XCTAssertEqual(request.body, Data("hello".utf8))
    }

    // MARK: - Router 令牌校验

    func testRouterRejectsWrongToken() {
        let router = LanQuickDropRouter(token: token, payload: makePayloadText())
        let request = LanHTTPRequest(method: "GET", path: "/s/deadbeefdeadbeefdeadbeefdeadbeef")
        guard case .respond(let response) = router.route(request) else {
            return XCTFail("应直接返回响应")
        }
        XCTAssertEqual(response.status, 403)
    }

    func testRouterRejectsMalformedTokenPath() {
        let router = LanQuickDropRouter(token: token, payload: makePayloadText())
        guard case .respond(let response) = router.route(LanHTTPRequest(method: "GET", path: "/s")) else {
            return XCTFail("应直接返回响应")
        }
        XCTAssertEqual(response.status, 403)
    }

    // MARK: - Router GET

    func testRouterServesHTMLPage() {
        let router = LanQuickDropRouter(token: token, payload: makePayloadText())
        guard case .respond(let response) = router.route(LanHTTPRequest(method: "GET", path: "/s/\(token)")) else {
            return XCTFail("应返回 HTML")
        }
        XCTAssertEqual(response.status, 200)
        let html = String(decoding: response.body, as: UTF8.self)
        XCTAssertTrue(html.contains("NookClip"))
        XCTAssertTrue(html.contains(token), "页面脚本必须带上令牌以拼出 API 路径")
    }

    func testRouterServesTextPayload() {
        let router = LanQuickDropRouter(token: token, payload: makePayloadText("明文内容"))
        guard case .respond(let response) = router.route(LanHTTPRequest(method: "GET", path: "/s/\(token)/payload")) else {
            return XCTFail("应返回 payload")
        }
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "明文内容")
        XCTAssertEqual(response.headers["Content-Type"], "text/plain; charset=utf-8")
    }

    func testRouterServesImagePayloadInline() {
        let binary = Data([0x89, 0x50, 0x4E, 0x47])
        let payload = LanSharedPayload(kind: .image, binary: binary, mimeType: "image/png", fileName: "shot.png")
        let router = LanQuickDropRouter(token: token, payload: payload)
        guard case .respond(let response) = router.route(LanHTTPRequest(method: "GET", path: "/s/\(token)/payload")) else {
            return XCTFail("应返回 payload")
        }
        XCTAssertEqual(response.body, binary)
        XCTAssertEqual(response.headers["Content-Type"], "image/png")
        XCTAssertTrue(response.headers["Content-Disposition"]?.hasPrefix("inline") ?? false)
    }

    // MARK: - Router POST 上行

    func testRouterAcceptsJSONText() {
        let router = LanQuickDropRouter(token: token, payload: makePayloadText())
        let body = Data(#"{"type":"text","content":"来自手机"}"#.utf8)
        let request = LanHTTPRequest(
            method: "POST",
            path: "/s/\(token)/send",
            headers: ["content-type": "application/json"],
            body: body
        )
        guard case .accept(let drop, let response) = router.route(request) else {
            return XCTFail("应接受回传")
        }
        XCTAssertEqual(drop.kind, .text)
        XCTAssertEqual(drop.text, "来自手机")
        XCTAssertEqual(response.status, 200)
    }

    func testRouterRejectsJSONWithoutContent() {
        let router = LanQuickDropRouter(token: token, payload: makePayloadText())
        let request = LanHTTPRequest(
            method: "POST",
            path: "/s/\(token)/send",
            headers: ["content-type": "application/json"],
            body: Data(#"{"type":"text"}"#.utf8)
        )
        guard case .respond(let response) = router.route(request) else {
            return XCTFail("应直接返回响应")
        }
        XCTAssertEqual(response.status, 400)
    }

    func testRouterAcceptsBinaryImage() {
        let router = LanQuickDropRouter(token: token, payload: makePayloadText())
        let imageBytes = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let request = LanHTTPRequest(
            method: "POST",
            path: "/s/\(token)/send",
            headers: ["content-type": "image/jpeg", "x-nook-filename": "photo.jpg"],
            body: imageBytes
        )
        guard case .accept(let drop, _) = router.route(request) else {
            return XCTFail("应接受回传")
        }
        XCTAssertEqual(drop.kind, .image)
        XCTAssertEqual(drop.data, imageBytes)
        XCTAssertEqual(drop.fileName, "photo.jpg")
    }

    func testRouterRejectsOversizeUpload() {
        let router = LanQuickDropRouter(token: token, payload: makePayloadText(), maxUploadBytes: 4)
        let request = LanHTTPRequest(
            method: "POST",
            path: "/s/\(token)/send",
            headers: ["content-type": "application/octet-stream"],
            body: Data(repeating: 0x41, count: 8)
        )
        guard case .respond(let response) = router.route(request) else {
            return XCTFail("应直接返回响应")
        }
        XCTAssertEqual(response.status, 413)
    }

    func testRouterUnknownSubpathIs404() {
        let router = LanQuickDropRouter(token: token, payload: makePayloadText())
        guard case .respond(let response) = router.route(LanHTTPRequest(method: "GET", path: "/s/\(token)/nope")) else {
            return XCTFail("应返回 404")
        }
        XCTAssertEqual(response.status, 404)
    }

    // MARK: - 令牌与网卡

    func testRandomTokenIs32HexChars() {
        let generated = LanQuickDropServer.randomToken()
        XCTAssertEqual(generated.count, 32)
        XCTAssertTrue(generated.allSatisfy { $0.isHexDigit })
        XCTAssertNotEqual(generated, LanQuickDropServer.randomToken())
    }

    func testPrivateIPv4Detection() {
        XCTAssertTrue(LanQuickDropServer.isPrivateIPv4("192.168.1.5"))
        XCTAssertTrue(LanQuickDropServer.isPrivateIPv4("10.0.0.2"))
        XCTAssertTrue(LanQuickDropServer.isPrivateIPv4("172.16.3.9"))
        XCTAssertTrue(LanQuickDropServer.isPrivateIPv4("172.31.255.1"))
        XCTAssertFalse(LanQuickDropServer.isPrivateIPv4("172.32.0.1"))
        XCTAssertFalse(LanQuickDropServer.isPrivateIPv4("8.8.8.8"))
        XCTAssertFalse(LanQuickDropServer.isPrivateIPv4("not-an-ip"))
    }

    func testCandidateAddressesAreAllPrivate() {
        for address in LanQuickDropServer.candidateIPv4Addresses() {
            XCTAssertTrue(LanQuickDropServer.isPrivateIPv4(address), "候选网卡地址必须是 RFC1918 私有地址：\(address)")
        }
    }

    // MARK: - 来源图标

    func testPhoneDropSourceUsesPhoneIcon() {
        let model = SourceAppModel.resolve(name: "手机快传", bundleID: SourceAppModel.phoneDropBundleID)
        XCTAssertEqual(model.symbol, NookClipIcon.Action.phoneDrop, "手机回传内容的来源图标必须是手机符号")
        XCTAssertNil(model.bundleID, "不应尝试解析成本地真实 App 图标")
    }

    func testUnknownAppStillFallsBack() {
        let model = SourceAppModel.resolve(name: "某个不存在的应用", bundleID: nil)
        XCTAssertNotEqual(model.symbol, NookClipIcon.Action.phoneDrop)
    }

    // MARK: - 服务生命周期

    func testServerStartAllocatesPortAndStops() async throws {
        let server = LanQuickDropServer()
        let port = try await server.start(payload: makePayloadText(), ttlSeconds: 30)
        XCTAssertGreaterThan(port, 0)
        XCTAssertTrue(server.isRunning)
        XCTAssertEqual(server.currentToken.count, 32)
        server.stop()
        // stop 是异步投递到串行队列，等待其生效
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(server.isRunning)
    }

    func testServerEndToEndOverRealHTTP() async throws {
        let server = LanQuickDropServer()
        let received = expectation(description: "服务端收到上行文本")
        let port = try await server.start(
            payload: makePayloadText("端到端内容"),
            ttlSeconds: 30,
            onReceive: { drop in if drop.kind == .text { received.fulfill() } },
            onExpire: nil
        )
        defer { server.stop() }
        let token = server.currentToken
        let base = URL(string: "http://127.0.0.1:\(port)/s/\(token)")!

        let (pageData, pageResp) = try await URLSession.shared.data(from: base)
        XCTAssertEqual((pageResp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: pageData, as: UTF8.self).contains("NookClip"))

        var request = URLRequest(url: base.appendingPathComponent("send"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"type":"text","content":"hello phone"}"#.utf8)
        let (_, postResp) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((postResp as? HTTPURLResponse)?.statusCode, 200)
        await fulfillment(of: [received], timeout: 5)
    }

    func testServerExpiresAndReleasesPort() async throws {
        let server = LanQuickDropServer()
        let expired = expectation(description: "onExpire 被调用")
        _ = try await server.start(
            payload: makePayloadText(),
            ttlSeconds: 1,
            onReceive: nil,
            onExpire: { expired.fulfill() }
        )
        XCTAssertTrue(server.isRunning)
        await fulfillment(of: [expired], timeout: 4)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(server.isRunning, "超时后必须立即释放监听端口")
    }

    // MARK: - 审查回归测试（图片格式归一化、去重摘要、敏感明文保护、扩展名识别）

    @MainActor
    func testNormalizePhoneDropImageDataConvertsJPEGToPNGAndProducesDistinctSummaries() throws {
        func makeJPEG(color: NSColor, size: NSSize) -> Data {
            let image = NSImage(size: size)
            image.lockFocus()
            color.setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
            image.unlockFocus()
            let tiff = image.tiffRepresentation!
            let rep = NSBitmapImageRep(data: tiff)!
            return rep.representation(using: .jpeg, properties: [:])!
        }

        let jpeg1 = makeJPEG(color: .systemRed, size: NSSize(width: 16, height: 12))
        let jpeg2 = makeJPEG(color: .systemBlue, size: NSSize(width: 24, height: 18))

        let norm1 = MainView.normalizePhoneDropImageData(jpeg1, mimeType: "image/jpeg")
        let norm2 = MainView.normalizePhoneDropImageData(jpeg2, mimeType: "image/jpeg")

        let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        XCTAssertEqual(norm1.ext, "png")
        XCTAssertEqual(norm2.ext, "png")
        XCTAssertEqual(Array(norm1.data.prefix(8)), pngMagic, "JPEG 回传图片必须归一化为 PNG 字节，避免按 TIFF 写入剪贴板损坏")
        XCTAssertEqual(Array(norm2.data.prefix(8)), pngMagic)

        let path1 = try FileStore.shared.save(data: norm1.data, preferredExtension: norm1.ext)
        let path2 = try FileStore.shared.save(data: norm2.data, preferredExtension: norm2.ext)
        defer {
            FileStore.shared.remove(path: path1)
            FileStore.shared.remove(path: path2)
        }

        let summary1 = MainView.phoneDropImageSummary(forPath: path1, dataCount: norm1.data.count)
        let summary2 = MainView.phoneDropImageSummary(forPath: path2, dataCount: norm2.data.count)
        XCTAssertNotEqual(summary1, summary2, "不同图片必须生成不同 summary，防止命中数据库去重导致第二张图片静默丢失")
        XCTAssertTrue(summary1.contains("×"), "图片摘要应包含像素尺寸：\(summary1)")
    }

    @MainActor
    func testMakeLanPayloadForSensitiveItemNeverSendsMaskedBullets() {
        let entity = ClipboardItem(
            type: .text,
            title: "API Key",
            summary: "••••••••••••",
            isSensitive: true
        )
        let row = ClipboardRowModel(item: entity)

        let unrevealedPayload = PreviewPane.makeLanPayload(
            for: row,
            entityItem: entity,
            revealedPlainText: nil,
            previewData: .live
        )
        XCTAssertNil(unrevealedPayload, "未解密的敏感条目绝不能把 •••••••• 掩码圆点当成快传载荷发往手机")

        let revealedPayload = PreviewPane.makeLanPayload(
            for: row,
            entityItem: entity,
            revealedPlainText: "sk-live-real-secret-12345",
            previewData: .live
        )
        XCTAssertEqual(revealedPayload?.text, "sk-live-real-secret-12345", "已解密的敏感条目应下发真实明文")
    }

    @MainActor
    func testMakeLanPayloadPrefersFullEntityTextOverTruncatedRowSummary() {
        let fullLongText = String(repeating: "长文段落内容-", count: 100)
        let entity = ClipboardItem(type: .text, title: "长文", summary: fullLongText)
        let truncatedEntity = ClipboardItem(id: entity.id, type: .text, title: "长文", summary: String(fullLongText.prefix(50)))
        let row = ClipboardRowModel(item: truncatedEntity)

        let payload = PreviewPane.makeLanPayload(
            for: row,
            entityItem: entity,
            revealedPlainText: nil,
            previewData: .live
        )
        XCTAssertEqual(payload?.text, fullLongText, "快传文本应优先取完整实体全文而非列表截断摘要")
    }

    func testRouterClassifiesHEICWithOctetStreamMimeAsImage() {
        let router = LanQuickDropRouter(token: token, payload: makePayloadText())
        let request = LanHTTPRequest(
            method: "POST",
            path: "/s/\(token)/send",
            headers: ["content-type": "application/octet-stream", "x-nook-filename": "IMG_2026.HEIC"],
            body: Data([0x00, 0x00, 0x00, 0x18])
        )
        guard case .accept(let drop, _) = router.route(request) else {
            return XCTFail("应接受回传")
        }
        XCTAssertEqual(drop.kind, .image, "手机浏览器未上报 image/* MIME 时应按图片扩展名识别为 .image")
    }

    func testMobilePageAdaptsToAcceptLanguageAcrossCountries() {
        XCTAssertEqual(LanQuickDropPage.resolveLocale(acceptLanguage: "en-US,en;q=0.9"), .en)
        XCTAssertEqual(LanQuickDropPage.resolveLocale(acceptLanguage: "ja-JP,ja;q=0.9,en;q=0.8"), .en)
        XCTAssertEqual(LanQuickDropPage.resolveLocale(acceptLanguage: "zh-TW,zh;q=0.9"), .zhHant)
        XCTAssertEqual(LanQuickDropPage.resolveLocale(acceptLanguage: "zh-HK,zh-Hant;q=0.9"), .zhHant)
        XCTAssertEqual(LanQuickDropPage.resolveLocale(acceptLanguage: "zh-CN,zh-Hans;q=0.9"), .zhHans)

        let router = LanQuickDropRouter(token: token, payload: makePayloadText())
        let enRequest = LanHTTPRequest(
            method: "GET",
            path: "/s/\(token)",
            headers: ["accept-language": "en-US,en;q=0.9"]
        )
        guard case .respond(let enResponse) = router.route(enRequest) else {
            return XCTFail("应返回 HTML")
        }
        let enHTML = String(decoding: enResponse.body, as: UTF8.self)
        XCTAssertTrue(enHTML.contains(#"<html lang="en">"#))

        let twRequest = LanHTTPRequest(
            method: "GET",
            path: "/s/\(token)",
            headers: ["accept-language": "zh-TW,zh;q=0.9"]
        )
        guard case .respond(let twResponse) = router.route(twRequest) else {
            return XCTFail("应返回 HTML")
        }
        let twHTML = String(decoding: twResponse.body, as: UTF8.self)
        XCTAssertTrue(twHTML.contains(#"<html lang="zh-Hant">"#))
    }

    func testPayloadResponseSanitizesCRLFAndQuotesInFileName() {
        let response = LanHTTPResponse.payload(
            Data([0x01, 0x02]),
            mimeType: "application/octet-stream",
            fileName: "report\"\r\nX-Injected: yes.pdf",
            inline: false
        )
        let disposition = response.headers["Content-Disposition"] ?? ""
        XCTAssertFalse(disposition.contains("\r"), "Content-Disposition 不得包含回车符")
        XCTAssertFalse(disposition.contains("\n"), "Content-Disposition 不得包含换行符")
        XCTAssertTrue(disposition.contains("filename=\"reportX-Injected: yes.pdf\""))
    }
}
