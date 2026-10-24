import Foundation
import OSLog

enum AppPaths {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.lx3xun.nookclip", category: "AppPaths")

    static let appSupportRoot: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.lx3xun.nookclip", isDirectory: true)
    }()

    nonisolated(unsafe) static var databaseURLOverride: URL?

    static var databaseURL: URL {
        if let databaseURLOverride { return databaseURLOverride }
        return appSupportRoot.appendingPathComponent("library.db")
    }

    nonisolated(unsafe) static var contentDirectoryOverride: URL?

    static var contentDirectory: URL {
        if let contentDirectoryOverride { return contentDirectoryOverride }
        return appSupportRoot.appendingPathComponent("Content", isDirectory: true)
    }

    static let masterKeyURL = appSupportRoot.appendingPathComponent(".master_key")

    nonisolated(unsafe) static var secretsDirectoryOverride: URL?

    /// 同步口令（E2EE Passphrase / WebDAV 密码）所在目录。
    ///
    /// 与主密钥同级的 0600 受控文件存放地，不再使用钥匙串：ad-hoc 签名下每次重新
    /// 构建都会改变 cdhash，钥匙串条目的访问控制随之失效，启动读取即弹出授权窗。
    static var secretsDirectory: URL {
        if let secretsDirectoryOverride { return secretsDirectoryOverride }
        return appSupportRoot.appendingPathComponent("Secrets", isDirectory: true)
    }
}
