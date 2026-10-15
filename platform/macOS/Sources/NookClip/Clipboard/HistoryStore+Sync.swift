import Foundation
import OSLog

// MARK: - iCloud 云端同步（T041：增量推送 + 首拉前全量对账）
extension InMemoryHistoryStore {
    public func scheduleSyncPush() {
        syncEngine.schedulePushDebounce()
    }

    func setupSyncEngine() {
        syncEngine.onRemoteChange = { [weak self] in
            Task { @MainActor [weak self] in
                // T053（审查 D-6）：远端变更回调加 5 秒短节流——目录监听在
                // iCloud 批量落盘时高频连发，每次都全量拉取会放大目录重复扫描
                await self?.pullRemoteChanges(minInterval: 5)
            }
        }
        if syncEngine.isEnabled {
            syncEngine.setupDirectoryMonitoring()
            Task {
                await self.pullRemoteChanges()
            }
        }
    }

    func recordDeletion(_ id: UUID) {}

    public func syncNow() async {
        guard syncEngine.isEnabled else { return }
        syncEngine.updateObservableState(.syncing)
        let syncDir = syncEngine.baseDirectoryURL.path
        let deviceID = syncDeviceID
        let assetsDir = payloadStore.directory.path
        let rustStore = self.rustStore
        do {
            // 安全不变量：敏感内容绝不上云（pack 仅 zstd 压缩、未加密）。
            // FFI 同步（iCloud 目录 IO）挪后台执行，结果回 MainActor 刷新镜像
            let report = try await Task.detached(priority: .utility) {
                try rustStore.syncNow(
                    syncDir: syncDir,
                    deviceId: deviceID,
                    localAssetsDir: assetsDir
                )
            }.value
            if report.pulledCount > 0 {
                items = rustStore.page(limit: Self.pageSize, offset: 0)
                trashItems = rustStore.trashItems()
                refreshHasMore()
                publishMutation(scheduleSync: false)
            }
            syncEngine.recordSuccess()
        } catch {
            Self.logger.error("Rust sync failed: \(error.localizedDescription, privacy: .public)")
            syncEngine.recordFailure(error)
        }
    }

    /// 拉取结果：true = 成功，false = 失败，nil = 未执行（同步未启用/节流跳过）
    @discardableResult
    public func pullRemoteChanges(minInterval: TimeInterval? = nil) async -> Bool? {
        guard syncEngine.isEnabled else { return nil }
        guard syncEngine.shouldPull(minInterval: minInterval) else { return nil }
        let syncDir = syncEngine.baseDirectoryURL.path
        let deviceID = syncDeviceID
        let assetsDir = payloadStore.directory.path
        let rustStore = self.rustStore
        syncEngine.updateObservableState(.syncing)
        do {
            // FFI 拉取（iCloud 目录 IO）挪后台执行，结果回 MainActor 刷新镜像
            let report = try await Task.detached(priority: .utility) {
                try rustStore.syncPull(
                    syncDir: syncDir,
                    deviceId: deviceID,
                    localAssetsDir: assetsDir
                )
            }.value
            syncEngine.markPulled()
            if report.pulledCount > 0 {
                items = rustStore.page(limit: Self.pageSize, offset: 0)
                trashItems = rustStore.trashItems()
                refreshHasMore()
                publishMutation(scheduleSync: false)
            }
            syncEngine.recordSuccess()
            return true
        } catch {
            Self.logger.error("Rust sync pull failed: \(error.localizedDescription, privacy: .public)")
            syncEngine.recordFailure(error)
            return false
        }
    }

    // MARK: - 保留期清理

    /// days <= 0（无限制）时完全跳过本地清理；否则清理所有符合条件的本地条目。
    func pruneExpiredItems(days: Int) {
        guard days > 0 else { return }
        let pruned = rustStore.pruneExpired(days: days, maxCount: nil)
        items = rustStore.page(limit: Self.pageSize, offset: 0)
        trashItems = rustStore.trashItems()
        publishMutation(scheduleSync: false)
        for record in pruned {
            payloadStore.remove(path: record.payloadPath)
        }
        if syncEngine.isEnabled {
            scheduleSyncPush()
        }
    }
}
