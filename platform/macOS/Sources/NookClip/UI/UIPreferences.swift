import Foundation

/// 列表行选中态的视觉呈现风格（FR-004 · 偏好配置）
public enum RowSelectionStyle: String, CaseIterable, Identifiable, Sendable {
    /// 经典系统强调色：实色系统强调胶囊 (跟随 macOS 强调色) + 白色反白文字
    case solidAccent
    /// 现代柔和微底：14% 半透明强调色微底 + 深色文字 + 左缘 3pt 强调竖线
    case subtleAccent

    public var id: String { rawValue }
}


/// 时间维度快速跳转交互模式（FR-006 · 偏好配置）
public enum TimelineJumpMode: String, CaseIterable, Identifiable, Sendable {
    /// 优化微型锚点轨：右边缘保留极简点轨 + 气泡 HUD
    case indexRail
    /// 组头下拉整合：吸顶时间组头集成快速跳转菜单，右边缘纯净
    case groupHeaderMenu

    public var id: String { rawValue }
}
