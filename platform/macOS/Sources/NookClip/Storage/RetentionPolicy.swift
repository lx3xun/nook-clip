import Foundation

/// 保留期策略——全应用唯一来源（默认天数、用户设置读取、截止时间计算）。
///
/// 语义约定（与既有行为一致）：
/// - 用户从未设置过 `historyRetentionDays` → 默认半年（180 天）；
/// - 用户显式设为 0（或负数）→ 无限制（不按保留期清理/裁剪）；
/// - 拉取合并窗口与云端清理窗口必须读取同一策略，不得各自硬编码。
struct RetentionPolicy {
    /// UserDefaults 键（历史保留天数；0 = 无限制）
    static let defaultsKey = "historyRetentionDays"
    /// 全应用唯一默认保留天数（半年 = 180 天）
    static let defaultDays = 180
    /// 用户有效保留天数；`nil` 表示无限制
    let days: Int?

    /// 显式指定天数（0 或负数视为无限制）
    init(days: Int) {
        self.days = days > 0 ? days : nil
    }

    /// 从 UserDefaults 读取：未设置 = 默认 180；0/负数 = 无限制
    init(defaults: UserDefaults) {
        guard let raw = defaults.object(forKey: RetentionPolicy.defaultsKey) as? Int else {
            self.days = RetentionPolicy.defaultDays
            return
        }
        self.days = raw > 0 ? raw : nil
    }

    /// 保留期截止时间点；无限制时返回 nil（调用方跳过按保留期的裁剪）
    func cutoff(now: Date = Date()) -> Date? {
        days.map { now.addingTimeInterval(-Double($0 * 86400)) }
    }
}

/// 磁盘空间上限策略——全应用唯一来源（默认上限、用户设置读取）。
///
/// 语义约定：
/// - 用户从未设置过 `historyDiskLimitMB` → 默认 5GB（5120 MB）；
/// - 用户显式设为 0（或负数）→ 无限制（不按磁盘配额清理淘汰）；
/// - 启动维护与定时淘汰必须读取同一策略。
struct DiskLimitPolicy {
    /// UserDefaults 键（磁盘空间上限，单位 MB；0 = 无限制）
    static let defaultsKey = "historyDiskLimitMB"
    /// 全应用唯一默认磁盘上限（5GB = 5120 MB）
    static let defaultLimitMB = 5120

    /// 用户有效磁盘上限（MB）；`nil` 表示无限制
    let limitMB: Int?

    /// 显式指定限额（0 或负数视为无限制）
    init(limitMB: Int) {
        self.limitMB = limitMB > 0 ? limitMB : nil
    }

    /// 从 UserDefaults 读取：未设置 = 默认 5120 MB；0/负数 = 无限制
    init(defaults: UserDefaults) {
        guard let raw = defaults.object(forKey: DiskLimitPolicy.defaultsKey) as? Int else {
            self.limitMB = DiskLimitPolicy.defaultLimitMB
            return
        }
        self.limitMB = raw > 0 ? raw : nil
    }

    /// 转换为字节数；无限制时返回 nil
    var maxDiskBytes: UInt64? {
        guard let limitMB, limitMB > 0 else { return nil }
        return UInt64(limitMB) * 1024 * 1024
    }
}

/// 软删除条目的兜底清除窗口（撤销机制）。
/// 删除不再有回收站入口：UI 撤销窗口（toast 10 秒）过期后，
/// 软删除条目再保留本宽限即彻底清除并写云端墓碑。
/// 本地清理、云端 prune 与启动扫描必须读取同一常量，不得各自硬编码。
enum TrashPurgeWindow {
    /// 撤销窗口过期后的兜底宽限（秒）。须大于撤销 toast 时长，防止仍在
    /// 撤销窗口内的条目被高频写入顺带清理提前清除。
    static let grace: TimeInterval = 60
}
