import AppKit
import JavaScriptCore
import SwiftUI

// MARK: - highlight.js 高亮服务（直驱 JSContext + 原生 Span 解析器）
//
// 为什么自研高亮渲染管线（直驱 JSContext + 原生 Span 解析器）：
//   1. 传统基于 WebKit NSAttributedString(.html) 的导入管线冷启动耗时 150~300ms 且污染
//      进程内存页，还会在 <pre><code> 外层调 trimmingCharacters(in: .whitespacesAndNewlines)
//      破坏首行缩进、折叠 <code><span> 边界空白并将 \r\n 改写为 \n，导致行号错位。
//   2. highlight.js 的输出仅包含 `<span class="...">`、`</span>` 与 5 种基础 HTML
//      实体（&amp; &lt; &gt; &quot; &#x27;）。本服务在后台 actor 执行 highlight.js，
//      再用零 WebKit 开销的原生状态机直接解析 span 树并映射 GitHub Primer 明暗色板：
//      - 耗时从 ~200ms 降至 ~5ms，彻底消除 WebKit HTML 导入开销
//      - 100% 保持原文所有缩进、空格与换行结构（与行号列严格对齐）
//      - 支持 NookClip 语言 ID 到 highlight.js 语法的精确别名映射与回退（如 shell→bash、vue→xml、groovy→java）
//      - 提供同步缓存快路（cachedOutcome），已高亮条目切换预览时首帧直出零闪烁

/// 后台 JS 执行器：管理 JSContext 与 highlight.min.js 的按需加载
private actor HLJSEngine {
    struct RawResult: Sendable {
        let htmlValue: String
        let language: String
        let relevance: Int
    }

    private var hljs: JSValue?
    private static var cachedScript: String?

    private func loadHLJS() -> JSValue? {
        if let hljs { return hljs }
        guard let script = Self.loadScript(),
              let context = JSContext() else { return nil }
        context.evaluateScript(script)
        guard let obj = context.objectForKeyedSubscript("hljs"), !obj.isUndefined else {
            return nil
        }
        self.hljs = obj
        return obj
    }

    private static func loadScript() -> String? {
        if let cachedScript { return cachedScript }
        let candidateBundles: [Bundle] = [
            Bundle.module,
            Bundle.main,
        ]
        for bundle in candidateBundles {
            if let path = bundle.path(forResource: "highlight.min", ofType: "js"),
               let content = try? String(contentsOfFile: path, encoding: .utf8) {
                cachedScript = content
                return content
            }
        }
        for bundle in Bundle.allBundles + Bundle.allFrameworks {
            if let path = bundle.path(forResource: "highlight.min", ofType: "js"),
               let content = try? String(contentsOfFile: path, encoding: .utf8) {
                cachedScript = content
                return content
            }
        }
        return nil
    }

    static func clearCachedScript() {
        cachedScript = nil
    }
    func highlight(_ text: String, languageAlias: String?) -> RawResult? {
        guard let hljs = loadHLJS() else { return nil }
        if let alias = languageAlias {
            let options: [String: Any] = ["language": alias, "ignoreIllegals": true]
            if let res = hljs.invokeMethod("highlight", withArguments: [text, options]),
               let parsed = Self.extract(res) {
                return parsed
            }
            // 指定别名不被 highlight.js 识别时自动回退自动检测
        }
        guard let res = hljs.invokeMethod("highlightAuto", withArguments: [text]) else {
            return nil
        }
        return Self.extract(res)
    }

    private static func extract(_ result: JSValue) -> RawResult? {
        guard !result.isUndefined, !result.isNull,
              let valObj = result.objectForKeyedSubscript("value"),
              !valObj.isUndefined, !valObj.isNull,
              let htmlValue = valObj.toString(),
              htmlValue != "undefined" else {
            return nil
        }
        let langObj = result.objectForKeyedSubscript("language")
        let language: String
        if let langObj, !langObj.isUndefined, !langObj.isNull, let str = langObj.toString(), str != "undefined" {
            language = str
        } else {
            language = "unknown"
        }
        let relevance = Int(result.objectForKeyedSubscript("relevance")?.toInt32() ?? 0)
        return RawResult(htmlValue: htmlValue, language: language, relevance: relevance)
    }
}

@MainActor
enum CodeHighlightService {
    struct Outcome {
        let attributed: NSAttributedString
        /// 检测到的语言展示名（规范化展示名，如 Swift / C++ / Objective-C）；nil = 检测失败
        let languageName: String?
    }

    /// JSContext（308KB highlight.min.js）空闲 60s 后释放，下次高亮时重建
    private static var engine: HLJSEngine?
    private static var idleReleaseTask: Task<Void, Never>?
    private static let idleReleaseSeconds: TimeInterval = 60
    private static let timeoutSeconds: TimeInterval = 1

    private static func acquireEngine() -> HLJSEngine {
        idleReleaseTask?.cancel()
        idleReleaseTask = nil
        if let engine { return engine }
        let instance = HLJSEngine()
        engine = instance
        return instance
    }

    private static func scheduleIdleRelease() {
        idleReleaseTask?.cancel()
        let seconds = idleReleaseSeconds
        idleReleaseTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            engine = nil
            HLJSEngine.clearCachedScript()
            idleReleaseTask = nil
        }
    }

    /// 面板收起闲置后立即释放 JSContext 引擎、highlight.min.js 源码缓存与富文本高亮缓存
    static func purgeIdleMemory() {
        idleReleaseTask?.cancel()
        idleReleaseTask = nil
        engine = nil
        HLJSEngine.clearCachedScript()
        cache.removeAll()
        order.removeAll()
    }

    // MARK: - 语言别名映射与展示名规范化

    /// 将 NookClip / LanguageClassifier 语言标识映射为 highlight.js 实际支持的语法名。
    /// 返回 nil 表示交由 highlightAuto 自动检测。
    static func resolveHighlightAlias(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return nil }
        switch lowered {
        case "code", "unknown", "auto", "plaintext", "text", "txt":
            return nil
        case "shell", "sh", "zsh", "fish":
            // highlight.js 的 "shell" 是交互式终端会话（要求 $ / # 提示符），脚本须走 "bash"
            return "bash"
        case "vue", "html", "xhtml", "svg", "plist":
            return "xml"
        case "jsx":
            return "javascript"
        case "tsx":
            return "typescript"
        case "objc", "obj-c", "objective-c", "objectivec":
            return "objectivec"
        case "csharp", "c#", "cs":
            return "csharp"
        case "cpp", "c++", "cc", "cxx", "hpp":
            return "cpp"
        case "vb", "vbnet", "visualbasic":
            return "vbnet"
        case "groovy":
            // highlight.min.js 未内置 groovy 独立语法，语法同构的 java 可提供完整着色
            return "java"
        case "toml":
            return "ini"
        case "yml":
            return "yaml"
        case "md":
            return "markdown"
        case "docker":
            return "dockerfile"
        case "py":
            return "python"
        case "js":
            return "javascript"
        case "ts":
            return "typescript"
        case "rb":
            return "ruby"
        case "rs":
            return "rust"
        case "kt", "kts":
            return "kotlin"
        case "golang":
            return "go"
        default:
            return lowered
        }
    }

    /// 生成卡片右上角胶囊的规范展示名（优先尊重用户/分类器已知的细分语言如 Vue/JSX/Shell/TOML）
    static func resolveDisplayLanguage(detected: String, forcedLanguage: String?) -> String? {
        if let forced = forcedLanguage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !forced.isEmpty {
            let normForced = LanguageClassifier.normalize(forced)
            if normForced != "code" && normForced != "unknown" && normForced != "auto" {
                return LanguageClassifier.displayName(for: normForced)
            }
        }
        let lowered = detected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty, lowered != "unknown", lowered != "undefined", lowered != "plaintext" else {
            return nil
        }
        switch lowered {
        case "xml": return "HTML"
        case "bash", "shell": return "Shell"
        case "ini": return "TOML"
        case "cpp": return "C++"
        case "csharp": return "C#"
        case "objectivec": return "Objective-C"
        case "javascript": return "JavaScript"
        case "typescript": return "TypeScript"
        case "vbnet": return "VB"
        case "graphql": return "GraphQL"
        case "pgsql": return "PostgreSQL"
        case "php-template": return "PHP"
        case "python-repl": return "Python"
        case "dockerfile": return "Dockerfile"
        case "makefile": return "Makefile"
        case "markdown": return "Markdown"
        case "applescript": return "AppleScript"
        case "ocaml": return "OCaml"
        case "css", "sql", "json", "php", "scss", "toml", "yaml", "wasm", "awk":
            return lowered.uppercased()
        default:
            return LanguageClassifier.displayName(for: lowered)
        }
    }

    // MARK: - LRU 缓存（key = 内容 + 长度 + 规范化语言 + 明暗）

    private struct CacheKey: Hashable {
        let contentHash: Int
        let length: Int
        let normalizedForcedLanguage: String?
        let dark: Bool
    }
    private static var cache: [CacheKey: Outcome] = [:]
    private static var order: [CacheKey] = []
    private static let cacheLimit = 32

    private static func makeCacheKey(text: String, forcedLanguage: String?, dark: Bool) -> CacheKey {
        let norm = forcedLanguage
            .map { LanguageClassifier.normalize($0) }
            .flatMap { ($0.isEmpty || $0 == "code" || $0 == "unknown") ? nil : $0 }
        return CacheKey(
            contentHash: text.hashValue,
            length: text.count,
            normalizedForcedLanguage: norm,
            dark: dark
        )
    }

    /// 同步查询 LRU 缓存：命中时直接返回高亮结果，供视图首帧直出避免占位闪烁
    static func cachedOutcome(for text: String, forcedLanguage: String?, dark: Bool) -> Outcome? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let key = makeCacheKey(text: text, forcedLanguage: forcedLanguage, dark: dark)
        guard let hit = cache[key] else { return nil }
        touch(key)
        scheduleIdleRelease()
        return hit
    }

    /// 高亮一段代码。失败/超时/纯空白一律返回 nil，由调用方保持占位渲染（SyntaxHighlighter）。
    static func outcome(for text: String, forcedLanguage: String?, dark: Bool) async -> Outcome? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let key = makeCacheKey(text: text, forcedLanguage: forcedLanguage, dark: dark)
        if let hit = cache[key] {
            touch(key)
            scheduleIdleRelease()
            return hit
        }

        let alias = resolveHighlightAlias(forcedLanguage)
        let currentEngine = acquireEngine()
        defer { scheduleIdleRelease() }
        do {
            let raw = try await withTimeout(Self.timeoutSeconds) {
                await currentEngine.highlight(text, languageAlias: alias)
            }
            guard let raw, !raw.htmlValue.isEmpty else { return nil }
            // 自动检测且完全无匹配特征（relevance == 0 且无已知强制语言）时保留占位着色
            if alias == nil && raw.language == "unknown" && raw.relevance == 0 {
                return nil
            }
            let attributed = renderSpanHTML(raw.htmlValue, dark: dark)
            guard attributed.length > 0 else { return nil }
            let outcome = Outcome(
                attributed: attributed,
                languageName: resolveDisplayLanguage(detected: raw.language, forcedLanguage: forcedLanguage)
            )
            store(key, outcome)
            return outcome
        } catch {
            return nil
        }
    }

    // MARK: - 原生 Span 状态机解析与 GitHub Primer 主题着色

    private static func hexColor(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }

    /// GitHub Primer Light 语法色板（高对比度，契合浅色代码底 #F7F7FA）
    private static let lightPalette: [String: NSColor] = {
        let keyword = hexColor(0xCF222E)   // 关键字 / 类型 / 模板变量
        let title   = hexColor(0x8250DF)   // 函数名 / 类名 / 标题
        let attr    = hexColor(0x0550AE)   // 数字 / 字面量 / 属性 / 常量 / 运算符
        let string  = hexColor(0x0A3069)   // 字符串 / 正则
        let builtIn = hexColor(0x953800)   // 内置类型 / 符号 / 宏变量
        let comment = hexColor(0x6E7781)   // 注释 / 文档
        let tag     = hexColor(0x116329)   // HTML/XML 标签名 / 选择器 / 新增行
        let del     = hexColor(0x82071E)   // 删除行
        let fg      = NookClip.nsCodeText
        return [
            "hljs": fg,
            "hljs-subst": fg,
            "hljs-punctuation": fg,
            "hljs-doctag": keyword,
            "hljs-keyword": keyword,
            "hljs-template-tag": keyword,
            "hljs-template-variable": keyword,
            "hljs-type": keyword,
            "hljs-variable.language_": keyword,
            "hljs-title": title,
            "hljs-title.class_": title,
            "hljs-title.class_.inherited__": title,
            "hljs-title.function_": title,
            "hljs-function": title,
            "hljs-attr": attr,
            "hljs-attribute": attr,
            "hljs-literal": attr,
            "hljs-meta": attr,
            "hljs-number": attr,
            "hljs-operator": attr,
            "hljs-variable": attr,
            "hljs-variable.constant_": attr,
            "hljs-selector-attr": attr,
            "hljs-selector-class": attr,
            "hljs-selector-id": attr,
            "hljs-section": attr,
            "hljs-link": attr,
            "hljs-regexp": string,
            "hljs-string": string,
            "hljs-built_in": builtIn,
            "hljs-symbol": builtIn,
            "hljs-bullet": builtIn,
            "hljs-params": fg,
            "hljs-property": attr,
            "hljs-comment": comment,
            "hljs-code": comment,
            "hljs-formula": comment,
            "hljs-name": tag,
            "hljs-quote": tag,
            "hljs-tag": tag,
            "hljs-selector-tag": tag,
            "hljs-selector-pseudo": tag,
            "hljs-addition": tag,
            "hljs-deletion": del,
        ]
    }()

    /// GitHub Primer Dark 语法色板（契合深色代码底 #222226）
    private static let darkPalette: [String: NSColor] = {
        let keyword = hexColor(0xFF7B72)   // 关键字 / 类型
        let title   = hexColor(0xD2A8FF)   // 函数名 / 类名
        let attr    = hexColor(0x79C0FF)   // 数字 / 字面量 / 属性 / 常量
        let string  = hexColor(0xA5D6FF)   // 字符串 / 正则
        let builtIn = hexColor(0xFFA657)   // 内置类型 / 符号
        let comment = hexColor(0x8B949E)   // 注释
        let tag     = hexColor(0x7EE787)   // 标签名 / 选择器
        let bullet  = hexColor(0xF2CC60)   // 列表项
        let add     = hexColor(0xAFF5B4)   // 新增行
        let del     = hexColor(0xFFDCD7)   // 删除行
        let fg      = NookClip.nsCodeText
        return [
            "hljs": fg,
            "hljs-subst": fg,
            "hljs-punctuation": fg,
            "hljs-doctag": keyword,
            "hljs-keyword": keyword,
            "hljs-template-tag": keyword,
            "hljs-template-variable": keyword,
            "hljs-type": keyword,
            "hljs-variable.language_": keyword,
            "hljs-title": title,
            "hljs-title.class_": title,
            "hljs-title.class_.inherited__": title,
            "hljs-title.function_": title,
            "hljs-function": title,
            "hljs-attr": attr,
            "hljs-attribute": attr,
            "hljs-literal": attr,
            "hljs-meta": attr,
            "hljs-number": attr,
            "hljs-operator": attr,
            "hljs-variable": attr,
            "hljs-variable.constant_": attr,
            "hljs-selector-attr": attr,
            "hljs-selector-class": attr,
            "hljs-selector-id": attr,
            "hljs-section": attr,
            "hljs-link": attr,
            "hljs-regexp": string,
            "hljs-string": string,
            "hljs-built_in": builtIn,
            "hljs-symbol": builtIn,
            "hljs-bullet": bullet,
            "hljs-params": fg,
            "hljs-property": attr,
            "hljs-comment": comment,
            "hljs-code": comment,
            "hljs-formula": comment,
            "hljs-name": tag,
            "hljs-quote": tag,
            "hljs-tag": tag,
            "hljs-selector-tag": tag,
            "hljs-selector-pseudo": tag,
            "hljs-addition": add,
            "hljs-deletion": del,
        ]
    }()

    private static func resolveTokenColor(
        className: String,
        palette: [String: NSColor],
        fallback: NSColor
    ) -> NSColor {
        let parts = className.split(separator: " ").map(String.init)
        guard let first = parts.first else { return fallback }
        if parts.count > 1 {
            let composite = first + "." + parts.dropFirst().joined(separator: ".")
            if let color = palette[composite] { return color }
        }
        for part in parts {
            if let color = palette[part] { return color }
        }
        return fallback
    }

    /// 直接解析 highlight.js 输出的 `<span>` 序列为带固定字体/行高/前景色的 NSAttributedString。
    /// 不经过 WebKit HTML 导入器，不丢失任何前导缩进、空格或空行。
    private static func renderSpanHTML(_ html: String, dark: Bool) -> NSAttributedString {
        let palette = dark ? darkPalette : lightPalette
        let defaultColor = NookClip.nsCodeText
        let baseAttrs = CodeTypography.baseAttributes
        let result = NSMutableAttributedString()
        var colorStack: [NSColor] = [defaultColor]
        let utf8 = Array(html.utf8)
        let count = utf8.count
        var index = 0
        var textBuffer: [UInt8] = []
        textBuffer.reserveCapacity(min(count, 4096))

        func flushBuffer() {
            guard !textBuffer.isEmpty else { return }
            let str = String(decoding: textBuffer, as: UTF8.self)
            var attrs = baseAttrs
            attrs[.foregroundColor] = colorStack.last ?? defaultColor
            result.append(NSAttributedString(string: str, attributes: attrs))
            textBuffer.removeAll(keepingCapacity: true)
        }

        while index < count {
            let byte = utf8[index]
            if byte == UInt8(ascii: "<") {
                // 匹配 `<span ...>`
                if index + 5 < count,
                   utf8[index + 1] == UInt8(ascii: "s"),
                   utf8[index + 2] == UInt8(ascii: "p"),
                   utf8[index + 3] == UInt8(ascii: "a"),
                   utf8[index + 4] == UInt8(ascii: "n"),
                   (utf8[index + 5] == UInt8(ascii: " ") || utf8[index + 5] == UInt8(ascii: ">")) {
                    var closeIdx = index + 5
                    while closeIdx < count && utf8[closeIdx] != UInt8(ascii: ">") {
                        closeIdx += 1
                    }
                    if closeIdx < count {
                        flushBuffer()
                        let attrSlice = String(decoding: utf8[(index + 5)..<closeIdx], as: UTF8.self)
                        var tokenColor = colorStack.last ?? defaultColor
                        if let q1 = attrSlice.firstIndex(of: "\""),
                           let q2 = attrSlice[attrSlice.index(after: q1)...].firstIndex(of: "\"") {
                            let cls = String(attrSlice[attrSlice.index(after: q1)..<q2])
                            tokenColor = resolveTokenColor(className: cls, palette: palette, fallback: tokenColor)
                        }
                        colorStack.append(tokenColor)
                        index = closeIdx + 1
                        continue
                    }
                } else if index + 6 < count,
                          utf8[index + 1] == UInt8(ascii: "/"),
                          utf8[index + 2] == UInt8(ascii: "s"),
                          utf8[index + 3] == UInt8(ascii: "p"),
                          utf8[index + 4] == UInt8(ascii: "a"),
                          utf8[index + 5] == UInt8(ascii: "n"),
                          utf8[index + 6] == UInt8(ascii: ">") {
                    flushBuffer()
                    if colorStack.count > 1 {
                        colorStack.removeLast()
                    }
                    index += 7
                    continue
                }
            } else if byte == UInt8(ascii: "&") {
                // highlight.js escapeHTML 仅转义 5 种实体：&amp; &lt; &gt; &quot; &#x27;（兼容 &#39;）
                let limit = min(index + 8, count)
                var semiIdx = index + 1
                while semiIdx < limit && utf8[semiIdx] != UInt8(ascii: ";") {
                    semiIdx += 1
                }
                if semiIdx < limit && utf8[semiIdx] == UInt8(ascii: ";") {
                    let entity = String(decoding: utf8[(index + 1)..<semiIdx], as: UTF8.self)
                    var decoded: UInt8?
                    switch entity {
                    case "lt": decoded = UInt8(ascii: "<")
                    case "gt": decoded = UInt8(ascii: ">")
                    case "amp": decoded = UInt8(ascii: "&")
                    case "quot": decoded = UInt8(ascii: "\"")
                    case "#x27", "#39", "apos": decoded = UInt8(ascii: "'")
                    default: break
                    }
                    if let decoded {
                        textBuffer.append(decoded)
                        index = semiIdx + 1
                        continue
                    }
                }
            }
            textBuffer.append(byte)
            index += 1
        }
        flushBuffer()
        return result
    }

    // MARK: - 超时看门狗（JS 在 actor 上执行，不响应取消；到点弃结果即可）

    private struct TimeoutError: Error {}

    private static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }
            guard let first = try await group.next() else { throw TimeoutError() }
            group.cancelAll()
            return first
        }
    }

    // MARK: - LRU 维护（主线程调用）

    private static func touch(_ key: CacheKey) {
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }

    private static func store(_ key: CacheKey, _ value: Outcome) {
        cache[key] = value
        touch(key)
        while order.count > cacheLimit {
            cache[order.removeFirst()] = nil
        }
    }
}
