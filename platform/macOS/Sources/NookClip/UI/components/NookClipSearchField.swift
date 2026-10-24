import SwiftUI
import AppKit

// MARK: - 搜索框（28px · 圆角 6 · 真输入 + @FocusState 聚焦环 · 非空时右侧清空按钮）

/// 搜索框左侧可嵌入的过滤条件胶囊（分类 / 标签）。点击 × 取消该条件。
struct EmbeddedFilterChip {
    enum Kind { case category, tag }
    let kind: Kind
    /// 分类：symbol 图标；标签：`#` 前缀（symbol 为 nil）
    let symbol: String?
    let title: String
    let tint: Color
    let onRemove: () -> Void
}

struct NookClipSearchField: View {
    @Binding var text: String
    var placeholder: String = L10n.tr("search.placeholder")
    /// 外部焦点控制（⌘F 聚焦；nil 时不外部驱动）
    var isFocused: Binding<Bool>?
    /// 左侧嵌入的过滤条件胶囊（分类 / 标签）；空数组 = 无过滤
    var chips: [EmbeddedFilterChip] = []
    /// 是否展示 ⌘F 快捷键角标（有 chips 时让位，避免拥挤）
    var showsShortcutHint: Bool = true
    /// 展开过滤面板时：搜索框改用与面板一致的不透明底纸，与下方面板连成一体
    /// （去掉独立的聚焦浅底与强调下划线，避免在两块面之间出现割裂的线条/色差）
    var isIntegratedWithPanel: Bool = false

    @FocusState private var isFieldFocused: Bool
    @State private var isClearHovered = false

    var body: some View {
        HStack(spacing: NookClip.spaceXS) {
            Image(systemName: NookClipIcon.Search.magnify)
                .font(.system(size: NookClipIconSize.compactMedium, weight: .medium))
                .foregroundStyle(isFieldFocused ? NookClip.accent : NookClip.textTertiary)
                .animation(NookClip.animHover, value: isFieldFocused)

            // 嵌入的过滤条件胶囊（紧贴放大镜右侧，随搜索框一体高度）
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                FilterChipBadge(chip: chip)
            }

            inputField

            accessoryView
        }
        .padding(.leading, NookClip.searchContentLeadingPadding)
        .padding(.trailing, 10)
        .frame(height: NookClip.heightSearch)
        .background {
            if isIntegratedWithPanel {
                // 合成卡场景：搜索框自身不再绘制底纸，由外层贯穿「搜索框 + 面板」的
                // 单张整体形状统一绘制底色与外围阴影（避免两块不透明面互相投影割裂）。
                Color.clear
            } else {
                Rectangle()
                    .fill(isFieldFocused ? NookClip.bgSearchFocused.opacity(0.45) : Color.clear)
                    .animation(NookClip.animHover, value: isFieldFocused)
            }
        }
        .overlay(alignment: .bottom) {
            if !isIntegratedWithPanel {
                Rectangle()
                    .fill(isFieldFocused ? NookClip.accent.opacity(0.35) : Color.clear)
                    .frame(height: 1.0)
                    .animation(NookClip.animHover, value: isFieldFocused)
            }
        }
        .onChange(of: isFieldFocused) { _, focused in
            isFocused?.wrappedValue = focused
        }
        .onChange(of: isFocused?.wrappedValue) { _, focused in
            if let focused, focused != isFieldFocused {
                isFieldFocused = focused
            }
        }
    }

    private var inputField: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.nookClipBody)
            .foregroundStyle(NookClip.textPrimary)
            .lineLimit(1)
            .accessibilityLabel(placeholder)
            .overlay(alignment: .leading) {
                placeholderOverlay
            }
            .focused($isFieldFocused)
    }

    @ViewBuilder
    private var placeholderOverlay: some View {
        if text.isEmpty && chips.isEmpty {
            Text(placeholder)
                .font(.nookClipBody)
                .foregroundStyle(NookClip.textTertiary)
                .lineLimit(1)
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if text.isEmpty && !chips.isEmpty {
            // 已有过滤条件时给出轻提示（不遮挡胶囊）
            Text(L10n.tr("filter.add_keyword_hint"))
                .font(.nookClipBody)
                .foregroundStyle(NookClip.textTertiary)
                .lineLimit(1)
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var accessoryView: some View {
        if !text.isEmpty {
            clearButton
        } else if showsShortcutHint && chips.isEmpty {
            shortcutBadge
                .opacity(isFieldFocused ? 0.45 : 0.88)
                .animation(NookClip.animHover, value: isFieldFocused)
        }
    }

    /// 极简快捷键提示（⌘F 去框化纯排印，与底栏提示语言统一）
    private var shortcutBadge: some View {
        Text("⌘F")
            .font(.nookClipMono(11, .medium))
            .foregroundStyle(NookClip.textTertiary)
            .padding(.trailing, 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var clearButton: some View {
        Button {
            text = ""
        } label: {
            Image(systemName: NookClipIcon.Search.clear)
                .font(.system(size: NookClipIconSize.compactMedium))
                .foregroundStyle(isClearHovered ? NookClip.textSecondary : NookClip.textTertiary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering in
            withAnimation(NookClip.animHover) {
                isClearHovered = hovering
            }
        }
        .help(L10n.tr("search.clear"))
        .accessibilityLabel(L10n.tr("action.clear"))
    }
}

// MARK: - 过滤条件胶囊（嵌在搜索框内 · 分类/标签通用 · 悬停显示 ×）

private struct FilterChipBadge: View {
    let chip: EmbeddedFilterChip
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 3) {
            if let symbol = chip.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(chip.tint)
            } else {
                Text("#")
                    .font(.nookClipMeta)
                    .foregroundStyle(chip.tint.opacity(0.6))
            }
            Text(chip.title)
                .font(.nookClipMeta)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(chip.tint)
            if isHovered {
                Image(systemName: "xmark")
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundStyle(chip.tint.opacity(0.7))
                    .frame(width: 11, height: 11)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background {
            RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                .fill(chip.tint.opacity(0.13))
        }
        .contentShape(RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous))
        .onTapGesture { chip.onRemove() }
        .onHover { isHovered = $0 }
        .animation(NookClip.animHover, value: isHovered)
        .help(L10n.tr("filter.remove_condition"))
    }
}
