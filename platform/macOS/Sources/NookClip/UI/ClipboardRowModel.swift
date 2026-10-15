import SwiftUI

// MARK: - 展示层适配器（specs/001-new-ui-cutover/data-model.md §2）
// 从持久化模型 ClipboardItem 单向派生原型 UI 所需的展示字段；纯函数、无状态。
// 视觉规格（图标/徽标/来源色）与 nook-swiftui 原型逐项一致（contracts C4）。

/// 行类型（原型 ItemKind 的迁移版）
enum RowKind: Equatable {
    case text
    case image
    case file
    case url
    case code
    case json
    case color
    case sensitive

    /// 行分类图标（主显示瓦片用）：符号与侧边栏类目一致（SidebarCategories defs）
    var categorySymbol: String {
        switch self {
        case .text: return NookClipIcon.Category.text
        case .image: return NookClipIcon.Category.image
        case .file: return NookClipIcon.Category.file
        case .url: return NookClipIcon.Category.url
        case .code: return NookClipIcon.Category.code
        case .json: return NookClipIcon.Category.json
        case .color: return NookClipIcon.Category.color
        case .sensitive: return NookClipIcon.Category.sensitive
        }
    }

    /// 分类专属语义主题色（用于前置瓦片微底板与图标高亮，增强长列表视觉扫视辨识度）
    var tintColor: Color {
        switch self {
        case .text: return NookClip.tintCategoryText
        case .image: return NookClip.tintCategoryImage
        case .file: return NookClip.tintCategoryFile
        case .url: return NookClip.tintCategoryURL
        case .code: return NookClip.tintCategoryCode
        case .json: return NookClip.tintCategoryJSON
        case .color: return NookClip.tintCategoryColor
        case .sensitive: return NookClip.colorSensitive
        }
    }
}

/// 格式徽标胶囊（图片格式 / MD / JSON / 代码语言，同原型 ClipboardItem.Badge + 语言扩展）
enum RowBadge: Equatable {
    case imageFormat(String)   // 灰（PNG/TIFF/JPG…，取载荷文件扩展名）
    case md    // 灰
    case json  // 蓝（强调色）
    case language(String)  // 代码语言（灰）

    var label: String {
        switch self {
        case .imageFormat(let format): return format
        case .md: return "MD"
        case .json: return "JSON"
        case .language(let lang): return LanguageClassifier.displayName(for: lang)
        }
    }

    var isAccent: Bool { self == .json }
}

/// 来源 App 展示模型（原型 SourceApp 的迁移版）
/// 已知应用映射原型主色/图形；未知应用用中性灰兜底（research.md D3）
struct SourceAppModel: Equatable {
    let name: String
    let color: Color
    let symbol: String
    let symbolColor: Color
    let glyphOnLight: Bool
    /// 来源 App 的 bundle ID（用于解析真实应用图标）
    var bundleID: String?

    static func resolve(name: String?, bundleID: String? = nil) -> SourceAppModel {
        let raw = (name ?? "").trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return fallback(name: L10n.tr("source.unknown")) }
        var model = resolveKnown(raw)
        model.bundleID = bundleID?.isEmpty == false ? bundleID : nil
        return model
    }
    /// 原型映射：已知应用主色/图形，未知应用用中性灰兜底（research.md D3）
    private static func resolveKnown(_ raw: String) -> SourceAppModel {
        let known: [String: SourceAppModel] = [
            "Safari": SourceAppModel(name: "Safari", color: NookClip.appColorSafariBg, symbol: NookClipIcon.SourceAppFallback.safari, symbolColor: NookClip.appColorSafariFg, glyphOnLight: true, bundleID: "com.apple.Safari"),
            "Xcode": SourceAppModel(name: "Xcode", color: NookClip.appColorXcode, symbol: NookClipIcon.SourceAppFallback.xcode, symbolColor: .white, glyphOnLight: false, bundleID: "com.apple.dt.Xcode"),
            "微信": SourceAppModel(name: "微信", color: NookClip.appColorWeChat, symbol: NookClipIcon.SourceAppFallback.wechat, symbolColor: .white, glyphOnLight: false, bundleID: "com.tencent.xinWeChat"),
            "WeChat": SourceAppModel(name: "微信", color: NookClip.appColorWeChat, symbol: NookClipIcon.SourceAppFallback.wechat, symbolColor: .white, glyphOnLight: false, bundleID: "com.tencent.xinWeChat"),
            "Figma": SourceAppModel(name: "Figma", color: NookClip.appColorFigma, symbol: NookClipIcon.SourceAppFallback.figma, symbolColor: .white, glyphOnLight: false, bundleID: "com.figma.Desktop"),
            "Finder": SourceAppModel(name: "Finder", color: NookClip.appColorFinder, symbol: NookClipIcon.SourceAppFallback.finder, symbolColor: .white, glyphOnLight: false, bundleID: "com.apple.finder"),
            "Terminal": SourceAppModel(name: "Terminal", color: NookClip.appColorTerminal, symbol: NookClipIcon.SourceAppFallback.terminal, symbolColor: .white, glyphOnLight: false, bundleID: "com.apple.Terminal"),
            "备忘录": SourceAppModel(name: "备忘录", color: NookClip.appColorNotes, symbol: NookClipIcon.SourceAppFallback.notes, symbolColor: .white, glyphOnLight: true, bundleID: "com.apple.Notes"),
            "Notes": SourceAppModel(name: "Notes", color: NookClip.appColorNotes, symbol: NookClipIcon.SourceAppFallback.notes, symbolColor: .white, glyphOnLight: true, bundleID: "com.apple.Notes"),
            "截图": SourceAppModel(name: "截图", color: NookClip.appColorNeutral, symbol: NookClipIcon.SourceAppFallback.screenshot, symbolColor: .white, glyphOnLight: false, bundleID: nil),
            "截圖": SourceAppModel(name: "截圖", color: NookClip.appColorNeutral, symbol: NookClipIcon.SourceAppFallback.screenshot, symbolColor: .white, glyphOnLight: false, bundleID: nil),
            "Screenshot": SourceAppModel(name: "Screenshot", color: NookClip.appColorNeutral, symbol: NookClipIcon.SourceAppFallback.screenshot, symbolColor: .white, glyphOnLight: false, bundleID: nil),
        ]
        if let exact = known[raw] { return exact }
        // 大小写不敏感匹配（来源名可能是 "Safari.app" 等）
        let lowered = raw.lowercased()
        for (key, model) in known where lowered.contains(key.lowercased()) {
            if model.name != raw {
                return SourceAppModel(name: raw, color: model.color, symbol: model.symbol, symbolColor: model.symbolColor, glyphOnLight: model.glyphOnLight, bundleID: model.bundleID)
            }
            return model
        }
        return fallback(name: raw)
    }

    private static func fallback(name: String) -> SourceAppModel {
        SourceAppModel(name: name, color: NookClip.appColorNeutral, symbol: NookClipIcon.SourceAppFallback.fallback, symbolColor: .white, glyphOnLight: false, bundleID: nil)
    }

}

/// 行展示模型：ClipboardItem → 原型 UI 展示字段（纯函数派生）
struct ClipboardRowModel: Identifiable, Equatable {
    let id: UUID
    let kind: RowKind
    let title: String
    let titleMono: Bool
    let summary: String
    let summaryMono: Bool
    let badge: RowBadge?
    let isSensitive: Bool
    let isFavorite: Bool
    let copyCount: Int
    /// 行内时间戳展示用（data-model §2：展示 lastUsedAt）
    /// 同时是 Timeline 分组/排序键（重复复制刷新后归入最新时间组）
    let lastUsedAt: Date
    /// 图片预览「捕获时间」元信息用
    let createdAt: Date
    let source: SourceAppModel
    let colorHex: String?
    let rgbValue: String?
    /// 图片/文件磁盘路径（列表缩略图、预览卡片共用）
    let payloadPath: String?
    /// title 为空时的展示回退（ClipboardItem.fallbackDisplayTitle 构造时缓存）：
    /// 敏感 → 脱敏摘要；文件 → 文件名；图片 → 尺寸；文本/链接 → 内容预览
    let fallbackTitle: String

    /// 派生规则（data-model §2）：
    /// sensitive（isSensitive）> image / file / url（= type）
    /// > json（LanguageClassifier 判定）> code > color（ColorDetector 命中）> text
    init(item: ClipboardItem) {
        id = item.id
        isSensitive = item.isSensitive
        isFavorite = item.isFavorite
        copyCount = item.copyCount
        lastUsedAt = item.lastUsedAt
        createdAt = item.createdAt
        source = SourceAppModel.resolve(name: item.sourceAppName, bundleID: item.sourceAppBundleId)
        title = item.title
        summary = item.summary
        fallbackTitle = item.fallbackDisplayTitle

        var derivedKind: RowKind
        var derivedBadge: RowBadge?
        var derivedTitleMono = false
        var derivedSummaryMono = false
        var derivedColorHex: String?
        var derivedRgb: String?

        if item.isSensitive {
            derivedKind = .sensitive
            derivedTitleMono = true
        } else {
            switch item.type {
            case .image:
                derivedKind = .image
                derivedBadge = Self.imageFormatBadge(path: item.payloadPath)
            case .file:
                // 展示层重分类：单一路径且为图片格式 → 图片分类（缩略图/预览卡按单路径加载，
                // 多文件换行拼接不重分类）。type 仍为 .file，粘贴与去重行为不变
                if Self.isSingleImageFilePath(item.payloadPath) {
                    derivedKind = .image
                    derivedBadge = Self.imageFormatBadge(path: item.payloadPath)
                } else {
                    derivedKind = .file
                    if let firstPath = item.payloadPath?.components(separatedBy: "\n").first,
                       firstPath.lowercased().hasSuffix(".md") {
                        derivedBadge = .md
                    }
                }
            case .url:
                derivedKind = .url
            case .text:
                let metadataLang = item.metadata.language?.trimmingCharacters(in: .whitespaces)
                let hasMetadataLang = !(metadataLang?.isEmpty ?? true)
                let effectiveKind = item.persistedKind

                if effectiveKind == "json" || (hasMetadataLang && LanguageClassifier.normalize(metadataLang!) == "json") {
                    derivedKind = .json
                    derivedBadge = .json
                    derivedTitleMono = true
                    derivedSummaryMono = true
                } else if effectiveKind == "code" || hasMetadataLang {
                    derivedKind = .code
                    derivedBadge = .language(hasMetadataLang ? metadataLang! : "code")
                    derivedTitleMono = true
                    derivedSummaryMono = true
                } else if effectiveKind == "color", let hex = parseColorHex(text: item.summary) {
                    derivedKind = .color
                    derivedColorHex = hex
                    if let hexValue = Color.rgbHexValue(from: hex) {
                        derivedRgb = "\(Int((hexValue >> 16) & 0xFF)), \(Int((hexValue >> 8) & 0xFF)), \(Int(hexValue & 0xFF))"
                    }
                    derivedTitleMono = true
                } else if effectiveKind == "text" {
                    derivedKind = .text
                } else {
                    // Fallback for unsaved in-memory items via Rust FFI
                    let detection = classifyTextContent(text: item.summary)
                    if detection.detectedLanguage == "json" {
                        derivedKind = .json
                        derivedBadge = .json
                        derivedTitleMono = true
                        derivedSummaryMono = true
                    } else if let hex = detection.detectedColorHex {
                        derivedKind = .color
                        derivedColorHex = hex
                        if let hexValue = Color.rgbHexValue(from: hex) {
                            derivedRgb = "\(Int((hexValue >> 16) & 0xFF)), \(Int((hexValue >> 8) & 0xFF)), \(Int(hexValue & 0xFF))"
                        }
                        derivedTitleMono = true
                    } else if detection.isCode {
                        derivedKind = .code
                        derivedBadge = .language(detection.detectedLanguage ?? "code")
                        derivedTitleMono = true
                        derivedSummaryMono = true
                    } else {
                        derivedKind = .text
                    }
                }
            }
        }

        kind = derivedKind
        badge = derivedBadge
        titleMono = derivedTitleMono
        summaryMono = derivedSummaryMono
        colorHex = derivedColorHex
        rgbValue = derivedRgb
        payloadPath = item.payloadPath
    }

    /// 副行展示文本：image 剥离捕获侧拼接的 ` #hash前8位` 尾巴（ClipboardMonitor.swift:193-198），
    /// 其余 kind 原样。原始 summary 与 RowDedup 去重逻辑不动（去重依赖原文）。
    var displaySummary: String {
        guard kind == .image else { return summary }
        return summary.replacingOccurrences(
            of: #" #[0-9a-fA-F]{8}$"#,
            with: "",
            options: .regularExpression
        )
    }

    /// 链接行副行完整 URL 拆分：scheme 前缀 + host（域名强化展示）+ path/query/fragment 尾部，
    /// 三段拼接即完整 URL（副行展示全部内容）。
    /// 解析失败或无 host（纯本机，不抓 favicon）返回 nil，调用方回退纯文本 summary。
    var urlParts: (schemePrefix: String, host: String, remainder: String)? {
        guard kind == .url, let url = URL(string: summary) else { return nil }
        guard let urlHost = url.host, !urlHost.isEmpty else { return nil }
        let schemePrefix = url.scheme.map { $0 + "://" } ?? ""
        // 端口并入 host 展示：URL(string:) 的 host 不含端口，遗漏会让
        // localhost:8080 显示为 localhost（审计 BUG-030）。仅用于副行展示拼接，
        // 三段拼接仍还原完整 URL
        var host = urlHost
        if let port = url.port {
            host += ":\(port)"
        }
        var remainder = url.path
        if let query = url.query, !query.isEmpty { remainder += "?" + query }
        if let fragment = url.fragment, !fragment.isEmpty { remainder += "#" + fragment }
        return (schemePrefix, host, remainder)
    }

    /// 行内色点颜色（色值条目）
    var swatchColor: Color? {
        guard let colorHex else { return nil }
        return Color(hexString: colorHex)
    }

    /// 图片文件扩展名（展示层重分类用，与 FileStore 可渲染格式对齐）
    static let imageFileExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "svg"
    ]

    /// file 条目是否仅含单一路径且为图片格式（多路径换行拼接 → false）
    static func isSingleImageFilePath(_ path: String?) -> Bool {
        guard let path, !path.isEmpty, !path.contains("\n") else { return false }
        let ext = (path as NSString).pathExtension.lowercased()
        return !ext.isEmpty && imageFileExtensions.contains(ext)
    }

    /// 图片格式徽标：取载荷文件扩展名大写（PNG/TIFF/JPG…），无扩展名返回 nil。
    /// 捕获侧图片载荷按实际编码保存（png/tiff），file 重分类的图片按原文件扩展名
    static func imageFormatBadge(path: String?) -> RowBadge? {
        guard let path else { return nil }
        let ext = (path as NSString).pathExtension
        return ext.isEmpty ? nil : RowBadge.imageFormat(ext.uppercased())
    }

    static func map(_ items: [ClipboardItem]) -> [ClipboardRowModel] {
        items.map(ClipboardRowModel.init)
    }
}

// MARK: - 显示层去重（title/summary 视觉重复时单行化）

/// 显示层去重：summary 与 title 视觉重复时单行化（列表行隐藏副行、预览区跳过大标题）。
/// 纯函数、无状态；不改动 ClipboardItem 持久化字段与生成侧逻辑。
enum RowDedup {
    /// 首尾去空白 + 内部连续空白折叠为单个空格 + 以首个换行截断（取首行）
    static func normalize(_ s: String) -> String {
        let firstLine = s.components(separatedBy: .newlines).first ?? ""
        return firstLine.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// 副行与标题是否重复（重复 → 列表行单行化、预览区跳过大标题）
    static func isRedundant(kind: RowKind, title: String, summary: String) -> Bool {
        let t = normalize(title)
        guard !t.isEmpty else { return false }
        let s = normalize(summary)
        switch kind {
        case .text:
            // 短文本逐字重复 / >48 字长文本 / 多行文本首行重复：
            // 副行 lineLimit(1) 下可见内容就是 title
            return s.hasPrefix(t)
        case .url:
            // 副行恒展示完整 URL（scheme + 域名强调色 + 路径），不因 title=host/path 单行化
            return false
        case .sensitive:
            // 生成侧 title = maskedText = summary（ClipboardMonitor 敏感分支），密文逐字重复
            return s == t
        case .image, .file, .json, .code, .color:
            // 构造上不重复，或副行有独立信息：
            // 图片副行含尺寸大小、文件副行含大小 + 完整路径（不再因 title=文件名单行化）
            return false
        }
    }

    /// 单行化后的标题展示文本（仅 text 类且正文比标题长时追加 "…"）
    static func displayTitle(kind: RowKind, title: String, summary: String) -> String {
        guard isRedundant(kind: kind, title: title, summary: summary) else { return title }
        // 用整段 summary（换行折叠为空格，不截断首行）判断正文是否比标题长
        if kind == .text && normalizeFull(summary) != normalize(title) {
            return title + "…"
        }
        return title
    }

    /// 整段空白（含换行）折叠为单个空格，不按行截断
    private static func normalizeFull(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

extension ClipboardRowModel {
    /// 副行与标题是否视觉重复（列表行/预览区共用判定）
    var isSubtitleRedundant: Bool {
        // title 为空时标题位展示的是回退文本（内容预览/脱敏摘要/尺寸），
        // 副行必与之重复 → 单行化；file 回退的是文件名，副行仍有
        // 路径/大小独立信息，保持双行
        if title.isEmpty { return kind != .file }
        return RowDedup.isRedundant(kind: kind, title: title, summary: summary)
    }

    /// 单行化后的标题展示文本
    var displayTitle: String {
        // 空 title → 展示层回退（不落库）：敏感 → 脱敏摘要；文件 → 文件名；
        // 图片 → 尺寸；文本/链接 → 内容预览
        if title.isEmpty { return fallbackTitle }
        return RowDedup.displayTitle(kind: kind, title: title, summary: summary)
    }

}

// MARK: - 相对时间格式化（原型 MockData.timeString 的去 Mock 迁移版）

enum RelativeTime {
    static func string(from date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return L10n.tr("time.just_now") }
        if minutes < 60 { return L10n.tr("time.minutes_ago", minutes) }
        if calendar.isDate(date, inSameDayAs: now) { return L10n.tr("time.today", clock(date)) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return L10n.tr("time.yesterday", clock(date)) }
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        let year = calendar.component(.year, from: date)
        if year == calendar.component(.year, from: now) {
            return L10n.tr("time.month_day", month, day, clock(date))
        }
        return L10n.tr("time.full_date", String(year), month, day)
    }

    private static func clock(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

// MARK: - 侧边栏分类（原型 MockData.categories 的去 Mock 迁移版）
// 类型类目按需出现（计数 0 自动隐藏）；全部/收藏常驻。

struct SidebarCategory: Identifiable, Equatable {
    let id: Int
    let name: String
    let symbol: String
    let count: Int

    /// 计数展示格式：超过 1000 采用 k 缩写（如 1000 -> 1k, 1094 -> 1.1k, 10000 -> 10k）
    var formattedCount: String {
        Self.formatCount(count)
    }

    static func formatCount(_ count: Int) -> String {
        guard count >= 1000 else { return "\(count)" }
        let thousands = Double(count) / 1000.0
        if thousands >= 100 {
            return "\(Int(thousands))k"
        }
        let formatted = String(format: "%.1f", thousands)
        if formatted.hasSuffix(".0") {
            return "\(Int(Double(formatted) ?? thousands))k"
        }
        return "\(formatted)k"
    }
    var tintColor: Color {
        switch id {
        case 0: return NookClip.accent
        case 8: return NookClip.colorFavorite
        case 1: return NookClip.tintCategoryText
        case 2: return NookClip.tintCategoryImage
        case 3: return NookClip.tintCategoryFile
        case 4: return NookClip.tintCategoryURL
        case 5: return NookClip.tintCategoryCode
        case 6: return NookClip.tintCategoryColor
        case 7: return NookClip.colorSensitive
        default: return NookClip.accent
        }
    }
}

enum SidebarCategories {
    static func categories(for items: [ClipboardRowModel]) -> [SidebarCategory] {
        // (id, 名称, 符号, 是否常驻) —— 名称/符号与原型 MockData.categories 一致；
        // 顺序按用户要求收藏紧随「全部」（id 不变，选中逻辑/快捷键不受影响）
        // 性能：单遍计数（此前每个类目各扫一遍全量数据，万级数据 = 10 万次比较）
        let defs: [(Int, String, String, Bool)] = [
            (0, L10n.tr("category.all"), NookClipIcon.Nav.all, true),
            (8, L10n.tr("category.favorite"), NookClipIcon.Action.favoriteFilled, true),
            (1, L10n.tr("category.text"), NookClipIcon.Category.text, false),
            (2, L10n.tr("category.image"), NookClipIcon.Category.image, false),
            (3, L10n.tr("category.file"), NookClipIcon.Category.file, false),
            (4, L10n.tr("category.link"), NookClipIcon.Category.url, false),
            (5, L10n.tr("category.code"), NookClipIcon.Category.code, false),
            (6, L10n.tr("category.color"), NookClipIcon.Category.color, false),
            (7, L10n.tr("category.sensitive"), NookClipIcon.Category.sensitive, false),
        ]
        var counts = [Int](repeating: 0, count: 9)
        for item in items {
            counts[0] += 1
            switch item.kind {
            case .text: counts[1] += 1
            case .image: counts[2] += 1
            case .file: counts[3] += 1
            case .url: counts[4] += 1
            case .code, .json: counts[5] += 1
            case .color: counts[6] += 1
            case .sensitive: counts[7] += 1
            }
            if item.isFavorite { counts[8] += 1 }
        }
        var result: [SidebarCategory] = []
        result.reserveCapacity(defs.count)
        for def in defs where def.3 || counts[def.0] > 0 {
            result.append(SidebarCategory(id: def.0, name: def.1, symbol: def.2, count: counts[def.0]))
        }
        return result
    }

    /// 从全历史真实聚合计数构造侧边栏分类（解耦自列表内存行）
    static func categories(from counts: CategoryCounts) -> [SidebarCategory] {
        let defs: [(Int, String, String, Bool, UInt64)] = [
            (0, L10n.tr("category.all"), NookClipIcon.Nav.all, true, counts.total),
            (8, L10n.tr("category.favorite"), NookClipIcon.Action.favoriteFilled, true, counts.favorite),
            (1, L10n.tr("category.text"), NookClipIcon.Category.text, false, counts.text),
            (2, L10n.tr("category.image"), NookClipIcon.Category.image, false, counts.image),
            (3, L10n.tr("category.file"), NookClipIcon.Category.file, false, counts.file),
            (4, L10n.tr("category.link"), NookClipIcon.Category.url, false, counts.url),
            (5, L10n.tr("category.code"), NookClipIcon.Category.code, false, counts.code),
            (6, L10n.tr("category.color"), NookClipIcon.Category.color, false, counts.color),
            (7, L10n.tr("category.sensitive"), NookClipIcon.Category.sensitive, false, counts.sensitive),
        ]
        var result: [SidebarCategory] = []
        result.reserveCapacity(defs.count)
        for def in defs where def.3 || def.4 > 0 {
            result.append(SidebarCategory(id: def.0, name: def.1, symbol: def.2, count: Int(def.4)))
        }
        return result
    }

    /// 选中类目若已被动态隐藏（计数为 0），回落到「全部」
    static func effectiveCategoryID(_ id: Int, in items: [ClipboardRowModel]) -> Int {
        categories(for: items).contains { $0.id == id } ? id : 0
    }

    /// 分类 id → 条目匹配（侧边栏点击过滤用，与计数同源）
    static func matchesCategory(_ id: Int, _ item: ClipboardRowModel) -> Bool {
        switch id {
        case 0: return true
        case 1: return item.kind == .text
        case 2: return item.kind == .image
        case 3: return item.kind == .file
        case 4: return item.kind == .url
        case 5: return item.kind == .code || item.kind == .json
        case 6: return item.kind == .color
        case 7: return item.kind == .sensitive
        case 8: return item.isFavorite
        default: return true
        }
    }
}
// MARK: - 分类自定义排序（手动序）

/// 手动序以 UserDefaults 存整份 id 序（`customCategoryOrder`，逗号分隔；空 = 自动数量序）。
/// 「全部」恒居首位不可重排，「收藏」可重排（自动序下仍默认居第 2 位）。
/// 序对全部 id 生效：计数为 0 被隐藏的分类保留序位，重新出现时归位而非追加队尾。
/// 纯函数集合，便于单测；MainView 持有存储并接线。
enum CategoryOrdering {
    /// 可重排分类 id（收藏 8 + 7 个类型类目；全部 0 固定首位不参与）
    static let reorderableIDs: [Int] = [8, 1, 2, 3, 4, 5, 6, 7]

    /// 解析存储序：过滤非法 id、去重；空或清洗后为空 → nil（自动序）
    static func parse(_ raw: String) -> [Int]? {
        let ids = raw.split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { reorderableIDs.contains($0) }
        var seen = Set<Int>()
        let unique = ids.filter { seen.insert($0).inserted }
        return unique.isEmpty ? nil : unique
    }

    /// 序列化（过滤非法 id；空序 → 空串 = 自动序）
    static func serialize(_ order: [Int]) -> String {
        var seen = Set<Int>()
        return order
            .filter { reorderableIDs.contains($0) && seen.insert($0).inserted }
            .map(String.init)
            .joined(separator: ",")
    }

    /// 生效序：存储序在前，未收录的可见 id 补中，其余（隐藏中）按默认序补尾。
    /// 自动序（stored = nil）下即「可见数量序 + 隐藏类目默认序」，首次拖拽由此切入手动序
    static func effectiveOrder(stored: [Int]?, visible: [Int]) -> [Int] {
        let base = stored ?? []
        var order = base + visible.filter { !base.contains($0) }
        order += reorderableIDs.filter { !order.contains($0) }
        return order
    }

    /// 应用序到分类列表：「全部」首位 + 按序排列；未收录者保持传入相对序补尾（兜底）
    static func apply(_ order: [Int], to categories: [SidebarCategory]) -> [SidebarCategory] {
        let byID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        var result: [SidebarCategory] = []
        result.reserveCapacity(categories.count)
        var placed: Set = [0]
        if let all = byID[0] { result.append(all) }
        for id in order where !placed.contains(id) {
            if let category = byID[id] {
                result.append(category)
                placed.insert(id)
            }
        }
        result += categories.filter { !placed.contains($0.id) }
        return result
    }

    /// 拖拽重排：把 dragging 移到 target 之前。已紧邻其前时原样返回
    /// （防止拖拽悬停时 dropEntered 反复触发的来回振荡）
    static func reorder(_ order: [Int], dragging: Int, before target: Int) -> [Int] {
        guard dragging != target,
              let from = order.firstIndex(of: dragging),
              let to = order.firstIndex(of: target),
              to != from + 1 else { return order }
        var result = order
        result.remove(at: from)
        result.insert(dragging, at: to > from ? to - 1 : to)
        return result
    }

    /// 选中类目是否被此次重排挤出可见条（条 = 可见序前 5 位，含「全部」恒居首）。
    /// 仅当原本在条内、重排后落到条外时为 true——第 4 槽的「选中项占槽」规则
    /// 会让被拖走的选中类目继续钉在槽上，过滤像是没变；此时应回落「全部」。
    /// 原本就在条外的深位选中（下拉点选/Tab 循环）不受重排影响，保持原样
    static func selectionPushedOutOfBar(
        oldVisible: [Int],
        newVisible: [Int],
        selected: Int,
        barCount: Int = 5
    ) -> Bool {
        guard selected != 0,
              let oldIndex = oldVisible.firstIndex(of: selected), oldIndex < barCount,
              let newIndex = newVisible.firstIndex(of: selected) else { return false }
        return newIndex >= barCount
    }
}

// MARK: - Color 便捷初始化（"#3B82F6" → Color，原型迁移版）

extension Color {
    init(hexString: String) {
        self.init(hex: Color.rgbHexValue(from: hexString) ?? 0)
    }

    /// "#RRGGBB" / "RRGGBB" → 0xRRGGBB
    /// （scanHexInt32 自 macOS 10.15 弃用，改用 scanInt32(representation:)）
    static func rgbHexValue(from hexString: String) -> UInt32? {
        let cleaned = hexString.replacingOccurrences(of: "#", with: "")
        guard let value = Scanner(string: cleaned).scanInt32(representation: .hexadecimal) else {
            return nil
        }
        return UInt32(bitPattern: value)
    }
}

