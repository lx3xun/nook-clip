import Foundation

public enum ClipboardItemType: String, CaseIterable, Codable, Sendable {
    case text, image, file, url
}

public struct ClipboardItem: Identifiable, Equatable, Codable {
    public let id: UUID
    public var type: ClipboardItemType
    public var title: String
    public var summary: String
    public let createdAt: Date
    public var lastUsedAt: Date
    public var copyCount: Int
    public var isFavorite: Bool
    public let payloadPath: String?
    public var ocrText: String?
    public var sourceAppBundleId: String?
    public var sourceAppName: String?
    public var isSensitive: Bool
    public var sourceDeviceId: String? = nil
    public var sourceDeviceName: String? = nil
    public var sourcePlatform: String? = nil
    public var encryptedContent: Data?
    /// Rust 引擎按需解密取回的敏感明文（仅 item(id:) 全文路径填充，不序列化、不进列表镜像，消除客户端二次加密）
    public var decryptedPlainText: String? = nil
    public var metadata: ClipboardMetadata
    /// 软删除时间（nil = 活跃条目；非 nil = 撤销窗口内，过期按宽限彻底清除）
    public var deletedAt: Date?
    /// 列表查询只载入 summary 前缀（内存上限，见 RustHistoryStore.summaryPrefixLimit）：
    /// 截断副本不得直接写入剪贴板或回存数据库
    public var summaryIsTruncated: Bool = false
    /// 存储层持久化的规范分类（text / image / file / url / code / json / color / sensitive）
    public var persistedKind: String? = nil
    /// 轻量标签（归一化后的展示字符串，按 created_at 升序）。空 = 无标签。
    public var tags: [String] = []

    private enum CodingKeys: String, CodingKey {
        case id, type, title, summary, createdAt, lastUsedAt, copyCount, isFavorite
        case payloadPath, ocrText, sourceAppBundleId, sourceAppName, isSensitive
        case sourceDeviceId, sourceDeviceName, sourcePlatform
        case encryptedContent, metadata, deletedAt, summaryIsTruncated, persistedKind
        case tags
    }

    /// 敏感明文查看失败原因：钥匙串授权被拒 ≠ 密文损坏
    public enum RevealFailure: Error {
        case keyUnavailable
        case decryptFailed
    }

    /// 带失败原因的明文查看（仅预览区区分提示文案用）：
    /// 优先直接读取 Rust 引擎解密的 `decryptedPlainText`（零客户端重加密）；
    /// 兼容未落库临时条目或旧测试注入的 `encryptedContent`。
    func revealPlainContentResult(crypto: any CryptoService = KeychainCryptoService.shared) -> Result<String, RevealFailure> {
        guard isSensitive else { return .success(summary) }
        if let plain = decryptedPlainText {
            return .success(plain)
        }
        guard let cipher = encryptedContent else { return .failure(.decryptFailed) }
        switch crypto.decryptResult(cipherData: cipher) {
        case .success(let text):
            return .success(text)
        case .failure(.keyUnavailable):
            return .failure(.keyUnavailable)
        case .failure(.cipherInvalid):
            return .failure(.decryptFailed)
        }
    }

    func revealPlainContent(crypto: any CryptoService = KeychainCryptoService.shared) -> String? {
        try? revealPlainContentResult(crypto: crypto).get()
    }

    /// T050（FR-026）：播种脚本（scripts/seed-promo-data.swift）校验敏感条目
    /// 可解密的公开只读入口（crypto 参数类型为模块内部协议，无法直接公开）
    public func revealPlainContent() -> String? {
        revealPlainContent(crypto: KeychainCryptoService.shared)
    }
    /// 仅空白（空格/换行/制表符）的文本或 URL：复制空选择产生的脏数据，不应入库展示
    public var isBlankText: Bool {
        guard !isSensitive, type == .text || type == .url else { return false }
        return summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public init(
        id: UUID = UUID(),
        type: ClipboardItemType,
        title: String,
        summary: String,
        createdAt: Date = .now,
        lastUsedAt: Date = .now,
        copyCount: Int = 1,
        isFavorite: Bool = false,
        payloadPath: String? = nil,
        ocrText: String? = nil,
        sourceAppBundleId: String? = nil,
        sourceAppName: String? = nil,
        isSensitive: Bool = false,
        sourceDeviceId: String? = nil,
        sourceDeviceName: String? = nil,
        sourcePlatform: String? = nil,
        encryptedContent: Data? = nil,
        metadata: ClipboardMetadata = ClipboardMetadata(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.summary = summary
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.copyCount = max(1, copyCount)
        self.isFavorite = isFavorite
        self.payloadPath = payloadPath
        self.ocrText = ocrText
        self.sourceAppBundleId = sourceAppBundleId
        self.sourceAppName = sourceAppName
        self.isSensitive = isSensitive
        self.sourceDeviceId = sourceDeviceId
        self.sourceDeviceName = sourceDeviceName
        self.sourcePlatform = sourcePlatform
        self.encryptedContent = encryptedContent
        self.metadata = metadata
        self.deletedAt = deletedAt
    }

    /// title 为空时的展示回退（纯展示层派生，不落库、不进 FTS、不同步）：
    /// 敏感 → 脱敏摘要（捕获侧 summary 即掩码文本，空则「敏感凭证」占位）；
    /// 文件 → 文件名（payloadPath 派生，多文件带数量）；图片 → 尺寸摘要
    /// （剥离捕获侧拼接的 ` #hash` 尾巴）；文本/链接 → 内容预览（summary）。
    /// 与已删除的 defaultTitle 的区别：不再为文本/代码/链接推断标题——
    /// 捕获即置空，仅展示时回退。
    public var fallbackDisplayTitle: String {
        if isSensitive {
            return summary.isEmpty ? L10n.tr("item.type_sensitive") : summary
        }
        switch type {
        case .text, .url:
            return summary
        case .image:
            let display = summary.replacingOccurrences(
                of: #" #[0-9a-fA-F]{8}$"#,
                with: "",
                options: .regularExpression
            )
            return display.isEmpty ? L10n.tr("item.type_image") : display
        case .file:
            if let path = payloadPath, !path.isEmpty {
                let components = path.components(separatedBy: "\n").filter { !$0.isEmpty }
                if components.count > 1 {
                    return L10n.tr("item.file_multi_title", (components[0] as NSString).lastPathComponent, components.count)
                }
                return (path as NSString).lastPathComponent
            }
            return summary
        }
    }
}
