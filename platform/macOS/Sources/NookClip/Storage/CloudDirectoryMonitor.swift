import Foundation

/// 云端目录监听：DispatchSource 的建立与取消、文件描述符关闭和事件防抖，
/// 输出「目录发生变化」事件（1s 防抖窗口合并批量事件；本地 push 写入
/// items 目录也会自触发，审计 BUG-047）。
/// 不触发数据库合并，也不修改同步状态。
final class CloudDirectoryMonitor {
    /// 目录发生变化（防抖后主线程回调）
    var onDirectoryChange: (() -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var monitoredDirectoryFileDescriptor: Int32 = -1
    private var debounceWork: DispatchWorkItem?

    /// 开始监听目录（重复调用先停止旧监听）
    func start(watching directoryURL: URL) {
        stop()
        let fd = open(directoryURL.path, O_EVTONLY)
        guard fd >= 0 else { return }

        monitoredDirectoryFileDescriptor = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .link],
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.scheduleDebouncedChange()
            }
        }

        source.setCancelHandler { [weak self] in
            _ = self // fd 关闭必须与 source 生命周期严格配对
            close(fd)
        }

        source.resume()
        self.source = source
    }

    private func scheduleDebouncedChange() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onDirectoryChange?()
        }
        debounceWork = work
        // 1s 防抖窗口合并批量事件；本地 push 也会触发监听（自反馈），
        // 拉取端有 lastPullAt 节流与内容比较兜底
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func stop() {
        if let source {
            source.cancel()
            self.source = nil
        }
        monitoredDirectoryFileDescriptor = -1
        debounceWork?.cancel()
        debounceWork = nil
    }

    deinit {
        stop()
    }
}
