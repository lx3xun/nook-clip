import Foundation

/// 云端同步目录的文件读写：items / assets / tombstones 的 JSON 与图片资产，
/// 以及 Security-Scoped Bookmark 对应的目录访问。
/// 只负责文件操作与目录解析，不决定某条记录是否应该被接受、覆盖或清理。
final class CloudFileRepository {
    let fileManager = FileManager.default

    private let defaults: UserDefaults
    private var explicitBaseDirectoryURL: URL?
    private let securityScopeLock = NSLock()
    /// 当前已 startAccessing 的安全作用域目录（与 stopAccessing 严格配对，
    /// 避免每次解析 bookmark 泄漏一次作用域）
    private var securityScopedBaseURL: URL?

    private let bookmarkKey = "iCloudSyncDirectoryBookmark"
    private let customPathKey = "iCloudSyncDirectoryCustomPath"

    init(defaults: UserDefaults, customBaseURL: URL? = nil) {
        self.defaults = defaults
        self.explicitBaseDirectoryURL = customBaseURL
    }

    // MARK: - 目录解析与安全作用域

    var hasExplicitBaseDirectoryURL: Bool {
        explicitBaseDirectoryURL != nil
    }

    var defaultICloudDirectoryURL: URL {
        let home = fileManager.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/NookClip", isDirectory: true)
    }

    var customLocalDirectoryURL: URL {
        if let bookmarkData = defaults.data(forKey: bookmarkKey) {
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                beginSecurityScope(for: resolved)
                return resolved
            }
        }
        if let customPath = defaults.string(forKey: customPathKey), !customPath.isEmpty {
            return URL(fileURLWithPath: customPath, isDirectory: true)
        }
        let home = fileManager.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Documents/NookClipSync", isDirectory: true)
    }

    /// 当前配置的同步根目录（显式指定 > 安全书签 > 自定义路径 > 默认 iCloud 目录）
    var baseDirectoryURL: URL {
        if let explicit = explicitBaseDirectoryURL {
            return explicit
        }
        // 1. 尝试从 Security-Scoped Bookmark 解析
        if let bookmarkData = defaults.data(forKey: bookmarkKey) {
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                beginSecurityScope(for: resolved)
                return resolved
            }
        }
        // 2. 尝试从自定义路径读取
        if let customPath = defaults.string(forKey: customPathKey), !customPath.isEmpty {
            return URL(fileURLWithPath: customPath, isDirectory: true)
        }
        // 3. 默认 iCloud Drive/NookClip 目录
        return defaultICloudDirectoryURL
    }
    var assetsDirectoryURL: URL {
        baseDirectoryURL.appendingPathComponent("assets", isDirectory: true)
    }

    var devicesDirectoryURL: URL {
        baseDirectoryURL.appendingPathComponent("devices", isDirectory: true)
    }

    /// 开始持有安全作用域：同一 URL 只 start 一次；切换目录时先释放旧作用域，保证 start/stop 严格配对
    private func beginSecurityScope(for url: URL) {
        securityScopeLock.lock()
        defer { securityScopeLock.unlock() }
        guard url != securityScopedBaseURL else { return }
        releaseSecurityScopeLocked()
        if url.startAccessingSecurityScopedResource() {
            securityScopedBaseURL = url
        }
    }

    /// 释放当前持有的安全作用域（与 beginSecurityScope 配对；deinit 时兜底调用）
    func releaseSecurityScope() {
        securityScopeLock.lock()
        defer { securityScopeLock.unlock() }
        releaseSecurityScopeLocked()
    }

    private func releaseSecurityScopeLocked() {
        securityScopedBaseURL?.stopAccessingSecurityScopedResource()
        securityScopedBaseURL = nil
    }

    // MARK: - 目录配置

    /// 切换自定义同步目录：保存 bookmark 与路径、释放旧作用域并确保目录存在。
    /// 观测快照清理与目录监听重启由调用方（引擎）负责。
    func setCustomDirectory(_ url: URL) throws {
        // 保存 security-scoped bookmark
        let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        if let bookmark {
            defaults.set(bookmark, forKey: bookmarkKey)
        }
        defaults.set(url.path, forKey: customPathKey)
        releaseSecurityScope()
        try ensureDirectoriesExist()
    }

    /// 恢复默认同步目录（清除 bookmark 与自定义路径）
    func resetToDefaultDirectory() {
        defaults.removeObject(forKey: bookmarkKey)
        defaults.removeObject(forKey: customPathKey)
        explicitBaseDirectoryURL = nil
        releaseSecurityScope()
        try? ensureDirectoriesExist()
    }

    func ensureDirectoriesExist() throws {
        let dirs = [devicesDirectoryURL, assetsDirectoryURL]
        for dir in dirs {
            if !fileManager.fileExists(atPath: dir.path) {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
    }
}
