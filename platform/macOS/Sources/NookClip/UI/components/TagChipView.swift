import SwiftUI

// MARK: - 标签胶囊（Tag Chip）·「墨迹元信息」风格
//
// 标签不是按钮，是元信息。这里的原则：
// - 无描边（描边是 52pt 行里最吵的视觉重音）
// - 仅极浅底（`NookClip.tagBg`）或纯文字承托，`#` 用更淡的 `tagHash`
// - 强调（选中/悬停）才给 accent 文字 + 极淡强调底
// - `+`（添加）不与之同级：用行尾 ghost 按钮，悬停才显形
//
// 三处复用：
// - 行内副行迷你档（`.mini`）：极小字号，仅在悬停/选中行出现，不撑高行
// - 筛选/预览紧凑档（`.compact`）
// - 编辑器/预览常规档（`.regular`）：可带移除 ×
//
// 支持选中态、悬停移除 ×、单选（isSelected）与批量三态（isPartial 半选标记）。

enum TagChipSize {
    /// 行内副行迷你档：最小字号，用副行空间，不改变行高
    case mini
    /// 紧凑档
    case compact
    /// 预览区/编辑器常规档
    case regular

    var font: Font {
        switch self {
        case .mini: return .system(size: 10, weight: .regular)
        case .compact: return .nookClipMeta
        case .regular: return .nookClipMetaMedium
        }
    }

    /// `#` 前缀比正文再小一号，视觉弱化
    var hashFont: Font {
        switch self {
        case .mini: return .system(size: 10, weight: .regular)
        case .compact: return .nookClipMeta
        case .regular: return .nookClipMeta
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .mini: return 4
        case .compact: return 7
        case .regular: return 8
        }
    }

    var height: CGFloat {
        switch self {
        case .mini: return 14
        case .compact: return 20
        case .regular: return 22
        }
    }

    var removeIconSize: CGFloat {
        switch self {
        case .mini: return 6.5
        case .compact: return 8
        case .regular: return 8.5
        }
    }
}

/// 极简 #tag 胶囊（墨迹风）。`onTap` 为空时仅展示（不可点）。
struct TagChipView: View {
    let tag: String
    var size: TagChipSize = .compact
    var isSelected: Bool = false
    /// 批量三态：部分选中（半选标记，底部实心小点）
    var isPartial: Bool = false
    /// 悬停时展示移除 ×（仅当 onRemove != nil）
    var onRemove: (() -> Void)? = nil
    var onTap: (() -> Void)? = nil

    @State private var isHovered = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size.height / 2, style: .continuous)
    }

    var body: some View {
        let content = HStack(spacing: 1) {
            Text("#")
                .font(size.hashFont)
                .foregroundStyle(hashColor)
            Text(tag)
                .font(size.font)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(foregroundColor)
            if isPartial {
                Circle()
                    .fill(NookClip.accent)
                    .frame(width: 4, height: 4)
                    .padding(.leading, 1)
            }
            if let onRemove, isHovered {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: size.removeIconSize, weight: .semibold))
                        .foregroundStyle(foregroundColor.opacity(0.6))
                        .frame(width: size.removeIconSize + 4, height: size.removeIconSize + 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .padding(.leading, 1)
            }
        }
        .padding(.horizontal, size.horizontalPadding)
        .frame(height: size.height)
        .background(background)
        .contentShape(shape)

        if let onTap {
            Button(action: onTap) { content }
                .buttonStyle(.plain)
                .focusable(false)
                .onHover { isHovered = $0 }
                .animation(NookClip.animHover, value: isHovered)
        } else {
            content
                .onHover { isHovered = $0 }
                .animation(NookClip.animHover, value: isHovered)
        }
    }

    private var foregroundColor: Color {
        if isSelected { return NookClip.tagTextActive }
        return isHovered ? NookClip.textPrimary : NookClip.tagText
    }

    private var hashColor: Color {
        if isSelected { return NookClip.accent.opacity(0.55) }
        return NookClip.tagHash
    }

    @ViewBuilder
    private var background: some View {
        if isSelected {
            shape.fill(NookClip.tagBgSelected)
        } else if isHovered {
            shape.fill(NookClip.tagBgHover)
        } else {
            shape.fill(NookClip.tagBg)
        }
    }
}

/// 行内副行迷你标签串（默认始终展示）：
/// - 列表行内始终显示，便于一眼看到条目标签；`isActive` 仅保留为可选开关
/// - 最多 `maxVisible` 个，超出显示 `+N`
/// - 纯文字、无边框，贴合副行，不改变行高
struct RowTagsInlineView: View {
    let tags: [String]
    var maxVisible: Int = 2
    var isSolidSelected: Bool = false
    /// 是否展示（默认 true = 始终显示；置 false 可隐藏，供特殊场景使用）
    var isActive: Bool = true

    var body: some View {
        if !tags.isEmpty && isActive {
            HStack(spacing: 6) {
                ForEach(Array(tags.prefix(maxVisible)), id: \.self) { tag in
                    HStack(spacing: 0.5) {
                        Text("#")
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(isSolidSelected ? NookClip.textOnAccentTertiary : NookClip.tagHash)
                        Text(tag)
                            .font(.system(size: 10, weight: .regular))
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundStyle(isSolidSelected ? NookClip.textOnAccentSecondary : NookClip.tagText)
                    }
                }
                if tags.count > maxVisible {
                    Text("+\(tags.count - maxVisible)")
                        .font(.system(size: 10, weight: .regular))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(isSolidSelected ? NookClip.textOnAccentTertiary : NookClip.textDisabled)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .transition(.opacity)
        }
    }
}
