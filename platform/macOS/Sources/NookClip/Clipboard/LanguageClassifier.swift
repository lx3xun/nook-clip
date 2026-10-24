import Foundation

/// 统一代码语言识别器：捕获侧（ClipboardMonitor → metadata.language）与
/// 展示层（ClipboardRowModel / PreviewPane）共用，替代原 CodeDetector 与
/// SmartTitleExtractor 各自为政的两套启发式。
///
/// 算法：词边界关键字 + 字面标记的加权签名打分（内置语言指纹表，无运行时依赖）。
/// 严格置信策略：最高分需过绝对阈值且领先第二名足够幅度，否则不硬猜——
/// 结构上像代码但语言不明 → language 为 nil（UI 显示 Code），纯文本 → 非代码。
///
/// 落库语言 id 一律小写规范名（java/swift/objc/csharp/cpp…），
/// 展示名经 displayName(for:) 映射（Objective-C/C#/C++/JSX…）。
struct LanguageClassifier {
    struct DetectionResult {
        /// 是否代码（含 JSON 与语言不明的结构兜底）
        let isCode: Bool
        /// 规范化小写语言 id；nil = 非代码或语言不明
        let language: String?
        let isJSON: Bool
        let formattedJSON: String?
        let minifiedJSON: String?
    }

    // MARK: - 公开入口

    /// 轻量分类（列表行映射用）：只判定 代码/JSON/语言，
    /// 跳过 JSON 美化与压缩两次重序列化（万级数据首屏映射的关键路径）
    static func classify(text: String) -> DetectionResult {
        detect(text: text, formatJSON: false)
    }

    /// 完整检测（预览区用）：JSON 额外产出美化/压缩两种形态
    static func detect(text: String) -> DetectionResult {
        detect(text: text, formatJSON: true)
    }

    /// 语言 id → 展示名；未知 id 回退首字母大写（存量脏数据兜底）
    static func displayName(for id: String) -> String {
        let key = normalize(id)
        if let name = displayNames[key] { return name }
        return id.capitalized
    }

    /// 任意存量 language 值 → 规范 id（"Swift"→"swift"，未知值小写原样）
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static let displayNames: [String: String] = [
        "java": "Java",
        "kotlin": "Kotlin",
        "swift": "Swift",
        "objc": "Objective-C",
        "python": "Python",
        "javascript": "JavaScript",
        "typescript": "TypeScript",
        "go": "Go",
        "rust": "Rust",
        "c": "C",
        "cpp": "C++",
        "csharp": "C#",
        "ruby": "Ruby",
        "php": "PHP",
        "shell": "Shell",
        "sql": "SQL",
        "html": "HTML",
        "xml": "XML",
        "css": "CSS",
        "dart": "Dart",
        "lua": "Lua",
        "r": "R",
        "scala": "Scala",
        "vb": "VB",
        "matlab": "Matlab",
        "groovy": "Groovy",
        "jsx": "JSX",
        "vue": "Vue",
        "json": "JSON",
        "yaml": "YAML",
        "toml": "TOML",
        "markdown": "Markdown"
    ]

    private static func detect(text: String, formatJSON: Bool) -> DetectionResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            return DetectionResult(isCode: false, language: nil, isJSON: false,
                                   formattedJSON: nil, minifiedJSON: nil)
        }
        let rustResult = classifyTextContent(text: trimmed)
        let isJSON = rustResult.detectedLanguage == "json"
        var pretty: String? = nil
        var minified: String? = nil
        if isJSON, formatJSON,
           let data = trimmed.data(using: .utf8),
           let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []) {
            pretty = (try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) }
            minified = (try? JSONSerialization.data(withJSONObject: jsonObject, options: []))
                .flatMap { String(data: $0, encoding: .utf8) }
        }
        return DetectionResult(
            isCode: rustResult.isCode,
            language: rustResult.detectedLanguage,
            isJSON: isJSON,
            formattedJSON: pretty,
            minifiedJSON: minified
        )
    }
}
