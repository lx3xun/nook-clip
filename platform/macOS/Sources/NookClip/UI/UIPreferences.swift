import Foundation

/// 列表行选中态的视觉呈现风格（FR-004 · 偏好配置）
public enum RowSelectionStyle: String, CaseIterable, Identifiable, Sendable {
    /// 经典系统强调色：实色系统强调胶囊 (跟随 macOS 强调色) + 白色反白文字
    case solidAccent
    /// 现代柔和微底：14% 半透明强调色微底 + 深色文字 + 左缘 3pt 强调竖线
    case subtleAccent

    public var id: String { rawValue }
}

