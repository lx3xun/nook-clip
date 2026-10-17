import Foundation
import CryptoKit
import Security
import OSLog

public final class KeychainCryptoService {
    public static let shared: KeychainCryptoService = {
        // 测试进程隔离：xctest 若直连真实钥匙串，会以 xctest 的二进制指纹创建主密钥，
        // 导致正式 App 永远无法静默读取（曾引发每次复制敏感内容都弹授权窗的缺陷）。
        // 测试一律使用临时文件密钥，不写真实钥匙串。
        if NSClassFromString("XCTestCase") != nil {
            return KeychainCryptoService(
                keyFileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("nook-test-master-key-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: false),
                keychainService: "test.nook.crypto.shared.\(ProcessInfo.processInfo.processIdentifier)",
                keychainBackupEnabled: false
            )
        }
        return KeychainCryptoService()
    }()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.lx3xun.nookclip", category: "KeychainCryptoService")
    private let service: String
    private let account = "master-encryption-key"
    private let keyFileURLOverride: URL?
    private let keychainBackupEnabled: Bool
    private let lock = NSLock()

    private var cachedKey: SymmetricKey?

    private var initializedKey: String { "nook.crypto.initialized.\(service)" }

    private enum KeychainReadResult {
        case found(SymmetricKey)
        case missing
        case unavailable(OSStatus)
    }
    public init() {
        self.service = "com.lx3xun.nookclip.crypto"
        self.keyFileURLOverride = nil
        self.keychainBackupEnabled = true
    }

    /// 测试注入口：隔离密钥文件位置与 Keychain service，避免污染真实用户数据

    internal init(keyFileURL: URL, keychainService: String, keychainBackupEnabled: Bool = true) {
        self.service = keychainService
        self.keyFileURLOverride = keyFileURL
        self.keychainBackupEnabled = keychainBackupEnabled
    }
    /// 获取或创建 AES-256 对称密钥
    ///
    /// 存储策略：0600 密钥文件是运行时唯一密钥来源，存在即用，不触碰钥匙串；
    /// 文件缺失且未初始化时生成新密钥：必须先原子落盘，钥匙串仅作尽力而为的备份。
    public func getOrCreateKey() -> SymmetricKey? {
        lock.lock()
        defer { lock.unlock() }

        if let key = cachedKey {
            return key
        }

        // 文件密钥存在即用：不读钥匙串，杜绝授权弹窗
        if let fileKey = readKeyFromFile() {
            UserDefaults.standard.set(true, forKey: initializedKey)
            cachedKey = fileKey
            return fileKey
        }
        switch readKeyFromKeychain() {
        case .found(let keychainKey):
            return persistAndCache(keychainKey)
        case .unavailable(let status):
            logger.error("Master key cannot be read from Keychain (status \(status)); refusing to replace it")
            return nil
        case .missing:
            guard !UserDefaults.standard.bool(forKey: initializedKey) else {
                logger.error("Previously initialized master key is missing; refusing to create a replacement")
                return nil
            }
        }

        let newKey = SymmetricKey(size: .bits256)
        guard writeKeyToFile(newKey) else {
            logger.error("Failed to persist new master key file; refusing to initialize encryption")
            return nil
        }
        if keychainBackupEnabled, !saveKeyToKeychain(newKey) {
            logger.notice("Keychain backup of master key failed; file key remains authoritative")
        }
        UserDefaults.standard.set(true, forKey: initializedKey)
        cachedKey = newKey
        return newKey
    }

    private func persistAndCache(_ key: SymmetricKey) -> SymmetricKey {
        if writeKeyToFile(key) {
            UserDefaults.standard.set(true, forKey: initializedKey)
        } else {
            logger.error("Master key file write failed; Keychain key still used for this session")
        }
        cachedKey = key
        return key
    }

    private func keysEqual(_ lhs: SymmetricKey, _ rhs: SymmetricKey) -> Bool {
        lhs.withUnsafeBytes { left in
            rhs.withUnsafeBytes { right in
                Data(left) == Data(right)
            }
        }
    }

    /// 加密明文字符串 -> AES-GCM 封装数据
    public func encrypt(text: String) -> Data? {
        guard let key = getOrCreateKey(),
              let data = text.data(using: .utf8) else {
            return nil
        }
        do {
            let sealedBox = try AES.GCM.seal(data, using: key)
            return sealedBox.combined
        } catch {
            logger.error("Encryption failed: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// 解密失败原因：主密钥不可用（密钥文件与钥匙串均无法读取）≠ 密文损坏
    public enum DecryptFailure: Error {
        case keyUnavailable
        case cipherInvalid
    }

    /// 解密 AES-GCM 封装数据 -> 明文字符串（带失败原因）
    public func decryptResult(cipherData: Data) -> Result<String, DecryptFailure> {
        guard let key = getOrCreateKey() else {
            return .failure(.keyUnavailable)
        }
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: cipherData)
            let decryptedData = try AES.GCM.open(sealedBox, using: key)
            guard let text = String(data: decryptedData, encoding: .utf8) else {
                return .failure(.cipherInvalid)
            }
            return .success(text)
        } catch {
            logger.error("Decryption failed: \(error.localizedDescription)")
            return .failure(.cipherInvalid)
        }
    }

    /// 解密 AES-GCM 封装数据 -> 明文字符串（失败返回 nil，不区分原因）
    public func decrypt(cipherData: Data) -> String? {
        try? decryptResult(cipherData: cipherData).get()
    }
    
    // MARK: - Keychain Operations
    
    private func readKeyFromKeychain() -> KeychainReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            return .found(SymmetricKey(data: data))
        }
        if status == errSecItemNotFound {
            return .missing
        }
        return .unavailable(status)
    }
    
    private func saveKeyToKeychain(_ key: SymmetricKey) -> Bool {
        let keyData = key.withUnsafeBytes { Data($0) }

        // 只新增，绝不先删后加（避免覆盖已有密钥导致历史密文无法解密）
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecSuccess {
            return true
        }
        if status == errSecDuplicateItem {
            // 已存在密钥：读回核验一致才视为成功，不覆盖
            if case .found(let existing) = readKeyFromKeychain(), keysEqual(key, existing) {
                return true
            }
            logger.error("Keychain already holds a different master key; refusing to overwrite it")
        } else {
            logger.error("SecItemAdd failed (status \(status))")
        }
        return false
    }

    // MARK: - File Key Operations

    private var keyFileURL: URL {
        if let keyFileURLOverride { return keyFileURLOverride }
        try? FileManager.default.createDirectory(
            at: AppPaths.masterKeyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        return AppPaths.masterKeyURL
    }

    /// 读取 0600 主密钥文件（运行时唯一密钥来源，存在即用）
    private func readKeyFromFile() -> SymmetricKey? {
        let url = keyFileURL
        guard let data = try? Data(contentsOf: url), data.count == 32 else {
            return nil
        }
        return SymmetricKey(data: data)
    }

    /// 密钥原子写入 0600 文件并读回核验（文件创建即为 0600，无权限放松窗口）
    private func writeKeyToFile(_ key: SymmetricKey) -> Bool {
        let url = keyFileURL
        let keyData = key.withUnsafeBytes { Data($0) }
        let tmpURL = url.deletingLastPathComponent()
            .appendingPathComponent(".master_key.tmp.\(UUID().uuidString)")
        do {
            guard FileManager.default.createFile(
                atPath: tmpURL.path,
                contents: keyData,
                attributes: [.posixPermissions: 0o600]
            ) else {
                logger.error("Failed to create master key temp file")
                return false
            }
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(at: tmpURL, to: url)
            guard let readBack = readKeyFromFile(), keysEqual(readBack, key) else {
                logger.error("Master key file read-back verification failed")
                return false
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            logger.error("Failed to write master key file: \(error.localizedDescription)")
            return false
        }
    }

    /// 测试专用：删除注入 service 对应的钥匙串备份条目，避免测试残留
    func deleteKeychainItemForTesting() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
extension KeychainCryptoService: KeyVaultBackupProvider {
    public func readBackupKey() -> KeyVaultReadStatus {
        guard keychainBackupEnabled else { return .missing }
        switch readKeyFromKeychain() {
        case .found(let key):
            let data = key.withUnsafeBytes { Data($0) }
            return .found(keyBytes: data)
        case .missing:
            return .missing
        case .unavailable(let status):
            return .unavailable(errorCode: status)
        }
    }

    public func writeBackupKey(keyBytes: Data) -> Bool {
        guard keychainBackupEnabled else { return true }
        let key = SymmetricKey(data: keyBytes)
        return saveKeyToKeychain(key)
    }
}
