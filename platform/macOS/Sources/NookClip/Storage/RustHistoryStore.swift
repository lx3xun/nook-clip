import Foundation
import OSLog

public class RustHistoryStore: @unchecked Sendable {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.lx3xun.nookclip",
        category: "RustHistoryStore"
    )

    public let engine: NookClipHistoryEngine
    private let queue = DispatchQueue(label: "com.lx3xun.nookclip.rust-history-store", qos: .userInitiated)

    public init(engine: NookClipHistoryEngine) {
        self.engine = engine
    }

    public convenience init(databaseURL: URL, encryptionKey: Data) throws {
        let engine = try NookClipHistoryEngine(
            dbPath: databaseURL.path,
            masterKey: encryptionKey
        )
        self.init(engine: engine)
    }

    /// - Warning: 生产代码不得用固定密钥调用本初始化器；请用
    /// `openProduction(databaseURL:keychain:)`（密钥来自钥匙串并含旧库迁移）。
    public convenience init(path: String = "", encryptionKey: Data) throws {
        if path == ":memory:" {
            let engine = try NookClipHistoryEngine(
                dbPath: ":memory:",
                masterKey: encryptionKey
            )
            self.init(engine: engine)
            return
        }
        let dbURL: URL
        if path.isEmpty {
            try? FileManager.default.createDirectory(
                at: AppPaths.databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            dbURL = AppPaths.databaseURL
        } else {
            dbURL = URL(fileURLWithPath: path)
        }
        try self.init(databaseURL: dbURL, encryptionKey: encryptionKey)
    }

    /// 生产库唯一打开入口：密钥取自 KeychainCryptoService（0600 密钥文件 +
    /// 钥匙串兜底）。首次运行时把旧版固定密钥（0x42×32）加密的载荷轮换为
    /// 钥匙串密钥（一次性迁移，UserDefaults 标记），失败回退内存库并记日志。
    public static func openProduction(
        databaseURL: URL? = nil,
        keychain: KeychainCryptoService = .shared,
        defaults: UserDefaults = .standard
    ) -> RustHistoryStore {
        let databaseURL = databaseURL ?? AppPaths.databaseURL
        let migrationKey = "nook.db.keychainKeyMigrated"
        guard let key = keychain.getOrCreateKey() else {
            Self.logger.error("KeychainCryptoService 无法提供主密钥，回退内存库（历史不可持久化）")
            return makeMemoryFallbackStore()
        }
        let keyData = key.withUnsafeBytes { Data($0) }
        let fileExists = FileManager.default.fileExists(atPath: databaseURL.path)
        if !defaults.bool(forKey: migrationKey), fileExists {
            // 旧库：用旧固定密钥打开 → rekey 到钥匙串密钥 → 标记完成。
            // 旧密钥打开失败不直接回退内存库：库可能已用钥匙串密钥加密
            // （迁移已发生但标记丢失），下方用钥匙串主密钥重试打开
            do {
                let legacy = Data(repeating: 0x42, count: 32)
                let legacyStore = try RustHistoryStore(databaseURL: databaseURL, encryptionKey: legacy)
                _ = try legacyStore.engine.rekey(newMasterKey: keyData)
            } catch {
                Self.logger.error("旧密钥迁移失败（将尝试钥匙串主密钥直接打开）：\(error.localizedDescription)")
            }
        }
        do {
            let store = try RustHistoryStore(databaseURL: databaseURL, encryptionKey: keyData)
            defaults.set(true, forKey: migrationKey)
            return store
        } catch {
            Self.logger.error("生产库打开/迁移失败，回退内存库：\(error.localizedDescription)")
            return makeMemoryFallbackStore()
        }
    }

    /// 内存库兜底：主密钥不可用或生产库打开失败时的最后手段。
    /// 内存库构造失败意味着应用无法提供任何历史存储，属不可恢复错误——
    /// 带清晰信息 fatalError，不得静默强解包崩溃
    private static func makeMemoryFallbackStore() -> RustHistoryStore {
        let randomKey = Data((0...31).map { _ in UInt8.random(in: 0...255) })
        do {
            return try RustHistoryStore(path: ":memory:", encryptionKey: randomKey)
        } catch {
            Self.logger.error("内存库构造失败：\(error.localizedDescription)")
            fatalError("NookClip 无法创建内存历史库（历史功能不可用）：\(error.localizedDescription)")
        }
    }

    // MARK: - Query & Timeline

    /// - Parameter truncatingSummary: true（默认）= 列表场景只载入前缀；
    /// 导出等需要全文的消费方传 false
    public func page(limit: Int = 1000, offset: Int = 0, truncatingSummary: Bool = true) -> [ClipboardItem] {
        let filter = QueryFilter(
            searchQuery: nil,
            itemType: nil,
            kind: nil,
            favoriteOnly: false,
            includeDeleted: false,
            limit: UInt32(limit),
            offset: UInt32(offset)
        )
        do {
            let summaries = try engine.queryItems(filter: filter)
            return summaries.compactMap { self.toClipboardItem($0, truncatingSummary: truncatingSummary) }
        } catch {
            Self.logger.error("Failed to query page from Rust engine: \(error.localizedDescription)")
            return []
        }
    }

    public func trashItems() -> [ClipboardItem] {
        let filter = QueryFilter(
            searchQuery: nil,
            itemType: nil,
            kind: nil,
            favoriteOnly: false,
            includeDeleted: true,
            limit: 1000,
            offset: 0
        )
        do {
            let summaries = try engine.queryItems(filter: filter)
            return summaries
                .filter { $0.deletedAt != nil }
                .compactMap { self.toClipboardItem($0) }
        } catch {
            Self.logger.error("trashItems query failed: \(error.localizedDescription)")
            return []
        }
    }

    /// 按 id 取单条全文（不截断），主键索引精确查询
    public func item(id: UUID) -> ClipboardItem? {
        let filter = QueryFilter(
            id: id.uuidString,
            searchQuery: nil,
            itemType: nil,
            kind: nil,
            favoriteOnly: false,
            includeDeleted: true,
            limit: 1,
            offset: 0
        )
        let summaries = (try? engine.queryItems(filter: filter)) ?? []
        guard let summary = summaries.first else {
            return nil
        }
        return toClipboardItem(summary, truncatingSummary: false)
    }

    /// 分类映射（search 与时间戳聚合共用）：
    /// 1~7 全部分类均走 ci.kind 派生判定，与 count_categories 和 SidebarCategories 对齐；8 为收藏
    private func makeFilter(query: String, categoryID: Int, limit: Int, offset: Int) -> QueryFilter {
        let kind: String? = {
            switch categoryID {
            case 1: return "text"
            case 2: return "image"
            case 3: return "file"
            case 4: return "url"
            case 5: return "code"
            case 6: return "color"
            case 7: return "sensitive"
            default: return nil
            }
        }()
        return QueryFilter(
            searchQuery: query.isEmpty ? nil : query,
            itemType: nil,
            kind: kind,
            favoriteOnly: categoryID == 8,
            includeDeleted: false,
            limit: UInt32(limit),
            offset: UInt32(offset)
        )
    }

    public func search(query: String, categoryID: Int = 0, limit: Int = 50, offset: Int = 0) -> [ClipboardItem] {
        let filter = makeFilter(query: query, categoryID: categoryID, limit: limit, offset: offset)
        do {
            let summaries = try engine.queryItems(filter: filter)
            return summaries.compactMap { self.toClipboardItem($0) }
        } catch {
            Self.logger.error("Failed to search in Rust engine: \(error.localizedDescription)")
            return []
        }
    }
    /// 全量时间戳聚合：当前筛选下全部命中条目的 last_used_at（降序，秒），
    /// 供时间导航锚点条做全历史时间分组（脱离分页限制）
    public func timeGroupTimestamps(query: String = "", categoryID: Int = 0) -> [Date] {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filter = makeFilter(query: cleanQuery, categoryID: categoryID, limit: 0, offset: 0)
        do {
            let seconds = try engine.timeGroupTimestamps(filter: filter)
            return seconds.map { Date(timeIntervalSince1970: $0) }
        } catch {
            Self.logger.error("Failed to fetch time group timestamps: \(error.localizedDescription)")
            return []
        }
    }

    /// 异步时间戳聚合：串行队列执行，不阻塞主 actor
    public func timeGroupTimestampsAsync(query: String = "", categoryID: Int = 0) async -> [Date] {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(
                    returning: self.timeGroupTimestamps(query: query, categoryID: categoryID)
                )
            }
        }
    }
    /// 异步查询：FFI 调用与逐条映射（metadata JSON 解码、敏感条目 detail 解密）
    /// 为阻塞型 CPU/IO 工作，挪到专属串行队列执行，避免阻塞主 actor 卡 UI
    /// （分类切换需连跑结果集 + 计数集两查，主线程同步执行会明显掉帧）。
    /// 引擎内部以互斥锁保护连接，串行队列只保证查询按提交顺序执行、废弃查询不并行堆积。
    /// 查询结果 + 失败标志：引擎错误不得伪装成空结果（界面需区分
    /// 「无匹配」与「索引不可用」）
    public func searchWithStatus(query: String, categoryID: Int = 0, limit: Int = 50, offset: Int = 0) -> (items: [ClipboardItem], failed: Bool) {
        let filter = makeFilter(query: query, categoryID: categoryID, limit: limit, offset: offset)
        do {
            let summaries = try engine.queryItems(filter: filter)
            return (summaries.compactMap { self.toClipboardItem($0) }, false)
        } catch {
            Self.logger.error("Failed to search in Rust engine: \(error.localizedDescription)")
            return ([], true)
        }
    }

    public func searchAsync(query: String, categoryID: Int = 0, limit: Int = 50, offset: Int = 0) async -> (items: [ClipboardItem], failed: Bool) {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(
                    returning: self.searchWithStatus(query: query, categoryID: categoryID, limit: limit, offset: offset)
                )
            }
        }
    }

    /// 全历史分类统计：按搜索词在 Rust 聚合出全量 9 大分类真实条数
    public func countCategories(query: String = "") -> CategoryCounts {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            return try engine.countCategories(searchQuery: cleanQuery.isEmpty ? nil : cleanQuery)
        } catch {
            Self.logger.error("Failed to count categories in Rust engine: \(error.localizedDescription)")
            return CategoryCounts(total: 0, favorite: 0, text: 0, image: 0, file: 0, url: 0, code: 0, color: 0, sensitive: 0)
        }
    }

    /// 异步分类统计：串行队列执行，不阻塞主 actor
    public func countCategoriesAsync(query: String = "") async -> CategoryCounts {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.countCategories(query: query))
            }
        }
    }

    // MARK: - Mutations

    /// 单条保存。返回持久化后的条目（内容去重合并后的真实 id、copyCount、
    /// createdAt——与库内状态一致，调用方据此增量更新镜像，无需整页重查）；
    /// 保存失败返回 nil，调用方不得变更内存镜像
    @discardableResult
    public func save(_ item: ClipboardItem, rawText: String? = nil) -> ClipboardItem? {
        // 非敏感条目 raw_text 存全文（title 只存捕获值，文本类常为空）；
        // 敏感条目存解密明文供 detail/导出使用（入库前 Rust 侧加密）
        let entry = BatchSaveItem(
            item: ffiSummary(from: item),
            rawText: rawText
                ?? (item.isSensitive ? item.revealPlainContent(crypto: KeychainCryptoService.shared) : nil)
                ?? (item.isSensitive ? item.title : item.summary)
        )
        do {
            let persisted = try engine.saveItems(items: [entry])
            guard let summary = persisted.first else { return nil }
            return toClipboardItem(summary, truncatingSummary: true)
        } catch {
            Self.logger.error("Failed to save item in Rust engine: \(error.localizedDescription)")
            return nil
        }
    }

    /// 批量写入（单事务）：导入/初始化/迁移等批量场景；逐条语义与 save 一致
    /// （内容去重合并、敏感加密、FTS 维护），任一条目失败整体回滚
    @discardableResult
    public func saveBatch(_ items: [ClipboardItem]) -> Bool {
        let entries = items.map { item in
            BatchSaveItem(
                item: ffiSummary(from: item),
                rawText: (item.isSensitive ? item.revealPlainContent(crypto: KeychainCryptoService.shared) : nil)
                    ?? (item.isSensitive ? item.title : item.summary)
            )
        }
        do {
            _ = try engine.saveItems(items: entries)
            return true
        } catch {
            Self.logger.error("Failed to batch save in Rust engine: \(error.localizedDescription)")
            return false
        }
    }

    /// 全部条目载荷路径（孤儿对账用，单列轻量查询）
    public func payloadPaths() -> [String] {
        (try? engine.payloadPaths()) ?? []
    }

    /// ClipboardItem → FFI 记录（字段语义与 save 的参数一致）
    private func ffiSummary(from item: ClipboardItem) -> ClipItemSummary {
        let metadataJson = (try? JSONEncoder().encode(item.metadata)).flatMap { String(data: $0, encoding: .utf8) }
        return ClipItemSummary(
            id: item.id.uuidString,
            itemType: item.type.rawValue,
            title: item.title,
            summary: item.summary,
            createdAt: item.createdAt.timeIntervalSince1970,
            lastUsedAt: item.lastUsedAt.timeIntervalSince1970,
            copyCount: Int64(item.copyCount),
            favorite: item.isFavorite,
            sourceAppBundleId: item.sourceAppBundleId,
            sourceAppName: item.sourceAppName,
            isSensitive: item.isSensitive,
            deletedAt: item.deletedAt?.timeIntervalSince1970,
            payloadPath: item.payloadPath,
            ocrText: item.ocrText,
            metadataJson: metadataJson
        )
    }

    @discardableResult
    public func delete(_ id: UUID) -> Bool {
        do {
            try engine.softDelete(id: id.uuidString)
            return true
        } catch {
            Self.logger.error("delete failed for \(id.uuidString): \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    public func restore(_ id: UUID) -> Bool {
        do {
            try engine.restoreDeleted(id: id.uuidString)
            return true
        } catch {
            Self.logger.error("restore failed for \(id.uuidString): \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    public func purge(_ id: UUID) -> Bool {
        do {
            try engine.purgeItem(id: id.uuidString)
            return true
        } catch {
            Self.logger.error("purge failed for \(id.uuidString): \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    public func toggleFavorite(_ id: UUID) -> Bool {
        do {
            _ = try engine.toggleFavorite(id: id.uuidString)
            return true
        } catch {
            Self.logger.error("toggleFavorite failed for \(id.uuidString): \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    public func toggleSensitive(_ id: UUID) -> ClipboardItem? {
        do {
            let summary = try engine.toggleSensitive(id: id.uuidString)
            return toClipboardItem(summary, truncatingSummary: true)
        } catch {
            Self.logger.error("toggleSensitive failed for \(id.uuidString): \(error.localizedDescription)")
            return nil
        }
    }

    /// 轻量标记使用：仅更新 last_used_at、copy_count、updated_at，不重写 clip_payloads 或 clip_fts
    @discardableResult
    public func markUsed(_ id: UUID, usedAt: Date = Date()) -> ClipboardItem? {
        do {
            let summary = try engine.markUsed(id: id.uuidString, usedAt: usedAt.timeIntervalSince1970)
            return toClipboardItem(summary, truncatingSummary: true)
        } catch {
            Self.logger.error("markUsed failed for \(id.uuidString): \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    public func updateOCR(id: UUID, ocrText: String) -> Bool {
        do {
            try engine.updateOcrText(id: id.uuidString, ocrText: ocrText)
            return true
        } catch {
            Self.logger.error("updateOCR failed for \(id.uuidString): \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    public func updateTitle(id: UUID, title: String) -> Bool {
        do {
            try engine.updateTitle(id: id.uuidString, title: title)
            return true
        } catch {
            Self.logger.error("updateTitle failed for \(id.uuidString): \(error.localizedDescription)")
            return false
        }
    }

    public func clearAllHistory(keepFavorites: Bool = true) -> [PrunedItemRecord] {
        do {
            return try engine.clearAllHistory(keepFavorites: keepFavorites)
        } catch {
            Self.logger.error("Failed to clear history in Rust engine: \(error.localizedDescription)")
            return []
        }
    }

    public func countItems() -> Int {
        (try? engine.countItems()).map(Int.init) ?? 0
    }

    public func countFavorites() -> Int {
        (try? engine.countFavorites()).map(Int.init) ?? 0
    }

    public func pruneExpired(days: Int?, maxCount: Int?) -> [PrunedItemRecord] {
        let config = RetentionConfig(
            maxAgeDays: days.flatMap { $0 > 0 ? UInt32($0) : nil },
            maxItemCount: maxCount.map { UInt32($0) }
        )
        do {
            return try engine.pruneExpired(config: config)
        } catch {
            Self.logger.error("Failed to prune expired in Rust engine: \(error.localizedDescription)")
            return []
        }
    }

    public func enforceDiskLimit(managedDir: String, limitMB: Int) -> [PrunedItemRecord] {
        guard limitMB > 0 else { return [] }
        let limitBytes = UInt64(limitMB) << 20
        do {
            return try engine.enforceDiskLimit(managedDir: managedDir, limitBytes: limitBytes)
        } catch {
            Self.logger.error("Failed to enforce disk limit in Rust engine: \(error.localizedDescription)")
            return []
        }
    }

    public func getDetail(id: UUID) -> ClipItemDetail? {
        try? engine.getItemDetail(id: id.uuidString)
    }

    // MARK: - Synchronization

    @discardableResult
    public func syncPull(syncDir: String, deviceId: String, localAssetsDir: String) throws -> SyncReport {
        try engine.syncPull(syncDir: syncDir, deviceId: deviceId, localAssetsDir: localAssetsDir)
    }

    @discardableResult
    public func syncPush(syncDir: String, deviceId: String, localAssetsDir: String) throws -> SyncReport {
        try engine.syncPush(syncDir: syncDir, deviceId: deviceId, localAssetsDir: localAssetsDir)
    }

    @discardableResult
    public func syncNow(syncDir: String, deviceId: String, localAssetsDir: String) throws -> SyncReport {
        try engine.syncNow(syncDir: syncDir, deviceId: deviceId, localAssetsDir: localAssetsDir)
    }

    // MARK: - Mapping

    /// 列表 summary 前缀上限（字符）：列表行与回退标题只需预览量级文本；
    /// 全文经 item(id:) 按需取回。内存优化：万级历史滚动不再全文常驻
    /// （含 RowMapCache/管线/翻页镜像的共享字符串存储）
    static let summaryPrefixLimit = 300

    /// - Parameter truncatingSummary: 列表/搜索查询传 true（截断到前缀上限）；
    /// item(id:) 全文取回传 false
    private func toClipboardItem(_ summary: ClipItemSummary, truncatingSummary: Bool = true) -> ClipboardItem? {
        guard let uuid = UUID(uuidString: summary.id) else {
            return nil
        }
        let type = ClipboardItemType(rawValue: summary.itemType) ?? .text

        let createdAt = Date(timeIntervalSince1970: summary.createdAt)
        let lastUsedAt = Date(timeIntervalSince1970: summary.lastUsedAt)
        let deletedAt = summary.deletedAt.map { Date(timeIntervalSince1970: $0) }

        var metadata = ClipboardMetadata()
        if let json = summary.metadataJson, let data = json.data(using: .utf8) {
            metadata = (try? JSONDecoder().decode(ClipboardMetadata.self, from: data)) ?? ClipboardMetadata()
        }

        // 敏感条目（懒解密）：Rust 侧以引擎主密钥加密存储，仅全文路径
        // （truncatingSummary == false，item(id:) 粘贴/预览契约）经 detail
        // 解密并用 KeychainCryptoService 重加密恢复 revealPlainContent；
        // 列表/保存路径不解密——page 的逐条 detail+Keychain 是主线程 N+1 大头
        var encryptedContent: Data?
        if !truncatingSummary,
           summary.isSensitive,
           let detail = try? engine.getItemDetail(id: summary.id),
           let plain = detail.rawText {
            encryptedContent = KeychainCryptoService.shared.encrypt(text: plain)
        }

        var itemSummary = summary.summary
        var isTruncated = false
        if truncatingSummary, summary.summary.count > Self.summaryPrefixLimit {
            isTruncated = true
            itemSummary = String(summary.summary.prefix(Self.summaryPrefixLimit))
        }

        var item = ClipboardItem(
            id: uuid,
            type: type,
            title: summary.title,
            summary: itemSummary,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt,
            copyCount: Int(summary.copyCount),
            isFavorite: summary.favorite,
            payloadPath: summary.payloadPath,
            ocrText: summary.ocrText,
            sourceAppBundleId: summary.sourceAppBundleId,
            sourceAppName: summary.sourceAppName,
            isSensitive: summary.isSensitive,
            encryptedContent: encryptedContent,
            metadata: metadata,
            deletedAt: deletedAt
        )
        item.summaryIsTruncated = isTruncated
        item.persistedKind = summary.kind.isEmpty ? nil : summary.kind
        return item
    }
}
