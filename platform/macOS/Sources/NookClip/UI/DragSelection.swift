import CoreGraphics
import Foundation

/// 鼠标拖拽多选的行命中计算与常量（纯几何、无 SwiftUI 依赖，可独立单测）。
///
/// 行坐标由 `RowFramesBox` 持续上报（`nookListColumn` 坐标系，key = 行 id 字符串）。
/// 拖拽时指针只需纵向位置即可决定「拖到了哪一行」：
/// - 指针落在某行区间内 → 命中该行；
/// - 落在行与行之间的缝隙、或拖出可视区上下边缘 → 钳到最近的那一行。
///   这样拖到列表底部之外仍能选到末行，符合直觉。
enum DragSelectionGeometry {
    /// 返回指针 `y` 命中的行 key；`frames` 为空时返回 nil。
    /// 命中规则：行内优先；都未命中时取最近的一行；距离相同取更靠上的一行
    /// （并在同一位置重复上报时保持稳定，避免选区在行接缝处来回跳）。
    static func rowKey(atY y: CGFloat, frames: [String: CGRect]) -> String? {
        var containing: (key: String, distance: CGFloat, minY: CGFloat)?
        var nearest: (key: String, distance: CGFloat, minY: CGFloat)?
        for (key, rect) in frames {
            let minY = rect.minY
            let maxY = rect.maxY
            // 半开区间 [minY, maxY)：相邻两行首尾相接时，交界线处的指针归属下一行，
            // 与自上而下的视觉顺序一致，也让命中结果唯一（不会在接缝处二义）
            let isInside = y >= minY && y < maxY
            let distance: CGFloat
            if isInside {
                distance = abs(y - rect.midY)
            } else if y < minY {
                distance = minY - y
            } else {
                distance = y - maxY
            }
            let candidate = (key: key, distance: distance, minY: minY)
            if isInside {
                containing = better(candidate, than: containing)
            }
            nearest = better(candidate, than: nearest)
        }
        return (containing ?? nearest)?.key
    }

    /// 候选优劣：距离更近者优先；距离相同时更靠上（minY 更小）者优先；
    /// 完全并列时按 key 字典序，保证纯函数在同一输入下恒返回同一行。
    private static func better(
        _ candidate: (key: String, distance: CGFloat, minY: CGFloat),
        than current: (key: String, distance: CGFloat, minY: CGFloat)?
    ) -> (key: String, distance: CGFloat, minY: CGFloat) {
        guard let current else { return candidate }
        if candidate.distance != current.distance {
            return candidate.distance < current.distance ? candidate : current
        }
        if candidate.minY != current.minY {
            return candidate.minY < current.minY ? candidate : current
        }
        return candidate.key < current.key ? candidate : current
    }
}

/// 拖拽多选的手势参数
enum DragSelection {
    /// 启动阈值：位移超过 3pt 才算拖拽，轻点仍然走行单击选中
    static let minimumDistance: CGFloat = 3
    /// 松手后短暂屏蔽点击判定的时长：拖拽结束时系统仍可能补一个单击，
    /// 若放行会把刚选好的整段选区又收敛回单条
    static let tapSuppressWindow: TimeInterval = 0.25
    /// 边缘自动滚动的触发边距：指针进入内容安全区上下 18pt 内即开始滚动
    static let autoScrollEdgeMargin: CGFloat = 18
    /// 边缘自动滚动的步进间隔（毫秒）：一行一停，约 20 行/秒，既连续又不至于太滑
    static let autoScrollIntervalMs: Int = 50
}
