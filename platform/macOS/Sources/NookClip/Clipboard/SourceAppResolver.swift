import AppKit

/// 复制来源归因：修复「Chrome 复制 → 0.35s 内切到其他应用，来源被记成切换后的应用」。
///
/// ClipboardMonitor 以 0.35s 轮询 `changeCount`，变化发生时刻 ≠ 检测时刻。
/// 检测时若前台应用激活不足一个轮询周期，复制更可能发生在切换前的应用
/// （复制 → 切换去粘贴是高频流，切换后 0.35s 内完成定位+复制的反向流罕见），
/// 归因到切换前应用；已稳定驻留超过一个周期则归因当前应用。
struct SourceAppResolver {
    struct Activation: Equatable {
        let bundleId: String?
        let name: String?
        /// NookClip 自身（面板等）——不可能是复制来源，解析时跳过
        let isSelf: Bool
        let at: Date
    }

    private var history: [Activation] = []
    private let pollInterval: TimeInterval

    init(pollInterval: TimeInterval = 0.35) {
        self.pollInterval = pollInterval
    }

    /// 记录一次应用激活（最近 8 条足够覆盖快速来回切换）
    mutating func record(bundleId: String?, name: String?, isSelf: Bool, at date: Date = Date()) {
        history.append(Activation(bundleId: bundleId, name: name, isSelf: isSelf, at: date))
        if history.count > 8 {
            history.removeFirst(history.count - 8)
        }
    }

    /// 解析当前剪贴板变化的来源应用（单轨化委托给 Rust 核心 algorithms::source_resolver）。
    func resolve(now: Date = Date()) -> Activation? {
        guard !history.isEmpty else { return nil }
        let ffiHistory = history.map {
            AppActivationRecord(
                bundleId: $0.bundleId,
                name: $0.name,
                isSelf: $0.isSelf,
                activatedAt: $0.at.timeIntervalSince1970
            )
        }
        guard let resolved = resolveClipboardSourceApp(
            history: ffiHistory,
            nowTs: now.timeIntervalSince1970,
            pollInterval: pollInterval
        ) else {
            return nil
        }
        return Activation(
            bundleId: resolved.bundleId,
            name: resolved.name,
            isSelf: resolved.isSelf,
            at: Date(timeIntervalSince1970: resolved.activatedAt)
        )
    }
}
