import Foundation

/// 历史条数上限策略——全应用唯一来源（默认条数、用户设置读取）。
///
/// 语义约定：
/// - 用户从未设置过 `historyMaxItemCount` → 默认 500 条；
/// - 「无限制」已退役：设置界面与所有存储值都被收敛到 `1...hardCap`。
///   0/负数（旧版「无限制」）与超上限值一律收敛到 `hardCap`，尽可能多保留；
/// - 按条数裁剪只针对非收藏、无标签的活跃条目，超限时淘汰最久未使用的；
/// - 按「历史保留天数」清理的维度已退役（旧键 `historyRetentionDays` 仅供一次性迁移读取）。
/// - 启动维护、周期维护与设置改动必须读取同一策略，不得各自硬编码。
struct HistoryMaxItemsPolicy {
    /// UserDefaults 键（历史最大记录条数，用户路径取值恒在 `1...hardCap`）
    static let defaultsKey = "historyMaxItemCount"
    /// 已退役的「历史保留天数」键：仅用于把「旧版显式关闭清理」的用户迁移为硬上限
    static let legacyRetentionDaysKey = "historyRetentionDays"
    /// 性能基准专用开关（仅 `NOOK_PERF=1` 基准使用）：为 true 时不按条数裁剪，
    /// 用于测量万级规模下读写路径的真实开销（此时库规模远超产品上限）。
    /// 设置界面不提供该档位，真实用户路径恒被收敛到 `1...hardCap`。
    static let benchmarkUnlimitedKey = "nook.benchmarkUnlimitedHistory"
    /// 全应用唯一默认条数上限
    static let defaultMaxItems = 500
    /// 条数硬上限：设置界面最高档位，也是任何用户值的收敛上界（「无限制」已退役）
    static let hardCap = 1000
    /// 设置界面可选档位（不含「无限制」，最高档即 `hardCap`）
    static let presets = [100, 200, 500, hardCap]

    /// 用户有效条数上限；`nil` 仅出现在性能基准专用开关下（不裁剪）
    let maxItems: Int?

    /// 收敛任意用户输入到合法区间：0/负数（旧版「无限制」）→ 硬上限；超上限 → 硬上限
    static func clamp(_ raw: Int) -> Int {
        raw <= 0 ? hardCap : min(raw, hardCap)
    }

    /// 显式指定条数（0 或负数按旧版「无限制」语义收敛为硬上限）
    init(maxItems: Int) {
        self.maxItems = Self.clamp(maxItems)
    }

    /// 从 UserDefaults 读取：未设置 = 默认 500；其余值一律收敛到 `1...hardCap`。
    ///
    /// 迁移规则：旧版把 `historyRetentionDays` 显式设为 0 的用户当时得到的是
    /// 「完全不清理」，条数维度不再提供无限制，迁移为硬上限（而非默认 500），
    /// 使其被裁剪的幅度最小。
    init(defaults: UserDefaults) {
        if defaults.bool(forKey: Self.benchmarkUnlimitedKey) {
            self.maxItems = nil
            return
        }
        if let raw = defaults.object(forKey: Self.defaultsKey) as? Int {
            self.maxItems = Self.clamp(raw)
            return
        }
        if let legacyDays = defaults.object(forKey: Self.legacyRetentionDaysKey) as? Int,
           legacyDays <= 0 {
            self.maxItems = Self.hardCap
            return
        }
        self.maxItems = Self.defaultMaxItems
    }
}

/// 磁盘空间上限策略——全应用唯一来源（默认上限、用户设置读取）。
///
/// 语义约定：
/// - 用户从未设置过 `historyDiskLimitMB` → 默认 5GB（5120 MB）；
/// - 「无限制」已退役：任何存储值都被收敛到 `1...hardCapMB`，
///   0/负数（旧版「无限制」）与超上限值一律收敛到最大档 `hardCapMB`；
/// - 启动维护与定时淘汰必须读取同一策略。
struct DiskLimitPolicy {
    /// UserDefaults 键（磁盘空间上限，单位 MB，取值恒在 `1...hardCapMB`）
    static let defaultsKey = "historyDiskLimitMB"
    /// 全应用唯一默认磁盘上限（5GB = 5120 MB）
    static let defaultLimitMB = 5120
    /// 磁盘上限最大档（20GB = 20480 MB，「无限制」已退役）
    static let hardCapMB = 20480
    /// 设置界面可选档位（512MB / 1GB / 2GB / 5GB / 10GB / 20GB，不含「无限制」）
    static let presets = [512, 1024, 2048, defaultLimitMB, 10240, hardCapMB]

    /// 用户有效磁盘上限（MB）；恒在 `1...Self.hardCapMB`
    let limitMB: Int

    /// 收敛任意输入到合法区间：0/负数（旧版「无限制」）→ 最大档；超上限 → 最大档
    static func clamp(_ raw: Int) -> Int {
        raw <= 0 ? hardCapMB : min(raw, hardCapMB)
    }

    /// 显式指定限额（0 或负数按旧版「无限制」语义收敛为最大档）
    init(limitMB: Int) {
        self.limitMB = Self.clamp(limitMB)
    }

    /// 从 UserDefaults 读取：未设置 = 默认 5120 MB；其余值一律收敛到 `1...hardCapMB`
    init(defaults: UserDefaults) {
        guard let raw = defaults.object(forKey: DiskLimitPolicy.defaultsKey) as? Int else {
            self.limitMB = DiskLimitPolicy.defaultLimitMB
            return
        }
        self.limitMB = DiskLimitPolicy.clamp(raw)
    }

    /// 转换为字节数
    var maxDiskBytes: UInt64 {
        UInt64(limitMB) * 1024 * 1024
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
