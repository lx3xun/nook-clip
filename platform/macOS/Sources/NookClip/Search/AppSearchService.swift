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
                let bundle = Bundle(url: url)
                let bundleID = bundle?.bundleIdentifier
                let id = bundleID ?? path
                if seenIDs.contains(id) { continue }
                seenIDs.insert(id)

                let displayName = FileManager.default.displayName(atPath: path)
                let name = (displayName.isEmpty || displayName.hasSuffix(".app"))
                    ? (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                        ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                        ?? url.deletingPathExtension().lastPathComponent)
                    : displayName

                let app = InstalledApp(
                    id: id,
                    name: name,
                    bundleIdentifier: bundleID,
                    path: path,
                    url: url,
                    englishName: url.deletingPathExtension().lastPathComponent
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

    public init(provider: any AppSearchProvider = DefaultAppSearchProvider()) {
        self.provider = provider
    }

    public func warmUp() {
        guard !isLoaded, loadTask == nil else { return }
        loadTask = Task.detached(priority: .userInitiated) { [provider] in
            let loaded = provider.loadApplications()
            await MainActor.run {
                self.cachedApps = loaded
                self.isLoaded = true
                self.loadTask = nil
            }
        }
    }

    public func search(query: String, limit: Int = 3) -> [InstalledApp] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if !isLoaded, loadTask == nil {
            cachedApps = provider.loadApplications()
            isLoaded = true
        }

        var scored: [(app: InstalledApp, score: Int)] = []
        for app in cachedApps {
            let s = AppMatchScore.score(app: app, query: trimmed)
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
