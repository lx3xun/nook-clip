import Combine
import Foundation
import Network

// MARK: - 局域网扫码免安装双向快传（LanQuickDrop · specs/014 US1）
//
// 设计要点：
// 1. 仅在用户主动打开「手机快传」面板期间启动临时 HTTP 服务，关闭弹窗/超时立即 cancel，
//    平时 0 端口监听（隐私红线）。
// 2. 一次性随机令牌（16 字节 hex）作为路由前缀 `/s/<token>`，任何不匹配的请求一律 403。
// 3. 物理局域网 IPv4 智能优选：过滤 VPN / 虚拟网卡，优先 en0/en1 的 RFC1918 私有地址。
// 4. 零外部 CDN 依赖的内联移动端页面，支持下发（查看/复制/下载）与上行（文字/图片/文件回传）。
// 5. HTTP 解析 / 路由 / 响应是纯函数（LanHTTPParser / LanQuickDropRouter），与网络层解耦，
//    便于 `swift test` 直接做一次性令牌校验、GET/POST 双向收发与超时关闭的单元测试。

// MARK: - 共享载荷快照

/// 当前电脑分享给手机的内容快照（文本 / 图片 / 文件）。
public struct LanSharedPayload: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case text
        case image
        case file
    }

    public let itemId: String
    public let title: String
    public let kind: Kind
    /// 文本正文（kind == .text 时）
    public let text: String?
    /// 图片 / 文件原始字节（kind == .image / .file 时）
    public let binary: Data?
    public let mimeType: String
    public let fileName: String

    public init(
        itemId: String = "",
        title: String = "",
        kind: Kind,
        text: String? = nil,
        binary: Data? = nil,
        mimeType: String = "text/plain; charset=utf-8",
        fileName: String = ""
    ) {
        self.itemId = itemId
        self.title = title
        self.kind = kind
        self.text = text
        self.binary = binary
        self.mimeType = mimeType
        self.fileName = fileName
    }

    /// 文本优先，其次二进制——用于计算回传体积与下载体
    public var byteCount: Int {
        if let binary { return binary.count }
        return text?.utf8.count ?? 0
    }
}

// MARK: - 手机回传内容

/// 手机端发送回电脑的内容（已在路由器侧完成解析与体积校验）。
public struct LanIncomingDrop: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case text
        case image
        case file
    }

    public let kind: Kind
    public let text: String?
    public let data: Data?
    public let fileName: String
    public let mimeType: String

    public init(kind: Kind, text: String? = nil, data: Data? = nil, fileName: String = "", mimeType: String = "application/octet-stream") {
        self.kind = kind
        self.text = text
        self.data = data
        self.fileName = fileName
        self.mimeType = mimeType
    }
}

// MARK: - HTTP 请求 / 响应（纯数据，可单测）

public struct LanHTTPRequest: Equatable {
    public let method: String
    /// 不含 query 的路径，例如 `/s/<token>/send`
    public let path: String
    public let query: [String: String]
    /// header 键已统一小写
    public let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }
}

public struct LanHTTPResponse: Equatable {
    public let status: Int
    public let reason: String
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, reason: String, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.reason = reason
        self.headers = headers
        self.body = body
    }

    /// 序列化为可直接通过 TCP 发送的 HTTP/1.1 报文。
    /// 恒带 Content-Length 与 `Connection: close`：移动端浏览器可正常处理短连接。
    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        var allHeaders = headers
        allHeaders["Content-Length"] = String(body.count)
        allHeaders["Connection"] = "close"
        allHeaders["Cache-Control"] = "no-store"
        allHeaders["X-Content-Type-Options"] = "nosniff"
        for (key, value) in allHeaders.sorted(by: { $0.key < $1.key }) {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    // MARK: 常用响应构造

    public static func html(_ html: String) -> LanHTTPResponse {
        LanHTTPResponse(
            status: 200,
            reason: "OK",
            headers: ["Content-Type": "text/html; charset=utf-8"],
            body: Data(html.utf8)
        )
    }

    public static func payload(_ data: Data, mimeType: String, fileName: String, inline: Bool) -> LanHTTPResponse {
        var disposition = inline ? "inline" : "attachment"
        if !fileName.isEmpty {
            let sanitizedName = fileName
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\n", with: "")
            let encoded = sanitizedName.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "download"
            disposition += "; filename=\"\(sanitizedName)\"; filename*=UTF-8''\(encoded)"
        }
        return LanHTTPResponse(
            status: 200,
            reason: "OK",
            headers: [
                "Content-Type": mimeType,
                "Content-Disposition": disposition,
            ],
            body: data
        )
    }

    public static func json(_ object: [String: Any]) -> LanHTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return LanHTTPResponse(status: 200, reason: "OK", headers: ["Content-Type": "application/json; charset=utf-8"], body: data)
    }

    public static func forbidden() -> LanHTTPResponse {
        LanHTTPResponse(status: 403, reason: "Forbidden", headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data("forbidden".utf8))
    }

    public static func notFound() -> LanHTTPResponse {
        LanHTTPResponse(status: 404, reason: "Not Found", headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data("not found".utf8))
    }

    public static func badRequest(_ message: String = "bad request") -> LanHTTPResponse {
        LanHTTPResponse(status: 400, reason: "Bad Request", headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(message.utf8))
    }

    public static func tooLarge() -> LanHTTPResponse {
        LanHTTPResponse(status: 413, reason: "Payload Too Large", headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data("payload too large".utf8))
    }

    public static func noContent() -> LanHTTPResponse {
        LanHTTPResponse(status: 204, reason: "No Content")
    }
}

// MARK: - HTTP 解析器（纯函数）

public enum LanHTTPParseResult: Equatable {
    /// 报文尚未收全，继续 receive
    case needMore
    /// 报文结构非法或 header 超限
    case malformed
    /// 声明体积超过上限（无需继续缓冲，直接回 413）
    case tooLarge
    /// 解析完成
    case complete(LanHTTPRequest)
}

public enum LanHTTPParser {
    public static let headerTerminator = Data("\r\n\r\n".utf8)
    /// header 体积上限，防止恶意超长 header 撑爆内存
    public static let maxHeaderBytes = 32 * 1024

    public static func parse(_ buffer: Data, maxBodyBytes: Int) -> LanHTTPParseResult {
        guard let boundary = buffer.range(of: headerTerminator) else {
            return buffer.count > maxHeaderBytes ? .malformed : .needMore
        }
        guard boundary.lowerBound <= maxHeaderBytes else { return .malformed }

        let headData = buffer.subdata(in: buffer.startIndex..<boundary.lowerBound)
        guard let headString = String(data: headData, encoding: .utf8) else { return .malformed }

        let lines = headString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else { return .malformed }
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return .malformed }

        let method = String(parts[0]).uppercased()
        let target = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        if contentLength < 0 { return .malformed }
        if contentLength > maxBodyBytes { return .tooLarge }

        let bodyStart = boundary.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        if available < contentLength { return .needMore }

        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
        let body = buffer.subdata(in: bodyStart..<bodyEnd)
        let (path, query) = splitTarget(target)
        return .complete(LanHTTPRequest(method: method, path: path, query: query, headers: headers, body: body))
    }

    /// 拆分 `/path?k=v` → (path, query)
    public static func splitTarget(_ target: String) -> (String, [String: String]) {
        guard let qIndex = target.firstIndex(of: "?") else { return (target, [:]) }
        let path = String(target[..<qIndex])
        let queryString = String(target[target.index(after: qIndex)...])
        var query: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let keyPart = kv.first else { continue }
            let key = String(keyPart).removingPercentEncoding ?? String(keyPart)
            let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            query[key] = value
        }
        return (path, query)
    }
}

// MARK: - 路由器（纯函数，便于单元测试）

public enum LanRouteResult: Equatable {
    /// 直接返回响应
    case respond(LanHTTPResponse)
    /// 手机端回传了内容：先投递到主应用，再返回 200
    case accept(LanIncomingDrop, LanHTTPResponse)
}

public struct LanQuickDropRouter {
    public let token: String
    public let payload: LanSharedPayload
    public let maxUploadBytes: Int

    public init(token: String, payload: LanSharedPayload, maxUploadBytes: Int = 50 * 1024 * 1024) {
        self.token = token
        self.payload = payload
        self.maxUploadBytes = maxUploadBytes
    }

    public func route(_ request: LanHTTPRequest) -> LanRouteResult {
        let components = request.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        // 一次性令牌校验：必须形如 /s/<token>/...
        guard components.count >= 2, components[0] == "s", Self.constantTimeEquals(components[1], token) else {
            return .respond(.forbidden())
        }
        let rest = Array(components.dropFirst(2))

        switch (request.method, rest) {
        case ("GET", []):
            let lang = request.headers["accept-language"]
            return .respond(.html(LanQuickDropPage.html(payload: payload, token: token, acceptLanguage: lang)))
        case ("GET", ["payload"]):
            return .respond(makePayloadResponse())
        case ("POST", ["send"]):
            return handleSend(request)
        case ("OPTIONS", _):
            return .respond(.noContent())
        default:
            return .respond(.notFound())
        }
    }

    private func makePayloadResponse() -> LanHTTPResponse {
        switch payload.kind {
        case .text:
            let text = payload.text ?? ""
            return .payload(Data(text.utf8), mimeType: "text/plain; charset=utf-8", fileName: "", inline: true)
        case .image:
            return .payload(payload.binary ?? Data(), mimeType: payload.mimeType, fileName: payload.fileName, inline: true)
        case .file:
            return .payload(payload.binary ?? Data(), mimeType: payload.mimeType, fileName: payload.fileName, inline: false)
        }
    }

    private func handleSend(_ request: LanHTTPRequest) -> LanRouteResult {
        guard request.body.count <= maxUploadBytes else {
            return .respond(.tooLarge())
        }
        let contentType = (request.headers["content-type"] ?? "").lowercased()

        if contentType.contains("application/json") {
            guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let content = object["content"] as? String else {
                return .respond(.badRequest("missing content"))
            }
            let text = content
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .respond(.badRequest("empty content"))
            }
            let drop = LanIncomingDrop(kind: .text, text: text, data: nil, fileName: "", mimeType: "text/plain; charset=utf-8")
            return .accept(drop, .json(["ok": true]))
        }

        // 其余按二进制（图片 / 文件）处理：优先从 X-Nook-Filename 取文件名
        guard !request.body.isEmpty else { return .respond(.badRequest("empty body")) }
        let rawName = request.headers["x-nook-filename"] ?? ""
        let fileName = rawName.removingPercentEncoding ?? rawName
        let mime = contentType.isEmpty ? "application/octet-stream" : contentType
        let ext = (fileName as NSString).pathExtension.lowercased()
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp"]
        let isImage = mime.hasPrefix("image/") || imageExtensions.contains(ext)
        let kind: LanIncomingDrop.Kind = isImage ? .image : .file
        let drop = LanIncomingDrop(
            kind: kind,
            text: nil,
            data: request.body,
            fileName: fileName.isEmpty ? "upload" : fileName,
            mimeType: mime
        )
        return .accept(drop, .json(["ok": true]))
    }

    /// 固定长度常量时间比较，避免令牌被逐字符计时侧信道推断。
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}

// MARK: - 移动端页面（内联、零外部依赖）

public enum LanQuickDropPage {
    public enum Locale: String, Equatable {
        case zhHans = "zh-Hans"
        case zhHant = "zh-Hant"
        case en = "en"
    }

    /// 由 HTTP `Accept-Language` 推断移动端页面初始语言：
    /// - `zh-tw` / `zh-hk` / `zh-mo` / `zh-hant` → 繁體中文
    /// - 其余 `zh*` → 简体中文
    /// - 其它任意国家/语言（或 header 缺失时回退客户端应用语言）→ English
    public static func resolveLocale(acceptLanguage: String?) -> Locale {
        let raw = (acceptLanguage ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let primaryTag: String
        if !raw.isEmpty {
            primaryTag = raw.split(separator: ",").first.map {
                String($0.split(separator: ";").first ?? "")
            } ?? ""
        } else {
            primaryTag = LocalizationManager.shared.effectiveLanguageCode.lowercased()
        }
        if primaryTag.hasPrefix("zh") {
            if primaryTag.contains("hant") || primaryTag.contains("tw") || primaryTag.contains("hk") || primaryTag.contains("mo") {
                return .zhHant
            }
            return .zhHans
        }
        return .en
    }

    public static func html(payload: LanSharedPayload, token: String, acceptLanguage: String? = nil) -> String {
        let locale = resolveLocale(acceptLanguage: acceptLanguage)
        let meta: [String: Any] = [
            "kind": payload.kind.rawValue,
            "title": payload.title,
            "fileName": payload.fileName,
            "token": token,
            "locale": locale.rawValue,
        ]
        let metaJSON: String = {
            guard let data = try? JSONSerialization.data(withJSONObject: meta),
                  var string = String(data: data, encoding: .utf8) else { return "{}" }
            // 防止文件名/标题里出现 </script> 破坏内联脚本
            string = string.replacingOccurrences(of: "</", with: "<\\/")
            return string
        }()
        return template
            .replacingOccurrences(of: "__LAN_LANG__", with: locale.rawValue)
            .replacingOccurrences(of: "__LAN_META__", with: metaJSON)
    }

    private static let template = #"""
<!DOCTYPE html>
<html lang="__LAN_LANG__">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="robots" content="noindex, nofollow">
<title>NookClip · Phone Drop</title>
<style>
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
  body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", "PingFang TC", "Microsoft YaHei", sans-serif; background: #f2f2f7; color: #1d1d1f; padding: 18px; padding-bottom: 40px; }
  @media (prefers-color-scheme: dark) { body { background: #1c1c1e; color: #f5f5f7; } .card { background: #2c2c2e !important; } .muted { color: #98989d !important; } textarea, input[type=text] { background: #1c1c1e !important; color: #f5f5f7 !important; border-color: #3a3a3c !important; } .pre { background: #1c1c1e !important; } }
  .wrap { max-width: 680px; margin: 0 auto; }
  .brand { display: flex; align-items: center; gap: 8px; font-size: 13px; font-weight: 600; color: #007aff; margin-bottom: 14px; }
  .card { background: #fff; border-radius: 14px; padding: 16px; margin-bottom: 14px; box-shadow: 0 1px 3px rgba(0,0,0,.06); }
  h1 { font-size: 17px; margin: 0 0 4px; line-height: 1.35; word-break: break-word; }
  .muted { font-size: 12px; color: #6e6e73; line-height: 1.5; }
  .pre { white-space: pre-wrap; word-break: break-word; background: #f2f2f7; border-radius: 10px; padding: 12px; margin: 12px 0; max-height: 46vh; overflow: auto; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 13px; line-height: 1.55; -webkit-user-select: text; user-select: text; }
  img#img { display: none; max-width: 100%; border-radius: 10px; margin: 12px 0; }
  .btn { appearance: none; border: 0; border-radius: 10px; padding: 11px 16px; font-size: 15px; font-weight: 600; background: #007aff; color: #fff; width: 100%; margin-top: 8px; cursor: pointer; }
  .btn.secondary { background: #e5e5ea; color: #1d1d1f; }
  @media (prefers-color-scheme: dark) { .btn.secondary { background: #3a3a3c; color: #f5f5f7; } }
  .btn:active { opacity: .8; }
  .row { display: flex; gap: 10px; }
  .row > * { flex: 1; }
  textarea { width: 100%; min-height: 92px; border-radius: 10px; border: 1px solid #d1d1d6; padding: 10px 12px; font-size: 15px; font-family: inherit; resize: vertical; background: #fff; color: inherit; }
  .filelabel { display: block; border: 1px dashed #c7c7cc; border-radius: 10px; padding: 14px; text-align: center; font-size: 14px; color: #6e6e73; margin-top: 8px; }
  .status { font-size: 13px; text-align: center; min-height: 20px; margin-top: 6px; color: #34c759; }
  .status.err { color: #ff3b30; }
  .hint { font-size: 12px; color: #6e6e73; margin-top: 6px; }
  .dl { display: inline-block; margin-top: 12px; font-size: 14px; color: #007aff; text-decoration: none; }
</style>
</head>
<body>
<div class="wrap">
  <div class="brand" id="brand">◇ NookClip · Phone Drop</div>

  <div class="card">
    <h1 id="title">From Your Mac</h1>
    <div class="muted" id="subtitle">Peer-to-peer over your local network. Never touches any cloud server.</div>
    <pre class="pre" id="content" style="display:none"></pre>
    <img id="img" alt="Image">
    <a class="dl" id="dl" style="display:none" download>Download</a>
    <button class="btn" id="copyBtn" style="display:none">Copy Text</button>
  </div>

  <div class="card">
    <h1 id="sendHeading">Send to Mac Clipboard</h1>
    <div class="muted" id="sendDesc">Type text below or pick a photo / file from your phone to send it straight to your Mac.</div>
    <textarea id="textInput" placeholder="Type text to send to your Mac…"></textarea>
    <button class="btn" id="sendTextBtn">Send Text to Mac</button>
    <label class="filelabel" for="fileInput" id="fileLabel">Or tap to choose a photo / file</label>
    <input type="file" id="fileInput" style="display:none">
    <button class="btn secondary" id="sendFileBtn" style="display:none">Send Selected File to Mac</button>
    <div class="status" id="status"></div>
    <div class="hint" id="footerHint">Keep the Phone Drop view open on your Mac during transfer — closing it or waiting 5 minutes disconnects immediately.</div>
  </div>
</div>
<script>
(function () {
  var META = __LAN_META__;
  var I18N = {
    'zh-Hans': {
      brand: '◇ NookClip · 手机互传',
      fromMac: '来自电脑的内容',
      subtitleText: '同一局域网内点对点传输，数据不经过任何服务器。',
      subtitleImg: '长按图片可保存到相册。',
      subtitleFile: '点下方链接下载电脑上的文件。',
      dlImg: '下载原图',
      dlFilePrefix: '下载文件：',
      dlFileFallback: '文件',
      copyBtn: '一键复制文本',
      copied: '已复制到手机剪贴板',
      copyFail: '复制失败，请长按选择文本',
      loadFail: '连接已断开，请确认电脑端仍保持快传界面打开',
      sendHeading: '发送到电脑剪贴板',
      sendDesc: '在下方输入文字，或选择手机相册里的图片 / 文件，点发送即可传回 Mac。',
      textPlaceholder: '在这里输入要发回电脑的文字…',
      sendTextBtn: '发送文字到电脑',
      fileLabelIdle: '或点此选择图片 / 文件',
      fileLabelPicked: '已选择：',
      sendFileBtn: '发送所选文件到电脑',
      footerHint: '仅在同一 Wi-Fi / 局域网内有效；传输期间请保持电脑端快传界面打开，关闭界面或超过 5 分钟将立即断开连接。',
      emptyTextErr: '请先输入文字',
      emptyFileErr: '请先选择文件',
      sending: '发送中…',
      uploading: '上传中…',
      sentOk: '已发送到电脑剪贴板 ✓',
      sendFail: '发送失败，请确认电脑端仍保持快传界面打开',
      uploadTooLarge: '上传失败，文件可能超过 50MB'
    },
    'zh-Hant': {
      brand: '◇ NookClip · 手機互傳',
      fromMac: '來自電腦的內容',
      subtitleText: '同一區域網路內點對點傳輸，資料不經過任何伺服器。',
      subtitleImg: '長按圖片可儲存到相簿。',
      subtitleFile: '點下方連結下載電腦上的檔案。',
      dlImg: '下載原圖',
      dlFilePrefix: '下載檔案：',
      dlFileFallback: '檔案',
      copyBtn: '一鍵複製文字',
      copied: '已複製到手機剪貼簿',
      copyFail: '複製失敗，請長按選取文字',
      loadFail: '連線已中斷，請確認電腦端仍保持快傳介面開啟',
      sendHeading: '傳送到電腦剪貼簿',
      sendDesc: '在下方輸入文字，或選取手機相簿裡的圖片 / 檔案，點傳送即可傳回 Mac。',
      textPlaceholder: '在這裡輸入要傳回電腦的文字…',
      sendTextBtn: '傳送文字到電腦',
      fileLabelIdle: '或點此選取圖片 / 檔案',
      fileLabelPicked: '已選取：',
      sendFileBtn: '傳送所選檔案到電腦',
      footerHint: '僅在同一 Wi-Fi / 區域網路內有效；傳輸期間請保持電腦端快傳介面開啟，關閉介面或超過 5 分鐘將立即中斷連線。',
      emptyTextErr: '請先輸入文字',
      emptyFileErr: '請先選取檔案',
      sending: '傳送中…',
      uploading: '上傳中…',
      sentOk: '已傳送到電腦剪貼簿 ✓',
      sendFail: '傳送失敗，請確認電腦端仍保持快傳介面開啟',
      uploadTooLarge: '上傳失敗，檔案可能超過 50MB'
    },
    'en': {
      brand: '◇ NookClip · Phone Drop',
      fromMac: 'From Your Mac',
      subtitleText: 'Peer-to-peer over your local network. Never touches any cloud server.',
      subtitleImg: 'Long-press the image to save it to Photos.',
      subtitleFile: 'Tap the link below to download the file from your Mac.',
      dlImg: 'Download Original Image',
      dlFilePrefix: 'Download: ',
      dlFileFallback: 'file',
      copyBtn: 'Copy Text',
      copied: 'Copied to phone clipboard',
      copyFail: 'Copy failed — long-press to select text',
      loadFail: 'Disconnected — make sure Phone Drop is still open on your Mac',
      sendHeading: 'Send to Mac Clipboard',
      sendDesc: 'Type text below or pick a photo / file from your phone to send it straight to your Mac.',
      textPlaceholder: 'Type text to send to your Mac…',
      sendTextBtn: 'Send Text to Mac',
      fileLabelIdle: 'Or tap to choose a photo / file',
      fileLabelPicked: 'Selected: ',
      sendFileBtn: 'Send Selected File to Mac',
      footerHint: 'Works on the same Wi-Fi / LAN only. Keep the Phone Drop view open on your Mac during transfer — closing it or waiting 5 minutes disconnects immediately.',
      emptyTextErr: 'Please enter some text first',
      emptyFileErr: 'Please select a file first',
      sending: 'Sending…',
      uploading: 'Uploading…',
      sentOk: 'Sent to Mac clipboard ✓',
      sendFail: 'Send failed — make sure Phone Drop is still open on your Mac',
      uploadTooLarge: 'Upload failed (file may exceed 50 MB)'
    }
  };

  function pickLocale() {
    var raw = (META.locale || navigator.language || 'en').toLowerCase();
    if (raw.indexOf('zh') === 0) {
      if (raw.indexOf('hant') >= 0 || raw.indexOf('tw') >= 0 || raw.indexOf('hk') >= 0 || raw.indexOf('mo') >= 0) {
        return 'zh-Hant';
      }
      return 'zh-Hans';
    }
    return 'en';
  }

  var L = I18N[pickLocale()] || I18N['en'];
  document.title = L.brand.replace('◇ ', '');
  document.getElementById('brand').textContent = L.brand;
  document.getElementById('subtitle').textContent = L.subtitleText;
  document.getElementById('copyBtn').textContent = L.copyBtn;
  document.getElementById('sendHeading').textContent = L.sendHeading;
  document.getElementById('sendDesc').textContent = L.sendDesc;
  document.getElementById('textInput').placeholder = L.textPlaceholder;
  document.getElementById('sendTextBtn').textContent = L.sendTextBtn;
  document.getElementById('fileLabel').textContent = L.fileLabelIdle;
  document.getElementById('sendFileBtn').textContent = L.sendFileBtn;
  document.getElementById('footerHint').textContent = L.footerHint;

  var base = '/s/' + META.token;
  var statusEl = document.getElementById('status');

  function setStatus(text, isErr) {
    statusEl.textContent = text;
    statusEl.className = 'status' + (isErr ? ' err' : '');
  }

  function loadShared() {
    document.getElementById('title').textContent = META.title || L.fromMac;
    if (META.kind === 'text') {
      var pre = document.getElementById('content');
      pre.style.display = 'block';
      fetch(base + '/payload', { cache: 'no-store' }).then(function (r) { return r.text(); }).then(function (t) {
        pre.textContent = t;
      }).catch(function () { setStatus(L.loadFail, true); });
      var copyBtn = document.getElementById('copyBtn');
      copyBtn.style.display = 'block';
      copyBtn.addEventListener('click', function () {
        var text = pre.textContent || '';
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(text).then(function () { setStatus(L.copied); })
            .catch(function () { fallbackCopy(text); });
        } else { fallbackCopy(text); }
      });
    } else if (META.kind === 'image') {
      var img = document.getElementById('img');
      img.src = base + '/payload';
      img.style.display = 'block';
      document.getElementById('subtitle').textContent = L.subtitleImg;
      var dl = document.getElementById('dl');
      dl.href = base + '/payload';
      dl.textContent = L.dlImg;
      dl.style.display = 'inline-block';
    } else {
      var dlf = document.getElementById('dl');
      dlf.href = base + '/payload';
      dlf.textContent = L.dlFilePrefix + (META.fileName || L.dlFileFallback);
      dlf.style.display = 'inline-block';
      document.getElementById('subtitle').textContent = L.subtitleFile;
    }
  }

  function fallbackCopy(text) {
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand('copy'); setStatus(L.copied); }
    catch (e) { setStatus(L.copyFail, true); }
    document.body.removeChild(ta);
  }

  document.getElementById('sendTextBtn').addEventListener('click', function () {
    var val = document.getElementById('textInput').value;
    if (!val || !val.trim()) { setStatus(L.emptyTextErr, true); return; }
    setStatus(L.sending);
    fetch(base + '/send', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ type: 'text', content: val })
    }).then(function (r) { return r.json(); }).then(function (res) {
      if (res && res.ok) { setStatus(L.sentOk); document.getElementById('textInput').value = ''; }
      else { setStatus(L.sendFail, true); }
    }).catch(function () { setStatus(L.sendFail, true); });
  });

  var fileInput = document.getElementById('fileInput');
  var selectedFile = null;
  fileInput.addEventListener('change', function () {
    selectedFile = fileInput.files && fileInput.files[0] ? fileInput.files[0] : null;
    var btn = document.getElementById('sendFileBtn');
    if (selectedFile) {
      document.getElementById('fileLabel').textContent = L.fileLabelPicked + selectedFile.name;
      btn.style.display = 'block';
    } else {
      document.getElementById('fileLabel').textContent = L.fileLabelIdle;
      btn.style.display = 'none';
    }
  });

  document.getElementById('sendFileBtn').addEventListener('click', function () {
    if (!selectedFile) { setStatus(L.emptyFileErr, true); return; }
    setStatus(L.uploading);
    fetch(base + '/send', {
      method: 'POST',
      headers: {
        'Content-Type': selectedFile.type || 'application/octet-stream',
        'X-Nook-Filename': encodeURIComponent(selectedFile.name)
      },
      body: selectedFile
    }).then(function (r) { return r.json(); }).then(function (res) {
      if (res && res.ok) {
        setStatus(L.sentOk);
        selectedFile = null;
        fileInput.value = '';
        document.getElementById('fileLabel').textContent = L.fileLabelIdle;
        document.getElementById('sendFileBtn').style.display = 'none';
      } else { setStatus(L.uploadTooLarge, true); }
    }).catch(function () { setStatus(L.sendFail, true); });
  });

  loadShared();
})();
</script>
</body>
</html>
"""#
}

// MARK: - 网络服务（NWListener）

public enum LanQuickDropServerError: Error, Equatable {
    case alreadyRunning
    case listenerFailed
}

/// 基于 Network.framework 的临时 HTTP 服务。线程模型：所有网络回调都在 `queue` 串行执行，
/// 对外只暴露线程安全的快照读取；状态变更通过回调交回主线程（由 Controller 负责）。
public final class LanQuickDropServer: @unchecked Sendable {
    public static let defaultTTLSeconds = 300
    public static let maxUploadBytes = 50 * 1024 * 1024

    private let queue: DispatchQueue
    private var listener: NWListener?
    private var token: String = ""
    private var payload: LanSharedPayload?
    private var onReceive: (@Sendable (LanIncomingDrop) -> Void)?
    private var onExpire: (@Sendable () -> Void)?
    private var expiryTimer: DispatchSourceTimer?
    private var startContinuation: CheckedContinuation<UInt16, Error>?
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]
    private var ttlSeconds: Int = LanQuickDropServer.defaultTTLSeconds

    public init(queue: DispatchQueue = DispatchQueue(label: "com.lx3xun.nookclip.landrop", qos: .userInitiated)) {
        self.queue = queue
    }

    // MARK: 线程安全快照

    public var isRunning: Bool { queue.sync { listener != nil } }
    public var currentToken: String { queue.sync { token } }
    public var currentPort: UInt16 { queue.sync { listener?.port?.rawValue ?? 0 } }

    // MARK: 启停

    /// 启动监听，返回实际分配到的端口。
    /// - Parameters:
    ///   - payload: 当前分享内容快照
    ///   - ttlSeconds: 有效期（默认 300 秒），到期自动释放端口并回调 onExpire
    ///   - onReceive: 收到手机回传内容时回调（在 queue 上执行，调用方负责切主线程）
    ///   - onExpire: 超时自动关闭时回调（在 queue 上执行）
    public func start(
        payload: LanSharedPayload,
        ttlSeconds: Int = LanQuickDropServer.defaultTTLSeconds,
        onReceive: (@Sendable (LanIncomingDrop) -> Void)? = nil,
        onExpire: (@Sendable () -> Void)? = nil
    ) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: LanQuickDropServerError.listenerFailed)
                    return
                }
                guard self.listener == nil else {
                    continuation.resume(throwing: LanQuickDropServerError.alreadyRunning)
                    return
                }

                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                let listener: NWListener
                do {
                    listener = try NWListener(using: parameters, on: .any)
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                self.token = Self.randomToken()
                self.payload = payload
                self.onReceive = onReceive
                self.onExpire = onExpire
                self.ttlSeconds = max(1, ttlSeconds)
                self.startContinuation = continuation
                self.listener = listener

                listener.stateUpdateHandler = { [weak self] state in
                    self?.handleListenerState(state)
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.start(queue: self.queue)
                self.scheduleExpiry()
            }
        }
    }

    /// 停止监听并释放端口（幂等）。
    public func stop() {
        queue.async { [weak self] in
            self?.teardown(callExpire: false)
        }
    }

    // MARK: 监听状态

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            let port = listener?.port?.rawValue ?? 0
            resumeStart(.success(port))
        case .failed(let error):
            resumeStart(.failure(error))
            teardown(callExpire: false)
        case .waiting(let error):
            // 无可用网络等场景不要无限等待：直接失败，让上层提示「先连 Wi-Fi」
            resumeStart(.failure(error))
            teardown(callExpire: false)
        default:
            break
        }
    }

    private func resumeStart(_ result: Result<UInt16, Error>) {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        switch result {
        case .success(let port): continuation.resume(returning: port)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }

    private func scheduleExpiry() {
        expiryTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(ttlSeconds))
        timer.setEventHandler { [weak self] in
            self?.teardown(callExpire: true)
        }
        timer.resume()
        expiryTimer = timer
    }

    /// 释放所有资源。`callExpire == true` 表示因超时触发，需要通知上层。
    private func teardown(callExpire: Bool) {
        let expireHandler = callExpire ? onExpire : nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        expiryTimer?.cancel()
        expiryTimer = nil
        for (_, connection) in activeConnections {
            connection.cancel()
        }
        activeConnections.removeAll()
        token = ""
        payload = nil
        onReceive = nil
        onExpire = nil
        if let continuation = startContinuation {
            startContinuation = nil
            continuation.resume(throwing: LanQuickDropServerError.listenerFailed)
        }
        expireHandler?()
    }

    // MARK: 连接处理

    private func accept(_ connection: NWConnection) {
        activeConnections[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.queue.async {
                    self?.activeConnections.removeValue(forKey: ObjectIdentifier(connection))
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }

            guard let payload = self.payload else {
                self.close(connection)
                return
            }
            let router = LanQuickDropRouter(token: self.token, payload: payload, maxUploadBytes: LanQuickDropServer.maxUploadBytes)
            let parseResult = LanHTTPParser.parse(accumulated, maxBodyBytes: LanQuickDropServer.maxUploadBytes)

            switch parseResult {
            case .complete(let request):
                self.dispatch(request, on: connection, router: router)
                return
            case .tooLarge:
                self.send(.tooLarge(), on: connection)
                return
            case .malformed:
                self.send(.badRequest(), on: connection)
                return
            case .needMore:
                if error != nil || isComplete {
                    self.close(connection)
                    return
                }
                // 双保险：header 已解析但 body 异常累积过大时中止
                if accumulated.count > LanQuickDropServer.maxUploadBytes + LanHTTPParser.maxHeaderBytes {
                    self.send(.tooLarge(), on: connection)
                    return
                }
                self.receive(on: connection, buffer: accumulated)
            }
        }
    }

    private func dispatch(_ request: LanHTTPRequest, on connection: NWConnection, router: LanQuickDropRouter) {
        switch router.route(request) {
        case .respond(let response):
            send(response, on: connection)
        case .accept(let drop, let response):
            onReceive?(drop)
            send(response, on: connection)
        }
    }

    private func send(_ response: LanHTTPResponse, on connection: NWConnection) {
        let data = response.serialized()
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            self?.queue.async {
                self?.activeConnections.removeValue(forKey: ObjectIdentifier(connection))
            }
        })
    }

    private func close(_ connection: NWConnection) {
        connection.cancel()
        queue.async { [weak self] in
            self?.activeConnections.removeValue(forKey: ObjectIdentifier(connection))
        }
    }

    // MARK: 令牌与网卡

    /// 128-bit 随机十六进制令牌（32 字符）
    public static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// 枚举本机物理局域网 IPv4，过滤 VPN / 虚拟网卡，优先 en0 / en1 的 RFC1918 私有地址。
    public static func candidateIPv4Addresses() -> [String] {
        var results: [(priority: Int, address: String)] = []
        var ifaddrsPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrsPointer) == 0, let first = ifaddrsPointer else { return [] }
        defer { freeifaddrs(ifaddrsPointer) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = cursor {
            let interface = pointer.pointee
            cursor = interface.ifa_next

            guard let addrPointer = interface.ifa_addr else { continue }
            let family = addrPointer.pointee.sa_family
            guard family == UInt8(AF_INET) else { continue }
            // 仅保留已启用、已运行、非环回接口
            let flags = Int32(interface.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_RUNNING) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }

            let name = String(cString: interface.ifa_name)
            guard !isVirtualInterface(name) else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addrPointer, socklen_t(addrPointer.pointee.sa_len),
                &hostname, socklen_t(hostname.count),
                nil, 0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let address = String(cString: hostname)
            guard isPrivateIPv4(address) else { continue }

            let priority = interfacePriority(name)
            results.append((priority, address))
        }

        // 优先 en0/en1，其次其它物理接口；同优先级按地址字典序保证稳定
        results.sort { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            return lhs.address < rhs.address
        }
        var seen = Set<String>()
        return results.map(\.address).filter { seen.insert($0).inserted }
    }

    private static func isVirtualInterface(_ name: String) -> Bool {
        let virtualPrefixes = ["utun", "ppp", "ipsec", "bridge", "vnic", "vmnet", "tun", "tap", "awdl", "llw", "anpi", "gif", "stf", "ap", "docker", "veth"]
        return virtualPrefixes.contains { name.hasPrefix($0) }
    }

    private static func interfacePriority(_ name: String) -> Int {
        if name == "en0" { return 0 }
        if name == "en1" { return 1 }
        if name.hasPrefix("en") { return 2 }
        return 3
    }

    static func isPrivateIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        if parts[0] == 10 { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        return false
    }
}

// MARK: - 会话控制器（MainActor · UI 状态）

public enum LanQuickDropFailure: Equatable {
    case noNetwork
    case startFailed
    case expired
}

/// UI 观察的会话状态机：持有 server，负责倒计时、已收到计数与 IP 选择。
@MainActor
public final class LanQuickDropController: ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public private(set) var token = ""
    @Published public private(set) var port: UInt16 = 0
    @Published public var availableIPs: [String] = []
    @Published public var selectedIP = ""
    @Published public private(set) var remainingSeconds = LanQuickDropServer.defaultTTLSeconds
    @Published public private(set) var receivedCount = 0
    @Published public private(set) var failure: LanQuickDropFailure?

    private let server: LanQuickDropServer
    private let ttlSeconds: Int
    private var timer: Timer?
    private var onReceiveHandler: ((LanIncomingDrop) -> Void)?

    public init(server: LanQuickDropServer = LanQuickDropServer(), ttlSeconds: Int = LanQuickDropServer.defaultTTLSeconds) {
        self.server = server
        self.ttlSeconds = ttlSeconds
    }

    public var shareURLString: String {
        guard isRunning, !selectedIP.isEmpty, port > 0 else { return "" }
        return "http://\(selectedIP):\(port)/s/\(token)"
    }

    /// 启动快传服务：先探测物理局域网地址，无网时直接进入失败态并提示。
    public func start(payload: LanSharedPayload, onReceive: @escaping (LanIncomingDrop) -> Void) async {
        onReceiveHandler = onReceive
        availableIPs = LanQuickDropServer.candidateIPv4Addresses()
        if selectedIP.isEmpty || !availableIPs.contains(selectedIP) {
            selectedIP = availableIPs.first ?? ""
        }
        guard !availableIPs.isEmpty else {
            failure = .noNetwork
            isRunning = false
            return
        }
        do {
            let allocatedPort = try await server.start(
                payload: payload,
                ttlSeconds: ttlSeconds,
                onReceive: { [weak self] drop in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.receivedCount += 1
                        self.onReceiveHandler?(drop)
                    }
                },
                onExpire: { [weak self] in
                    Task { @MainActor [weak self] in self?.handleExpired() }
                }
            )
            port = allocatedPort
            token = server.currentToken
            isRunning = true
            failure = nil
            remainingSeconds = ttlSeconds
            startTimer()
        } catch {
            failure = .startFailed
            isRunning = false
        }
    }

    /// 手动停止（关闭弹窗 / 点停止分享）。
    public func stop() {
        stopTimer()
        server.stop()
        isRunning = false
        token = ""
        port = 0
    }

    /// 切换展示用的局域网 IP（服务仍监听全部本地接口，仅改变二维码里的地址）。
    public func selectIP(_ ip: String) {
        guard availableIPs.contains(ip) else { return }
        selectedIP = ip
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard isRunning else { return }
        if remainingSeconds > 0 { remainingSeconds -= 1 }
        if remainingSeconds <= 0 { handleExpired() }
    }

    private func handleExpired() {
        guard isRunning else { return }
        stopTimer()
        server.stop()
        isRunning = false
        token = ""
        port = 0
        remainingSeconds = 0
        failure = .expired
    }
}
