import AppKit
import Foundation

// MARK: - 依赖协议
// 小接口原则：只覆盖被多个层消费、且有测试替身价值的依赖面；
// 不为展示架构意图抽象只有一个实现且无法注入替身的 AppKit API。

/// 条目载荷文件的存取与清理（落盘数据、受管路径判定）。
/// 预览用的缩略图/全图缓存不属于本协议。
protocol PayloadStore: AnyObject {
    /// 受管载荷根目录（content-addressed）：同步附件池的本地落点
    var directory: URL { get }
    @discardableResult func save(data: Data, preferredExtension: String) throws -> String
    func load(path: String) -> Data?
    func remove(path: String?)
    func isManaged(_ path: String) -> Bool
    /// T054（FR-026，审查 F-1）：本地载荷孤儿对账（仅启动低频调用；
    /// 默认实现为空操作，测试替身按需覆写）
    @discardableResult func sweepOrphans(referencedPaths: Set<String>, olderThan: TimeInterval) -> Int
}

/// 敏感条目 AES-GCM 加解密（含失败原因：密钥不可用 ≠ 密文损坏）
protocol CryptoService: AnyObject {
    func encrypt(text: String) -> Data?
    func decryptResult(cipherData: Data) -> Result<String, KeychainCryptoService.DecryptFailure>
}

/// 系统剪贴板写入出口（PasteService 的抽象面；UI 层禁止直调 NSPasteboard）。
/// @MainActor：唯一实现 PasteService 为 MainActor 隔离，协议同步隔离，
/// 消除「协议非隔离 ↔ 实现隔离」的 Swift 6 数据竞争前瞻警告。
@MainActor
protocol ClipboardWriter: AnyObject {
    @discardableResult func copyOnly(_ item: ClipboardItem, plainTextOnly: Bool) -> Bool
    @discardableResult func copyText(_ text: String, containsSensitive: Bool) -> Bool
    @discardableResult func paste(_ item: ClipboardItem, targetApplication: NSRunningApplication?, plainTextOnly: Bool) -> Bool
    @discardableResult func pasteText(_ text: String, targetApplication: NSRunningApplication?, containsSensitive: Bool) -> Bool
    func clearClipboardIfContent(matches plainText: String)
    func staleFileMessage(for item: ClipboardItem) -> String?
}


// MARK: - 默认实现适配

extension PayloadStore {
    func sweepOrphans(referencedPaths: Set<String>, olderThan: TimeInterval) -> Int { 0 }
}

extension FileStore: PayloadStore {}
extension KeychainCryptoService: CryptoService {}
extension PasteService: ClipboardWriter {}

// MARK: - 依赖容器

/// 应用级依赖组装入口：生产环境用 `.live`（AppDelegate 持有并下发给各组件），
/// 测试按需替换个别依赖实现隔离实例。
/// 说明：不设 SettingsStore 协议——UserDefaults 本身即可注入隔离 suite
/// （见测试 makeIsolatedDefaults），再包一层没有替身价值。
struct AppDependencies {
    let defaults: UserDefaults
    let payloadStore: any PayloadStore
    let cryptoService: any CryptoService
    let clipboardWriter: any ClipboardWriter
    /// 设置 UI 仍需引擎特有 API（setCustomDirectory / baseDirectoryURL），
    /// 因此保留具体类型；协议视角经 syncGateway 暴露
    let syncEngine: ICloudDriveSyncEngine
    let rustHistoryStore: RustHistoryStore
    static let live = AppDependencies()

    private init() {
        defaults = .standard
        payloadStore = FileStore.shared
        cryptoService = KeychainCryptoService.shared
        clipboardWriter = PasteService.shared
        syncEngine = .shared
        if NSClassFromString("XCTestCase") != nil {
            self.rustHistoryStore = try! RustHistoryStore(path: ":memory:", encryptionKey: Data(repeating: 0x42, count: 32))
        } else {
            self.rustHistoryStore = RustHistoryStore.openProduction()
        }
    }

    init(
        defaults: UserDefaults,
        payloadStore: any PayloadStore,
        cryptoService: any CryptoService,
        clipboardWriter: any ClipboardWriter,
        syncEngine: ICloudDriveSyncEngine
    ) {
        self.defaults = defaults
        self.payloadStore = payloadStore
        self.cryptoService = cryptoService
        self.clipboardWriter = clipboardWriter
        self.syncEngine = syncEngine
        if NSClassFromString("XCTestCase") != nil {
            self.rustHistoryStore = try! RustHistoryStore(path: ":memory:", encryptionKey: Data(repeating: 0x42, count: 32))
        } else {
            self.rustHistoryStore = RustHistoryStore.openProduction()
        }
    }
}
