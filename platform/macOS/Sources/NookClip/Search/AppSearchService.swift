import AppKit
import Foundation

// MARK: - 应用数据模型

public struct InstalledApp: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let bundleIdentifier: String?
    public let path: String
    public let url: URL
    public let englishName: String
    public let pinyinFull: String
    public let pinyinInitials: String

    public init(
        id: String,
        name: String,
        bundleIdentifier: String? = nil,
        path: String,
        url: URL,
        englishName: String? = nil,
        pinyinFull: String? = nil,
        pinyinInitials: String? = nil
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.path = path
        self.url = url
        let rawEng = englishName ?? url.deletingPathExtension().lastPathComponent
        self.englishName = rawEng
        if let pinyinFull, let pinyinInitials {
            self.pinyinFull = pinyinFull
            self.pinyinInitials = pinyinInitials
        } else {
            let py = PinyinHelper.transform(text: name)
            self.pinyinFull = py.full
            self.pinyinInitials = py.initials
        }
    }
}

// MARK: - 拼音提取转换器

public enum PinyinHelper {
    public static func transform(text: String) -> (full: String, initials: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", "") }
        // 纯 ASCII 名称快路：直接按分词提取全拼与首字母，不触发底层 libicucore 汉字转拼音表加载（省 ~2.7MB 堆内存）
        if trimmed.utf8.allSatisfy({ $0 < 0x80 }) {
            let lower = trimmed.lowercased()
            let words = lower.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)).filter { !$0.isEmpty }
            let full = words.joined()
            let initials = String(words.compactMap { $0.first })
            return (full, initials)
        }
        let mutableString = NSMutableString(string: trimmed)
        CFStringTransform(mutableString, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutableString, nil, kCFStringTransformStripDiacritics, false)
        let latin = (mutableString as String).lowercased()
        let words = latin.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)).filter { !$0.isEmpty }
        let full = words.joined()
        let initials = String(words.compactMap { $0.first })
        return (full, initials)
    }
}

// MARK: - 匹配算法与打分

public enum AppMatchScore {
    public static func score(app: InstalledApp, query: String) -> Int {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return 0 }
        let nameLower = app.name.lowercased()
        let engLower = app.englishName.lowercased()

        // 1. 完全匹配
        if nameLower == q || engLower == q {
            return 1000
        }
        // 2. 名称前缀匹配
        if nameLower.hasPrefix(q) {
            return 900
        }
        if engLower.hasPrefix(q) {
            return 850
        }
        // 3. 拼音首字母简拼完全匹配 (如 wx == wx)
        if app.pinyinInitials == q {
            return 800
        }
        // 4. 拼音首字母简拼前缀匹配 (如 w 匹配 wx)
        if app.pinyinInitials.hasPrefix(q) {
            return 750
        }
        // 5. 拼音全拼完全匹配 (如 weixin)
        if app.pinyinFull == q {
            return 700
        }
        // 6. 拼音全拼前缀匹配 (如 wei 匹配 weixin)
        if app.pinyinFull.hasPrefix(q) {
            return 650
        }
        // 7. 包含匹配
        if nameLower.contains(q) {
            return 500
        }
        if engLower.contains(q) {
            return 450
        }
        if app.pinyinFull.contains(q) {
            return 300
        }
        if app.pinyinInitials.contains(q) && q.count > 1 {
            return 200
        }
        return 0
    }
}

// MARK: - 应用提供者协议与系统实现

public protocol AppSearchProvider: Sendable {
    func loadApplications() -> [InstalledApp]
    func openApp(_ app: InstalledApp) -> Bool
}

public struct DefaultAppSearchProvider: AppSearchProvider {
    public init() {}

    public func loadApplications() -> [InstalledApp] {
        let candidateDirs = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications"
        ]
        var apps: [InstalledApp] = []
        var seenIDs: Set<String> = []

        for dir in candidateDirs {
            let dirURL = URL(fileURLWithPath: dir)
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in contents where url.pathExtension == "app" {
                let path = url.path
                // 直接从 Contents/Info.plist 读取轻量元数据字典，避免实例化 Bundle(url:) 污染 CoreFoundation 全局 Bundle 缓存
                let infoURL = url.appendingPathComponent("Contents/Info.plist")
                let infoDict = NSDictionary(contentsOf: infoURL) as? [String: Any]
                let bundleID = infoDict?["CFBundleIdentifier"] as? String
                let id = bundleID ?? path
                if seenIDs.contains(id) { continue }
                seenIDs.insert(id)

                let rawDisplayName = FileManager.default.displayName(atPath: path)
                let cleanedDisplay: String = {
                    if rawDisplayName.lowercased().hasSuffix(".app") {
                        return String(rawDisplayName.dropLast(4))
                    }
                    return rawDisplayName
                }()
                let fallbackFileName = url.deletingPathExtension().lastPathComponent
                let name = !cleanedDisplay.isEmpty
                    ? cleanedDisplay
                    : ((infoDict?["CFBundleDisplayName"] as? String)
                        ?? (infoDict?["CFBundleName"] as? String)
                        ?? fallbackFileName)

                let app = InstalledApp(
                    id: id,
                    name: name,
                    bundleIdentifier: bundleID,
                    path: path,
                    url: url,
                    englishName: fallbackFileName
                )
                apps.append(app)
            }
        }
        return apps
    }

    public func openApp(_ app: InstalledApp) -> Bool {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: config, completionHandler: nil)
        return true
    }
}

// MARK: - 集中检索服务单例

@MainActor
public final class AppSearchService {
    public static let shared = AppSearchService()

    private let provider: any AppSearchProvider
    private var cachedApps: [InstalledApp] = []
    private var isLoaded = false
    private var loadTask: Task<Void, Never>?
    /// 索引构建完成回调（主线程）：让搜索方在按需加载完成后回填结果。
    /// 单槽设计：回调触发后立即清空，避免长期持有外部上下文。
    public var onIndexReady: (() -> Void)?

    public init(provider: any AppSearchProvider = DefaultAppSearchProvider()) {
        self.provider = provider
    }

    /// 按需加载设计：启动与唤起面板时不再提前全量扫描 `/Applications` 与初始化 ICU 拼音表，
    /// 仅当用户在搜索框输入字符触发 `search(query:)` 时毫秒级按需构建索引。
    public func warmUp() {}

    /// 面板收起闲置后释放已缓存的应用列表
    public func clearCache() {
        loadTask?.cancel()
        loadTask = nil
        cachedApps.removeAll()
        isLoaded = false
        onIndexReady = nil
    }

    /// 索引是否已就绪（供调用方决定是否需要等待异步加载）
    public var isIndexReady: Bool { isLoaded }

    /// 触发后台索引构建（若尚未开始）。首字符输入时调用，避免主线程全盘扫描。
    public func ensureIndexLoaded() {
        guard !isLoaded, loadTask == nil else { return }
        loadTask = Task.detached(priority: .utility) { [provider] in
            let apps = provider.loadApplications()
            // 取消后不得把旧索引写回：面板可能已收起并执行过 clearCache
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self.cachedApps = apps
                self.isLoaded = true
                self.loadTask = nil
                let callback = self.onIndexReady
                self.onIndexReady = nil
                callback?()
            }
        }
    }

    /// 同步检索：索引未就绪时当场同步构建（测试与一次性调用沿用此语义）。
    /// 面板热路径请改用 `searchAsync`，避免首次输入在主线程全盘扫描。
    public func search(query: String, limit: Int = 3) -> [InstalledApp] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if !isLoaded {
            // 若已在后台构建，取消后同步构建一次，保证同步接口返回值契约
            loadTask?.cancel()
            loadTask = nil
            cachedApps = provider.loadApplications()
            isLoaded = true
            let callback = onIndexReady
            onIndexReady = nil
            callback?()
        }

        return score(query: trimmed, limit: limit)
    }

    /// 异步检索：索引未就绪时后台构建，期间返回空；构建完成经 onIndexReady 回调刷新。
    public func searchAsync(query: String, limit: Int = 3) -> [InstalledApp] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard isLoaded else {
            ensureIndexLoaded()
            return []
        }
        return score(query: trimmed, limit: limit)
    }

    private func score(query: String, limit: Int) -> [InstalledApp] {
        var scored: [(app: InstalledApp, score: Int)] = []
        for app in cachedApps {
            let s = AppMatchScore.score(app: app, query: query)
            if s > 0 {
                scored.append((app, s))
            }
        }

        scored.sort {
            if $0.score != $1.score {
                return $0.score > $1.score
            }
            return $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending
        }

        return Array(scored.prefix(limit).map(\.app))
    }

    @discardableResult
    public func openApp(_ app: InstalledApp) -> Bool {
        provider.openApp(app)
    }
}
