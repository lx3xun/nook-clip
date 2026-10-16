import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class InMemoryHistoryStore {
    nonisolated static let demoSeededKey = "nook.demoItemsSeeded"
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.lx3xun.nookclip", category: "HistoryStore")
    let rustStore: RustHistoryStore
    /// 配置读取来源（测试注入隔离 suite，避免污染测试进程共享域）
    let defaults: UserDefaults
    /// 载荷文件存取（测试注入替身，记录清理调用）
    @ObservationIgnored let payloadStore: any PayloadStore
    /// OCR 识别与回写（T030 收编；测试注入替身引擎，默认 OCREngine.shared）
    @ObservationIgnored private let ocrService: HistoryOCRService
    var items: [ClipboardItem] = []
    public let syncEngine: ICloudDriveSyncEngine
    /// 磁盘限额低频检查定时器（10 分钟；save 等高频写入口不再触发全表 stat，FR-005）
    @ObservationIgnored private var diskLimitTimer: Timer?
    // MARK: 分页加载（首页 100 条，滚动到底自动翻页）
    /// 每页条数
    static let pageSize = 100
    /// 是否还有未加载的更早条目（列表底部哨兵据此显示加载态）
    var hasMoreItems = false
    /// 翻页防抖（哨兵 onAppear 可能连发）
    var loadingMore = false

    /// 数据版本：每次成功提交数据库写批次后 +1，视图据此刷新进行中的搜索结果
    private(set) var dataVersion = 0
    var lastSyncResult: SyncResult { syncEngine.lastSyncResult }

    public var syncDeviceID: String {
        let existingID = defaults.string(forKey: "nook.sync.deviceID")
        if let id = existingID, !id.isEmpty {
            let isLegacyPlaceholder = id.range(of: #"^device-[A-F0-9]{8}$"#, options: .regularExpression) != nil
            if !isLegacyPlaceholder {
                return id
            }
            // 清理旧占位符 pack 文件（如果存在）
            let oldPackURL = syncEngine.devicesDirectoryURL.appendingPathComponent("\(id).pack")
            try? FileManager.default.removeItem(at: oldPackURL)
        }
        let rawName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let safeName = rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\0", with: "")
        let prefix = safeName.isEmpty ? "Mac" : safeName
        let suffix = existingID?.components(separatedBy: "-").last ?? String(UUID().uuidString.prefix(8))
        let generated = "\(prefix)-\(suffix)"
        defaults.set(generated, forKey: "nook.sync.deviceID")
        return generated
    }

    /// T040（契约 R4/R5）依赖收口说明：payloadStore/syncEngine/defaults 的
    /// `.shared`/`.standard` 默认值仅为测试便捷保留——生产组装链（AppDependencies/
    /// AppDelegate）已显式传参；待 UI/App 侧接线完成后收口移除默认值。
    init(
        rustStore: RustHistoryStore? = nil,
        syncEngine: ICloudDriveSyncEngine = .shared,
        defaults: UserDefaults = .standard,
        payloadStore: any PayloadStore = FileStore.shared,
        ocrEngine: OCREngine = .shared
    ) {
        if let rustStore {
            self.rustStore = rustStore
        } else if NSClassFromString("XCTestCase") != nil {
            // 测试运行环境防呆：若未显式注入 store，一律默认使用进程隔离的内存库，绝不得触碰生产磁盘库
            self.rustStore = try! RustHistoryStore(path: ":memory:", encryptionKey: Data(repeating: 0x42, count: 32))
        } else {
            self.rustStore = RustHistoryStore.openProduction()
        }
        self.defaults = defaults
        self.syncEngine = syncEngine
        self.payloadStore = payloadStore
        self.ocrService = HistoryOCRService(rustStore: self.rustStore, ocrEngine: ocrEngine)
        syncEngine.onDebouncedPush = { [weak self] in
            await self?.syncNow()
        }
        // 启动加载只做轻量查询（首页 + 回收站）；保留期清理与空白行清理
        // 移入 performStartupMaintenance 后台执行——万级历史下 prune +
        // 1000 行扫描是主线程启动卡顿大头。删除的墓碑由 Rust 侧
        // sync_tombstones 事务性写入，与首次拉取竞态不再有永久复活风险
        items = self.rustStore.page(limit: Self.pageSize, offset: 0)
        trashItems = self.rustStore.trashItems()
        refreshHasMore()
        seedDemoItemsIfNeeded()

        // 磁盘限额检查（FR-005）：启动执行一次，此后每 10 分钟低频复查
        enforceDiskLimit()
        sweepOrphanPayloads()
        scheduleDiskLimitEnforcementIfNeeded()

        // 测试环境下不自动调度（异步清理会与用例播种/断言竞态），
        // 用例直接 await performStartupMaintenance() 驱动
        if NSClassFromString("XCTestCase") == nil {
            Task { [weak self] in
                await self?.performStartupMaintenance()
            }
        }

        setupSyncEngine()
    }

    /// 磁盘限额低频定时器（10 分钟，tolerance 60s 允许系统合并唤醒降低能耗）；
    /// save 等高频写入口只确保定时器存在（幂等），不触发检查。
    /// .common mode 保证菜单追踪期间不漏（与剪贴板轮询同一取舍）。
    private func scheduleDiskLimitEnforcementIfNeeded() {
        guard diskLimitTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.enforceDiskLimit() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        diskLimitTimer = timer
    }

    /// 数据库写批次提交成功后调用：发布内存/云端副作用的统一出口
    /// （推送恒为 Rust 引擎全量导出，无增量脏标记）。
    /// - Parameter scheduleSync: 是否触发云端推送防抖（无同步意义的清理流程传 false）
    func publishMutation(scheduleSync: Bool = true) {
        dataVersion += 1
        if scheduleSync {
            syncEngine.schedulePushDebounce()
        }
    }

    /// 按数据库 ID 取实体：内存页优先，兜底查库（全历史命中不必已在内存页）。
    /// 全文契约收口：截断前缀条目与敏感条目（镜像不持明文，懒解密）都经
    /// rustStore.item(id:) 按需取回全文——粘贴/预览/回存的统一入口
    func item(withID id: UUID) -> ClipboardItem? {
        if let memory = items.first(where: { $0.id == id }) ?? trashItems.first(where: { $0.id == id }) {
            // 敏感条目懒解密：镜像不持有 Keychain 密文；明文经库内 detail 取回。
            // 镜像持有密文时（如捕获后未落库、测试注入损坏密文）以镜像为准，
            // reveal 成败由该密文决定
            if memory.isSensitive, memory.encryptedContent == nil {
                return rustStore.item(id: id)
            }
            guard memory.summaryIsTruncated else { return memory }
            // 截断副本不可用于粘贴/回存；取回失败返回 nil（宁可不动作，
            // 也不能把截断前缀写入剪贴板或 FTS 索引）
            return rustStore.item(id: id)
        }
        // 兜底查库：支持内存页之外的历史记录
        return rustStore.item(id: id)
    }

    /// 启动维护（原 init 同步执行）：保留期清理 + 空白行清理 + 载荷清删。
    /// FFI（prune 全表扫描 + 空白行 1000 行扫描）在后台执行，结果回
    /// MainActor 刷新镜像并发布变更；无清理发生时不触动镜像
    func performStartupMaintenance() async {
        let rustStore = self.rustStore
        let retentionDays = RetentionPolicy(defaults: defaults).days
        // 保留期单一来源：nil = 无限制（用户显式设 0）；未设置 = 默认 30 天。
        // 只清活跃条目（收藏豁免）；软删除条目按撤销宽限窗口另行清除
        let purged: [(id: UUID, payloadPath: String?)] = await Task.detached(priority: .utility) {
            var purged: [(id: UUID, payloadPath: String?)] = []
            if let retentionDays {
                let pruned = rustStore.pruneExpired(days: retentionDays, maxCount: nil)
                purged.append(contentsOf: pruned.compactMap { record in
                    guard let id = UUID(uuidString: record.id) else { return nil }
                    return (id: id, payloadPath: record.payloadPath)
                })
            }
            for item in rustStore.page(limit: 1000, offset: 0) where item.isBlankText {
                _ = rustStore.purge(item.id)
                purged.append((id: item.id, payloadPath: item.payloadPath))
            }
            return purged
        }.value
        guard !purged.isEmpty else { return }

        for record in purged {
            payloadStore.remove(path: record.payloadPath)
        }
        // 清理属全量变更：整页重查一次可接受（低频路径）
        items = rustStore.page(limit: Self.pageSize, offset: 0)
        trashItems = rustStore.trashItems()
        refreshHasMore()
        publishMutation(scheduleSync: false)
    }

    /// 复制链写入口（最高频）：保存成功后增量应用持久化结果
    /// （去重合并后的真实 id/copyCount/createdAt），不整页重查。
    /// hasMore 纯内存推导：镜像只有写满一页时库内才可能有剩余行，
    /// 置顶插入只会把队尾行推出镜像，不会使剩余行消失
    func save(_ item: ClipboardItem) {
        guard !item.isBlankText else { return }
        guard let persisted = rustStore.save(item) else { return }
        items.removeAll { $0.id == persisted.id }
        items.insert(persisted, at: 0)
        if items.count > Self.pageSize {
            items.removeLast(items.count - Self.pageSize)
        }
        hasMoreItems = hasMoreItems || items.count == Self.pageSize
        purgeExpiredTrash()
        scheduleDiskLimitEnforcementIfNeeded()
        publishMutation()
    }

    // MARK: 删除与撤销

    /// 软删除条目镜像（删除时间倒序；仅存活于撤销宽限窗口内，全量不分页）
    var trashItems: [ClipboardItem] = []

    /// 删除 = 软删除（本地与云端记录都保留，仅标记 deletedAt，不写墓碑），
    /// UI 撤销窗口内可 restoreFromTrash 恢复；窗口过后按宽限彻底清除
    func delete(_ id: UUID) {
        let candidate = items.first(where: { $0.id == id }) ?? item(withID: id)
        guard let item = candidate else { return }
        var removed = item
        if removed.deletedAt == nil { removed.deletedAt = .now }
        items.removeAll { $0.id == id }
        trashItems.insert(removed, at: 0)
        rustStore.delete(id)
        publishMutation()
    }

    func deleteMultiple(_ ids: Set<UUID>) {
        let toTrash = items.filter { ids.contains($0.id) }.map { item -> ClipboardItem in
            var trashed = item
            if trashed.deletedAt == nil { trashed.deletedAt = .now }
            return trashed
        }
        items.removeAll { ids.contains($0.id) }
        trashItems.insert(contentsOf: toTrash, at: 0)
        for id in ids { rustStore.delete(id) }
        publishMutation()
    }

    func restoreFromTrash(_ ids: Set<UUID>) {
        let candidates = trashItems.filter { ids.contains($0.id) }
        trashItems.removeAll { ids.contains($0.id) }
        for item in candidates {
            var restored = item
            restored.deletedAt = nil
            restored.lastUsedAt = Date()
            items.insert(restored, at: 0)
        }
        refreshHasMore()
        for id in ids { rustStore.restore(id) }
        publishMutation()
    }

    static func expiredTrash(in trash: [ClipboardItem], now: Date) -> [ClipboardItem] {
        let cutoff = now.addingTimeInterval(-TrashPurgeWindow.grace)
        return trash.filter { ($0.deletedAt ?? .distantPast) < cutoff }
    }

    /// 软删除条目按撤销宽限窗口清除（窗口内条目不动）。
    /// - Parameter now: 判定基准时间（默认当前；测试注入未来时间模拟窗口过期）
    /// 返回被彻底清除的条目（便于测试与统计）
    @discardableResult
    func purgeExpiredTrash(now: Date = Date()) -> [ClipboardItem] {
        let expired = Self.expiredTrash(in: trashItems, now: now)
        hardDelete(expired)
        return expired
    }

    /// 撤销窗口关闭后安排兜底清除：进程常驻但用户可能长时间无写入，
    /// 定时任务保证软删除条目到期即彻底清除（幂等，条件按 deletedAt 统一判定）
    func scheduleExpiredTrashPurge() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(TrashPurgeWindow.grace))
            self?.purgeExpiredTrash()
        }
    }

    private func hardDelete(_ toDelete: [ClipboardItem]) {
        guard !toDelete.isEmpty else { return }
        var purged: [ClipboardItem] = []
        purged.reserveCapacity(toDelete.count)
        for item in toDelete {
            if rustStore.purge(item.id) {
                purged.append(item)
            } else {
                Self.logger.error("hardDelete purge 失败，条目保留原状态：\(item.id.uuidString)")
            }
        }
        guard !purged.isEmpty else { return }
        let ids = Set(purged.map(\.id))
        trashItems.removeAll(where: { ids.contains($0.id) })
        for item in purged {
            payloadStore.remove(path: item.payloadPath)
        }
        publishMutation(scheduleSync: false)
    }

    private func sweepOrphanPayloads(grace: TimeInterval = 24 * 3600) {
        let referenced = Set(rustStore.payloadPaths())
        let store = payloadStore
        Task.detached(priority: .utility) {
            _ = store.sweepOrphans(referencedPaths: referenced, olderThan: grace)
        }
    }

    func markUsed(_ id: UUID) {
        // 轻量标记使用：仅刷新时间戳与复制次数，不重写 clip_payloads（杜绝掩码或截断前缀覆盖原文）；
        // 已在回收站中的条目不动作
        guard let current = item(withID: id), current.deletedAt == nil else { return }
        guard let persisted = rustStore.markUsed(id) else { return }
        items.removeAll { $0.id == id }
        items.insert(persisted, at: 0)
        publishMutation()
    }

    func toggleFavorite(_ id: UUID) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].isFavorite.toggle()
        }
        rustStore.toggleFavorite(id)
        publishMutation()
    }

    @discardableResult
    func toggleSensitive(_ id: UUID) -> Bool {
        guard let updated = rustStore.toggleSensitive(id) else {
            return false
        }
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index] = updated
        }
        publishMutation()
        return true
    }

    // MARK: - 自定义标题与元数据管理（T032，契约 R1/R3：转发 MutationService）

    func updateMetadata(for id: UUID, metadata: ClipboardMetadata) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].metadata = metadata
        }
        publishMutation()
    }

    func updateTitle(_ title: String, for id: UUID) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].title = trimmed
        }
        rustStore.updateTitle(id: id, title: trimmed)
        publishMutation()
    }

    // MARK: - 离线 OCR 文本识别（T030：转发 HistoryOCRService）

    /// 用户手动触发 OCR 识别（前台交互路径）：
    /// 识别成功后回写数据库与内存，并在 completion 回传识别文本（失败回传 nil）
    func performManualOCR(for id: UUID, completion: ((String?) -> Void)? = nil) {
        guard let item = items.first(where: { $0.id == id }) else {
            completion?(nil)
            return
        }
        ocrService.performManualOCR(for: item) { [weak self] text, itemId in
            if let text {
                self?.updateOCRText(text, for: itemId)
            }
            // 识别不到文字（纯色图等）也必须回调 nil：调用方依赖此信号复位扫描状态
            completion?(text)
        }
    }

    /// async 版本手动 OCR 识别
    @discardableResult
    func performManualOCR(for id: UUID) async -> String? {
        await withCheckedContinuation { continuation in
            performManualOCR(for: id) { result in
                continuation.resume(returning: result)
            }
        }
    }

    func updateOCRText(_ text: String, for id: UUID) {
        // 服务内单事务回写（含 FTS 索引行替换与敏感掩码）；成功后仅刷内存镜像
        guard let storable = ocrService.updateOCRText(text, for: id) else { return }
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].ocrText = storable
        }
        if let index = trashItems.firstIndex(where: { $0.id == id }) {
            trashItems[index].ocrText = storable
        }
        publishMutation()
    }

    // MARK: - 统计与清理

    var totalCount: Int {
        _ = dataVersion
        return rustStore.countItems()
    }
    var favoriteCount: Int {
        _ = dataVersion
        return rustStore.countFavorites()
    }
    var unflaggedCount: Int {
        max(0, totalCount - favoriteCount)
    }

    // MARK: 磁盘空间限制

    /// payload 文件总大小超限时按「最久未使用」淘汰，收藏条目豁免；回收站条目计入总量且不豁免。
    func enforceDiskLimit() {
        let limitMB = defaults.integer(forKey: "historyDiskLimitMB")
        guard limitMB > 0 else { return }
        let rustStore = self.rustStore
        let managedDir = payloadStore.directory.standardizedFileURL.path
        Task { @MainActor in
            let evicted = await Task.detached(priority: .utility) {
                rustStore.enforceDiskLimit(managedDir: managedDir, limitMB: limitMB)
            }.value
            guard !evicted.isEmpty else { return }
            let evictedIDs = Set(evicted.compactMap { UUID(uuidString: $0.id) })
            for record in evicted {
                payloadStore.remove(path: record.payloadPath)
            }
            items.removeAll { evictedIDs.contains($0.id) }
            trashItems.removeAll { evictedIDs.contains($0.id) }
            refreshHasMore()
            publishMutation(scheduleSync: false)
        }
    }

    func clearHistory(keepFavorites: Bool = true) {
        let pruned = rustStore.clearAllHistory(keepFavorites: keepFavorites)
        let deletedFromTrash = trashItems.filter { !keepFavorites || !$0.isFavorite }
        for record in pruned {
            payloadStore.remove(path: record.payloadPath)
        }
        for item in deletedFromTrash {
            payloadStore.remove(path: item.payloadPath)
        }
        trashItems.removeAll()
        items = rustStore.page(limit: Self.pageSize, offset: 0)
        refreshHasMore()
        publishMutation(scheduleSync: false)
    }
}
