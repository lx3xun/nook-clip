import SwiftUI
import AppKit
// MARK: - 搜索框（28px · 圆角 6 · 真输入 + @FocusState 聚焦环 · 非空时右侧清空按钮）

struct NookClipSearchField: View {
    @Binding var text: String
    var placeholder: String = L10n.tr("search.placeholder")
    /// 外部焦点控制（⌘F 聚焦；nil 时不外部驱动）
    var isFocused: Binding<Bool>?
    @FocusState private var isFieldFocused: Bool
    @State private var isClearHovered = false

    var body: some View {
        HStack(spacing: NookClip.spaceXS) {
            Image(systemName: NookClipIcon.Search.magnify)
                .font(.system(size: NookClipIconSize.compactMedium, weight: .medium))
                .foregroundStyle(isFieldFocused ? NookClip.accent : NookClip.textTertiary)
                .animation(NookClip.animHover, value: isFieldFocused)

            inputField

            accessoryView
        }
        .padding(.leading, NookClip.searchContentLeadingPadding)
        .padding(.trailing, 10)
        .frame(height: NookClip.heightSearch)
        .background {
            Rectangle()
                .fill(isFieldFocused ? NookClip.bgSearchFocused.opacity(0.45) : Color.clear)
                .animation(NookClip.animHover, value: isFieldFocused)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isFieldFocused ? NookClip.accent.opacity(0.35) : Color.clear)
                .frame(height: 1.0)
                .animation(NookClip.animHover, value: isFieldFocused)
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
        if text.isEmpty {
            Text(placeholder)
                .font(.nookClipBody)
                .foregroundStyle(NookClip.textTertiary)
                .lineLimit(1)
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    @ViewBuilder
    private var accessoryView: some View {
        if text.isEmpty {
            shortcutBadge
                .opacity(isFieldFocused ? 0.45 : 0.88)
                .animation(NookClip.animHover, value: isFieldFocused)
        } else {
            clearButton
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
