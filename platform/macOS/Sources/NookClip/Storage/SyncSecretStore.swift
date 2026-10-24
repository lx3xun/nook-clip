import Foundation
import os

/// 同步密钥（E2EE 口令、WebDAV 密码）的本地存储：0600 受控文件。
///
/// 为什么不用钥匙串：传统文件钥匙串的访问控制按「二进制 cdhash 白名单」授权，
/// 而本项目是 ad-hoc 签名（没有 Developer ID），每次重新构建 cdhash 都会变，
/// 于是每次启动读取口令都会弹出「NookClip 想要访问钥匙串」的系统授权窗。
/// 主密钥早已按同一思路改成 0600 文件存储（见 `KeychainCryptoService` 与
/// commit 5fc8098），同步口令沿用同一方案即可彻底消除弹窗。
///
/// 安全边界：文件权限 0600、目录 0700，与同目录下的主密钥文件同级。
/// 主密钥文件本身就能解密整个历史库，因此把同步口令放在同一信任级别内并不降低安全性。
final class SyncSecretStore {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.lx3xun.nookclip",
        category: "SyncSecretStore"
    )

    private static let fileName = "sync-secrets.json"

    private let directoryURL: URL
    private let namespace: String?
    private let lock = NSLock()
    private var cache: [String: String]?
    private var didLoad = false

    /// 测试注入用：换目录/换文件名，保证用例之间互不干扰。
    /// - Parameter namespace: 非空时文件名加后缀，用于同一进程内多个引擎实例并存。
    init(directoryURL: URL, namespace: String? = nil) {
        self.directoryURL = directoryURL
        self.namespace = namespace
    }

    private var fileURL: URL {
        guard let namespace, !namespace.isEmpty else {
            return directoryURL.appendingPathComponent(Self.fileName, isDirectory: false)
        }
        let safe = namespace.replacingOccurrences(of: "/", with: "-")
        return directoryURL.appendingPathComponent("\(Self.fileName).\(safe)", isDirectory: false)
    }

    /// 默认位置：`~/Library/Application Support/com.lx3xun.nookclip/Secrets/`。
    ///
    /// 测试进程一律走临时目录，避免污染真实用户的口令文件。
    static func defaultDirectory() -> URL {
        if let override = AppPaths.secretsDirectoryOverride {
            return override
        }
        if NSClassFromString("XCTestCase") != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("nook-test-secrets-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        return AppPaths.secretsDirectory
    }

    // MARK: - 读写

    func value(for account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeededLocked()
        guard let value = cache?[account], !value.isEmpty else { return nil }
        return value
    }

    func setValue(_ value: String?, for account: String) {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeededLocked()
        var dict = cache ?? [:]
        if let value, !value.isEmpty {
            dict[account] = value
        } else {
            dict.removeValue(forKey: account)
        }
        cache = dict
        persistLocked(dict)
    }

    // MARK: - 磁盘落盘

    private func loadIfNeededLocked() {
        guard !didLoad else { return }
        didLoad = true
        guard let data = try? Data(contentsOf: fileURL) else {
            cache = [:]
            return
        }
        guard let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            Self.logger.error("同步密钥文件解析失败，按空处理（不影响历史库解密）")
            cache = [:]
            return
        }
        cache = dict
    }

    /// 原子写：先写临时文件（0600）再 rename，避免写到一半断电留下半截 JSON。
    private func persistLocked(_ dict: [String: String]) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            Self.logger.error("创建同步密钥目录失败: \(error.localizedDescription, privacy: .public)")
            return
        }

        guard let data = try? JSONEncoder().encode(dict) else {
            Self.logger.error("同步密钥序列化失败")
            return
        }

        let tempURL = directoryURL.appendingPathComponent(
            "\(Self.fileName).tmp.\(UUID().uuidString)",
            isDirectory: false
        )
        do {
            try data.write(to: tempURL, options: [.atomic])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
            if fm.fileExists(atPath: fileURL.path) {
                _ = try fm.replaceItemAt(fileURL, withItemAt: tempURL)
            } else {
                try fm.moveItem(at: tempURL, to: fileURL)
            }
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            try? fm.removeItem(at: tempURL)
            Self.logger.error("写入同步密钥文件失败: \(error.localizedDescription, privacy: .public)")
        }
    }
}
