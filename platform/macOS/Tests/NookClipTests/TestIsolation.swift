import XCTest
import Darwin
@testable import NookClip

/// 测试隔离工具：
/// 1) UserDefaults 不再写测试进程共享域（com.apple.dt.xctest.tool），
///    避免 swift test --parallel 多 worker 进程互相踩踏、以及泄漏键影响后续运行；
/// 2) 系统剪贴板：进入剪贴板锁时整体切换到进程私有命名剪贴板（PasteboardAccess），
///    测试读写不再触达 NSPasteboard.general——同机运行的 NookClip 不会把测试数据
///    捕获进真实历史库；flock 仍保留，兜底未来任何直用系统剪贴板的用例。
extension XCTestCase {

    /// 每个用例独占的 UserDefaults suite，teardown 时整域清除
    func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "nook-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    /// 关闭同步的引擎（隔离 defaults，enableICloudSync 未设置 = false）：
    /// 非同步主题的 store 测试不再受共享单例引擎 isEnabled 状态影响
    func makeDisabledSyncEngine() -> ICloudDriveSyncEngine {
        ICloudDriveSyncEngine(
            customBaseURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            defaults: makeIsolatedDefaults()
        )
    }

    /// 隔离 store：独占 defaults suite（演示播种标记不落真实用户域）+ 关闭同步的
    /// 引擎（不触达真实 iCloud）——非同步主题用例的默认构造方式
    @MainActor
    func makeIsolatedStore(rustStore: RustHistoryStore) -> InMemoryHistoryStore {
        PasteboardAccess.useIsolatedNamedPasteboard()
        return InMemoryHistoryStore(rustStore: rustStore, syncEngine: makeDisabledSyncEngine(), defaults: makeIsolatedDefaults())
    }
    @MainActor
    func makeIsolatedStore(syncEngine: ICloudDriveSyncEngine, defaults: UserDefaults? = nil) -> InMemoryHistoryStore {
        PasteboardAccess.useIsolatedNamedPasteboard()
        let tempPath = NSTemporaryDirectory() + "nook_isolated_\(UUID().uuidString).sqlite"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tempPath) }
        let rustStore = (try? RustHistoryStore(path: tempPath, encryptionKey: Data(repeating: 0x42, count: 32))) ?? (try! RustHistoryStore(path: ":memory:", encryptionKey: Data(repeating: 0x42, count: 32)))
        let effectiveDefaults = defaults ?? makeIsolatedDefaults()
        effectiveDefaults.set(true, forKey: InMemoryHistoryStore.demoSeededKey)
        return InMemoryHistoryStore(
            rustStore: rustStore,
            syncEngine: syncEngine,
            defaults: effectiveDefaults
        )
    }
    @MainActor
    func makeIsolatedStore(defaults: UserDefaults? = nil) -> InMemoryHistoryStore {
        PasteboardAccess.useIsolatedNamedPasteboard()
        let tempPath = NSTemporaryDirectory() + "nook_isolated_\(UUID().uuidString).sqlite"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tempPath) }
        let rustStore = (try? RustHistoryStore(path: tempPath, encryptionKey: Data(repeating: 0x42, count: 32))) ?? (try! RustHistoryStore(path: ":memory:", encryptionKey: Data(repeating: 0x42, count: 32)))
        let effectiveDefaults = defaults ?? makeIsolatedDefaults()
        effectiveDefaults.set(true, forKey: InMemoryHistoryStore.demoSeededKey)
        return InMemoryHistoryStore(
            rustStore: rustStore,
            syncEngine: makeDisabledSyncEngine(),
            defaults: effectiveDefaults
        )
    }

    /// 跨进程互斥访问系统剪贴板（NSPasteboard.general 全登录会话共享）
    func withPasteboardLock<T>(_ body: () throws -> T) rethrows -> T {
        let fd = open(NSTemporaryDirectory() + "nook-pasteboard.lock", O_CREAT | O_RDWR, 0o644)
        precondition(fd >= 0, "无法打开剪贴板测试锁文件")
        defer { close(fd) }
        let result = flock(fd, LOCK_EX)
        precondition(result == 0, "无法获取剪贴板测试锁")
        defer { _ = flock(fd, LOCK_UN) }
        PasteboardAccess.useIsolatedNamedPasteboard()
        return try body()
    }
    /// 异步版本：监控窗口需要跨越 await 持锁
    func withPasteboardLock<T>(_ body: () async throws -> T) async rethrows -> T {
        let fd = open(NSTemporaryDirectory() + "nook-pasteboard.lock", O_CREAT | O_RDWR, 0o644)
        precondition(fd >= 0, "无法打开剪贴板测试锁文件")
        defer { close(fd) }
        let result = flock(fd, LOCK_EX)
        precondition(result == 0, "无法获取剪贴板测试锁")
        defer { _ = flock(fd, LOCK_UN) }
        PasteboardAccess.useIsolatedNamedPasteboard()
        return try await body()
    }
}

