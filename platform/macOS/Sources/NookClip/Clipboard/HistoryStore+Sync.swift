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
                // 远端变更短节流（2.5 秒）
                await self?.pullRemoteChanges(minInterval: 2.5)
            }
        }
        if syncEngine.isEnabled {
            syncEngine.setupSyncTriggers()
            Task {
                await self.pullRemoteChanges()
            }
        }
    }

    func recordDeletion(_ id: UUID) {}

    public func syncNow() async {
        guard syncEngine.isEnabled else { return }
        if syncEngine.syncMode == .webdav && syncEngine.webDavURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        syncEngine.updateObservableState(.syncing)
        let options = await syncEngine.makeSyncOptionsAsync(
            deviceId: syncDeviceID,
            localAssetsDir: payloadStore.directory.path
        )
        // 口令校验基于实际参与同步的选项，避免入口处与真正下发的参数不一致（TOCTOU）
        if syncEngine.isE2EEEnabled && options.passphrase == nil {
            syncEngine.recordFailureMessage(L10n.tr("settings.sync.passphrase_required"))
            return
        }
        let rustStore = self.rustStore
        do {
            let report = try await Task.detached(priority: .utility) {
                try rustStore.syncWithOptions(options)
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
    /// 使用当前新口令重置云端加密凭证并将本机剪贴板重新推送到云端
    public func resetSyncPassphrase() async throws {
        guard syncEngine.isEnabled else { return }
        syncEngine.updateObservableState(.syncing)
        let options = await syncEngine.makeSyncOptionsAsync(
            deviceId: syncDeviceID,
            localAssetsDir: payloadStore.directory.path
        )
        let rustStore = self.rustStore
        do {
            _ = try await Task.detached(priority: .userInitiated) {
                try rustStore.resetSyncPassphrase(options: options)
            }.value
            syncEngine.recordSuccess()
        } catch {
            Self.logger.error("Reset sync passphrase failed: \(error.localizedDescription, privacy: .public)")
            syncEngine.recordFailure(error)
            throw error
        }
    }

    /// 拉取结果：true = 成功，false = 失败，nil = 未执行（同步未启用/节流跳过）
    @discardableResult
    public func pullRemoteChanges(minInterval: TimeInterval? = nil) async -> Bool? {
        guard syncEngine.isEnabled else { return nil }
        guard syncEngine.shouldPull(minInterval: minInterval) else { return nil }
        if syncEngine.syncMode == .webdav && syncEngine.webDavURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        syncEngine.markPulled()
        let options = await syncEngine.makeSyncOptionsAsync(
            deviceId: syncDeviceID,
            localAssetsDir: payloadStore.directory.path
        )
        // 口令校验基于实际参与同步的选项，避免入口处与真正下发的参数不一致
        if syncEngine.isE2EEEnabled && options.passphrase == nil {
            syncEngine.recordFailureMessage(L10n.tr("settings.sync.passphrase_required"))
            return false
        }
        let rustStore = self.rustStore
        syncEngine.updateObservableState(.syncing)
        do {
            let report = try await Task.detached(priority: .utility) {
                try rustStore.syncPullWithOptions(options)
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

    // MARK: - 条数上限裁剪

    /// 把非收藏、无标签的活跃条目裁到最多 `count` 条（超限时淘汰最久未使用的，
    /// 收藏条目始终豁免）。「无限制」已退役：传入值先经策略收敛，
    /// 0/负数等价于硬上限，超上限也按硬上限处理。
    func pruneToMaxItems(_ count: Int) {
        let limit = HistoryMaxItemsPolicy.clamp(count)
        let pruned = rustStore.pruneExpired(days: nil, maxCount: limit)
        items = rustStore.page(limit: Self.pageSize, offset: 0)
        trashItems = rustStore.trashItems()
        // 裁剪减少了总条数，翻页终止信号必须随库重算，否则列表尾部会残留
        // 「还有更多」按钮却翻不出任何内容
        refreshHasMore()
        publishMutation(scheduleSync: false)
        for record in pruned {
            payloadStore.remove(path: record.payloadPath)
        }
        if syncEngine.isEnabled {
            scheduleSyncPush()
        }
    }
}
