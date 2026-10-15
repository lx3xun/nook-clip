import AppKit

/// 剪贴板访问入口：生产环境固定 NSPasteboard.general；
/// 测试进程可整体切换到私有命名剪贴板（NSPasteboard(name:)），
/// 使测试写入不触达系统剪贴板、不被同机运行的 NookClip 捕获进真实历史库
/// （历史库中的「first.md 等 2 个文件」「图片 4×4 ×N」测试污染即源于此）。
/// 命名剪贴板与系统剪贴板行为一致（changeCount/clearContents/writeObjects/自定义类型），
/// AppKit ⌘V 等系统行为仍读 NSPasteboard.general，不受影响。
enum PasteboardAccess {
    private static let lock = NSLock()
    private static var override: NSPasteboard?

    /// 当前进程使用的剪贴板；未切换时即系统剪贴板
    static var general: NSPasteboard {
        lock.lock()
        defer { lock.unlock() }
        return override ?? .general
    }

    /// 切换到进程内私有命名剪贴板（幂等，仅首次调用生效）。
    /// 每个测试进程用独立 UUID 命名，避免并行 worker 或先后进程共享状态。
    static func useIsolatedNamedPasteboard() {
        lock.lock()
        defer { lock.unlock() }
        guard override == nil else { return }
        let board = NSPasteboard(name: NSPasteboard.Name("NookTests-\(UUID().uuidString)"))
        board.clearContents()
        override = board
    }
}
