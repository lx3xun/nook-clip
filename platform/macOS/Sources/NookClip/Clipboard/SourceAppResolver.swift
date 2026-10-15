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

    /// 解析当前剪贴板变化的来源应用；无可用记录（NookClip 刚启动）返回 nil。
    /// NookClip 自身驻留超过一个周期时如实返回 NookClip（面板内选中复制、NookClip 触发的
    /// 钥匙串等系统弹窗均属此类，归因到之前的外部应用反而是错的）。
    func resolve(now: Date = Date()) -> Activation? {
        // NookClip 面板已驻留超过一个周期：变化必然发生在 NookClip 前台期间
        // （面板内选中复制、NookClip 触发的钥匙串等系统弹窗），如实标注为 NookClip
        if let last = history.last,
           last.isSelf,
           now.timeIntervalSince(last.at) >= pollInterval {
            return last
        }

        var idx = history.index(before: history.endIndex)
        while idx >= history.startIndex, history[idx].isSelf {
            idx = history.index(before: idx)
        }
        guard idx >= history.startIndex else { return nil }
        let current = history[idx]

        // 当前应用已驻留超过一个轮询周期：变化必然发生在它前台期间
        if now.timeIntervalSince(current.at) >= pollInterval {
            return current
        }

        // 激活不足一个周期（复制后快速切换）：归因到切换前的前台应用
        var prev = history.index(before: idx)
        while prev >= history.startIndex, history[prev].isSelf {
            prev = history.index(before: prev)
        }
        return prev >= history.startIndex ? history[prev] : current
    }
}
