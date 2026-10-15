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
}
