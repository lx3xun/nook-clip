import Foundation
import Observation
import os

/// iCloud Drive 同步管理引擎：管理目录配置、安全作用域与 devices/ 目录变动监听。
/// 核心同步、打包压缩与冲突解决由 Rust nook-core 引擎在 SQLite 事务中完成。
@Observable
final class ICloudDriveSyncEngine {
    static let shared = ICloudDriveSyncEngine()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.lx3xun.nookclip",
        category: "ICloudDriveSyncEngine"
    )

    private(set) var state: SyncState = .idle
    private(set) var lastSyncDate: Date?
    private(set) var lastSyncResult: SyncResult = .idle
    var onRemoteChange: (() -> Void)?
    @ObservationIgnored var onDebouncedPush: (() async -> Void)?
    @ObservationIgnored private var pushDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var lastPullAt: Date?

    @MainActor
    func updateObservableState(_ newState: SyncState, lastSyncDate: Date? = nil) {
        state = newState
        if let lastSyncDate {
            self.lastSyncDate = lastSyncDate
        }
    }

    @MainActor
    func recordSuccess(_ date: Date = Date()) {
        lastSyncResult = .success(date)
        updateObservableState(.success(date), lastSyncDate: date)
    }

    @MainActor
    func recordFailure(_ error: Error, at date: Date = Date()) {
        let reason: SyncFailureReason = (error as NSError).domain == NSURLErrorDomain ? .network : .unknown
        lastSyncResult = .failure(reason, at: date)
        updateObservableState(.failed(reason.localizedDescription))
    }

    @MainActor
    func schedulePushDebounce() {
        guard isEnabled else { return }
        pushDebounceTask?.cancel()
        pushDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.onDebouncedPush?()
        }
    }

    func shouldPull(minInterval: TimeInterval?) -> Bool {
        guard let minInterval, let lastPullAt else { return true }
        return Date().timeIntervalSince(lastPullAt) >= minInterval
    }

    func markPulled() {
        lastPullAt = Date()
    }

    private let isSyncEnabledKey = "enableICloudSync"
    private let defaults: UserDefaults
    private let repository: CloudFileRepository
    private let monitor: CloudDirectoryMonitor

    init(customBaseURL: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.repository = CloudFileRepository(defaults: defaults, customBaseURL: customBaseURL)
        self.monitor = CloudDirectoryMonitor()
        monitor.onDirectoryChange = { [weak self] in
            self?.onRemoteChange?()
        }
    }

    // MARK: - 开关与目录

    var isEnabled: Bool {
        get {
            defaults.bool(forKey: isSyncEnabledKey)
        }
        set {
            defaults.set(newValue, forKey: isSyncEnabledKey)
            if newValue {
                setupDirectoryMonitoring()
            } else {
                stopDirectoryMonitoring()
            }
        }
    }

    var baseDirectoryURL: URL { repository.baseDirectoryURL }
    var devicesDirectoryURL: URL { repository.devicesDirectoryURL }
    var assetsDirectoryURL: URL { repository.assetsDirectoryURL }

    // MARK: - 目录配置与权限

    func setCustomDirectory(url: URL) throws {
        try repository.setCustomDirectory(url)
        setupDirectoryMonitoring()
    }

    func resetToDefaultDirectory() {
        repository.resetToDefaultDirectory()
        setupDirectoryMonitoring()
    }

    func ensureDirectoriesExist() throws {
        try repository.ensureDirectoriesExist()
    }

    // MARK: - 目录监听

    func setupDirectoryMonitoring() {
        stopDirectoryMonitoring()
        guard isEnabled else { return }
        try? repository.ensureDirectoriesExist()
        monitor.start(watching: repository.devicesDirectoryURL)
    }

    func stopDirectoryMonitoring() {
        monitor.stop()
    }

    deinit {
        monitor.stop()
        repository.releaseSecurityScope()
    }
}
