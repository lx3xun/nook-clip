import AppKit
import SwiftUI

// MARK: - ⌘D 行内对比渲染卡片（feature #5 · Phase 3 精简版）
//
// 这一屏要回答一个问题：「这两段文本到底改了哪几个字？」
// 所以用两层表达，缺一不可：
//   1. 整行底色——回答「哪些行变了」（扫一眼就知道改动密度）；
//   2. 行内字词深底色——回答「这一行里到底哪几个字变了」（不用逐字比对）。
// 两层若同浓度，行内精确改动会被整行底色吃掉；删除行再加删除线、新增行再加粗，
// 让「红绿之外」也有第二个可辨信号（红绿色弱用户也能读）。
//
// 视觉与热区纪律：
// - 顶栏严格锁定 `NookClip.heightToolbar`（40pt）单行布局，对齐 `PreviewToolbar`，
//   保证全部按钮落在 `DraggablePanel.hotZonePreviewToolbarHeight` 热区内，绝不与面板拖拽抢手势；
// - 卡片自身不铺不透明实底，直接复用 `MainView` 右列统一的 `nookClipAuroraBackground` 与半透明度；
// - 底部操作统一收口至左列 `DiffSessionHintsBar`（54pt，与 `BatchBar` 同构），
//   右列不设重复底栏，把 100% 纵向空间留给差异内容。

// MARK: - 外观相关的具体色

/// 把动态设计令牌解析成当前环境下的具体颜色（AttributedString 不能存动态色）
private struct DiffPalette {
    let removedWordBg: NSColor
    let addedWordBg: NSColor
    let removedText: NSColor
    let addedText: NSColor

    @MainActor
    static func resolve(in environment: EnvironmentValues) -> DiffPalette {
        DiffPalette(
            removedWordBg: NookClip.diffRemovedWordBg.nsColor(in: environment),
            addedWordBg: NookClip.diffAddedWordBg.nsColor(in: environment),
            removedText: NookClip.diffRemovedText.nsColor(in: environment),
            addedText: NookClip.diffAddedText.nsColor(in: environment)
        )
    }
}

private extension Color {
    @MainActor
    func nsColor(in environment: EnvironmentValues) -> NSColor {
        let r = resolve(in: environment)
        return NSColor(
            srgbRed: CGFloat(r.red),
            green: CGFloat(r.green),
            blue: CGFloat(r.blue),
            alpha: CGFloat(r.opacity)
        )
    }
}

// MARK: - 主卡片

@MainActor
struct DiffPreviewCard: View {
    let session: DiffSessionState
    var onSetViewMode: (DiffViewMode) -> Void = { _ in }
    var onCopyMerged: () -> Void = {}
    var onPasteMerged: () -> Void = {}
    var onClose: () -> Void = {}
    var onPinSide: (UUID) -> Void = { _ in }

    @Environment(\.self) private var environment

    var body: some View {
        let palette = DiffPalette.resolve(in: environment)
        VStack(spacing: 0) {
            DiffToolbar(
                session: session,
                onPinSide: onPinSide,
                onClose: onClose
            )
            .zIndex(1)
            content(palette: palette)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func content(palette: DiffPalette) -> some View {
        if let failure = session.failure {
            failureState(failure)
        } else if session.isComputing {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let result = session.result {
            if result.hunks.isEmpty {
                identicalState
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 10) {
                            DiffSummaryBanner(
                                session: session,
                                onSetViewMode: onSetViewMode
                            )

                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(result.hunks, id: \.id) { hunk in
                                    DiffHunkView(
                                        hunk: hunk,
                                        mode: session.viewMode,
                                        isFocused: session.focusedHunkID == hunk.id,
                                        palette: palette
                                    )
                                    .id("diff-hunk-\(hunk.id)")
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 20)
                    }
                    .onChange(of: session.focusedHunkID) { _, newID in
                        guard let newID else { return }
                        withAnimation(NookClip.animHover) {
                            proxy.scrollTo("diff-hunk-\(newID)", anchor: .center)
                        }
                    }
                }
            }
        } else {
            EmptyView()
        }
    }

    // MARK: 空态 / 完全相同

    private var identicalState: some View {
        VStack(spacing: 8) {
            Image(systemName: NookClipIcon.Action.diff)
                .font(.system(size: NookClipIconSize.titleLarge, weight: .regular))
                .foregroundStyle(NookClip.colorSuccess)
            Text(L10n.tr("diff.stats.identical"))
                .font(.nookClipSubheadMedium)
                .foregroundStyle(NookClip.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failureState(_ failure: DiffFailure) -> some View {
        VStack(spacing: 8) {
            Image(systemName: NookClipIcon.Action.diff)
                .font(.system(size: NookClipIconSize.titleLarge, weight: .regular))
                .foregroundStyle(NookClip.textTertiary)
            Text(MainView.diffMessage(for: failure))
                .font(.nookClipSubhead)
                .foregroundStyle(NookClip.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 顶栏（严格 40pt 单行，对齐 PreviewToolbar 与热区）

private struct DiffToolbar: View {
    let session: DiffSessionState
    let onPinSide: (UUID) -> Void
    let onClose: () -> Void
    @State private var isCloseHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: NookClipIcon.Action.diff)
                .font(.system(size: NookClipIconSize.compactMedium, weight: .semibold))
                .foregroundStyle(NookClip.accent)

            sidePill(
                side: session.oldSide,
                tag: L10n.tr("diff.label.old"),
                title: session.oldSide?.title ?? L10n.tr("diff.label.unknown"),
                tint: NookClip.diffRemovedText,
                bg: NookClip.diffRemovedLineBg
            )

            Text("\u{2192}")
                .font(.nookClipCaption)
                .foregroundStyle(NookClip.textTertiary)

            sidePill(
                side: session.newSide,
                tag: L10n.tr("diff.label.new"),
                title: session.newSide?.title ?? L10n.tr("diff.label.unknown"),
                tint: NookClip.diffAddedText,
                bg: NookClip.diffAddedLineBg
            )
            Spacer(minLength: 4)


            Button(action: onClose) {
                Image(systemName: NookClipIcon.Action.diffClose)
                    .font(.system(size: NookClipIconSize.regular, weight: .regular))
                    .foregroundStyle(isCloseHovered ? NookClip.textPrimary : NookClip.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .onHover { isCloseHovered = $0 }
            .help("\(L10n.tr("diff.action.close"))（Esc / ⌘D）")
            .accessibilityLabel(L10n.tr("diff.action.close"))
        }
        .padding(.horizontal, 20)
        .frame(height: NookClip.heightToolbar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(NookClip.borderHairline).frame(height: 0.5)
        }
    }



    private func sidePill(
        side: DiffSide?,
        tag: String,
        title: String,
        tint: Color,
        bg: Color
    ) -> some View {
        let isPinned = side != nil && session.anchorItemID == side?.itemID
        let helpText = L10n.tr(isPinned ? "diff.side.pinned_help" : "diff.side.pin_help")
        return Button {
            if let id = side?.itemID {
                onPinSide(id)
            }
        } label: {
            HStack(spacing: 4) {
                HStack(spacing: 2) {
                    if isPinned {
                        Image(systemName: NookClipIcon.Action.pinFilled)
                            .font(.system(size: NookClipIconSize.microSmall, weight: .semibold))
                    }
                    Text(tag)
                        .font(.nookClipCaption)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(tint)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(bg, in: RoundedRectangle(cornerRadius: NookClip.radiusThumb, style: .continuous))
                Text(title)
                    .font(.nookClipMetaMedium)
                    .foregroundStyle(NookClip.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 68, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(helpText)
        .accessibilityLabel("\(tag) \(title)")
    }


}

// MARK: - 统计与快捷全选副栏（随内容滚动，清爽单行）

private struct DiffSummaryBanner: View {
    let session: DiffSessionState
    let onSetViewMode: (DiffViewMode) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(session.statsSummary)
                .font(.nookClipMeta)
                .monospacedDigit()
                .foregroundStyle(NookClip.textSecondary)
                .lineLimit(1)

            if session.usesOCRText {
                badge(L10n.tr("diff.badge.ocr"), tint: NookClip.accent)
            }
            if session.containsSensitive {
                badge(L10n.tr("diff.badge.sensitive"), tint: NookClip.colorSensitive)
            }
            if session.result?.stats.isTruncated == true {
                badge(L10n.tr("diff.badge.truncated"), tint: NookClip.textTertiary)
            }

            Spacer(minLength: 4)

            viewModeSegment
        }
        .padding(.horizontal, 2)
    }

    private var viewModeSegment: some View {
        HStack(spacing: 1) {
            modeButton(.inline, label: L10n.tr("diff.view.inline"))
            modeButton(.sideBySide, label: L10n.tr("diff.view.side_by_side"))
            modeButton(.changesOnly, label: L10n.tr("diff.view.changes_only"))
        }
        .padding(2)
        .background(NookClip.bgInset, in: RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous))
    }

    private func modeButton(_ mode: DiffViewMode, label: String) -> some View {
        let isSelected = session.viewMode == mode
        return Button {
            onSetViewMode(mode)
        } label: {
            Text(label)
                .font(.nookClipCaption)
                .fontWeight(isSelected ? .medium : .regular)
                .foregroundStyle(isSelected ? NookClip.textPrimary : NookClip.textTertiary)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(height: 17)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: NookClip.radiusThumb, style: .continuous)
                            .fill(NookClip.bgControlElevated)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(label)
        .accessibilityLabel(label)
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.nookClipCaption)
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                tint.opacity(0.12),
                in: RoundedRectangle(cornerRadius: NookClip.radiusThumb, style: .continuous)
            )
    }
}

// MARK: - 单个差异块

private struct DiffHunkView: View {
    let hunk: FfiDiffHunk
    let mode: DiffViewMode
    let isFocused: Bool
    let palette: DiffPalette

    var body: some View {
        if hunk.isChange {
            changeCard
        } else {
            contextBody
        }
    }

    private var changeCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if mode == .sideBySide {
                sideBySideBody
            } else {
                inlineBody
            }
        }
        .background {
            RoundedRectangle(cornerRadius: NookClip.radiusCard, style: .continuous)
                .fill(NookClip.bgCode)
        }
        .clipShape(RoundedRectangle(cornerRadius: NookClip.radiusCard, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: NookClip.radiusCard, style: .continuous)
                .strokeBorder(
                    isFocused ? NookClip.diffFocusedHunkBorder : NookClip.borderHairline,
                    lineWidth: isFocused ? 1.0 : 0.5
                )
        }
    }


    // MARK: 行内视图（默认）

    private var inlineBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                DiffLineRow(
                    oldNo: line.oldLineNo,
                    newNo: line.newLineNo,
                    tag: line.tag,
                    text: DiffTextBuilder.attributed(line.spans, palette: palette)
                )
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: 左右分栏视图（Split / Side-by-Side）

    private var sideBySideBody: some View {
        let oldLines = hunk.lines.filter { $0.tag == .delete }
        let newLines = hunk.lines.filter { $0.tag == .insert }
        let rowCount = max(oldLines.count, newLines.count)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<rowCount, id: \.self) { index in
                HStack(alignment: .top, spacing: 0) {
                    if index < oldLines.count {
                        let line = oldLines[index]
                        DiffSplitCell(
                            lineNo: line.oldLineNo,
                            tag: .delete,
                            text: DiffTextBuilder.attributed(line.spans, palette: palette)
                        )
                    } else {
                        DiffSplitEmptyCell()
                    }
                    Rectangle()
                        .fill(NookClip.borderHairline)
                        .frame(width: 0.5)
                    if index < newLines.count {
                        let line = newLines[index]
                        DiffSplitCell(
                            lineNo: line.newLineNo,
                            tag: .insert,
                            text: DiffTextBuilder.attributed(line.spans, palette: palette)
                        )
                    } else {
                        DiffSplitEmptyCell()
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: 上下文块

    @ViewBuilder
    private var contextBody: some View {
        if mode == .changesOnly {
            HStack(spacing: 4) {
                Image(systemName: NookClipIcon.Action.diffJump)
                    .font(.system(size: NookClipIconSize.micro, weight: .semibold))
                Text(L10n.tr("diff.context.folded", String(hunk.newLines.count)))
                    .font(.nookClipCaption)
            }
            .foregroundStyle(NookClip.textTertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
        } else if mode == .sideBySide {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(hunk.newLines.enumerated()), id: \.offset) { offset, newText in
                    let oldText = offset < hunk.oldLines.count ? hunk.oldLines[offset] : newText
                    let oldAttr = AttributedString(oldText.isEmpty ? " " : oldText)
                    let newAttr = AttributedString(newText.isEmpty ? " " : newText)
                    HStack(alignment: .top, spacing: 0) {
                        DiffSplitCell(
                            lineNo: hunk.oldLineStart &+ UInt32(offset),
                            tag: .equal,
                            text: oldAttr
                        )
                        Rectangle()
                            .fill(NookClip.borderHairline)
                            .frame(width: 0.5)
                        DiffSplitCell(
                            lineNo: hunk.newLineStart &+ UInt32(offset),
                            tag: .equal,
                            text: newAttr
                        )
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: NookClip.radiusCard, style: .continuous)
                    .fill(NookClip.bgCode.opacity(0.65))
            }
            .clipShape(RoundedRectangle(cornerRadius: NookClip.radiusCard, style: .continuous))
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(hunk.newLines.enumerated()), id: \.offset) { offset, text in
                    DiffLineRow(
                        oldNo: hunk.oldLineStart &+ UInt32(offset),
                        newNo: hunk.newLineStart &+ UInt32(offset),
                        tag: .equal,
                        text: AttributedString(text.isEmpty ? " " : text)
                    )
                }
            }
            .padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: NookClip.radiusCard, style: .continuous)
                    .fill(NookClip.bgCode.opacity(0.65))
            }
            .clipShape(RoundedRectangle(cornerRadius: NookClip.radiusCard, style: .continuous))
        }
    }
}

// MARK: - Split（左右分栏）单侧单元格

/// Split 视图单侧行：只带本侧 1 列行号（20pt），省掉另一侧空行号列，给窄分栏腾出更多正文宽度。
private struct DiffSplitCell: View {
    let lineNo: UInt32
    let tag: FfiDiffTag
    let text: AttributedString

    private var rowBackground: Color {
        switch tag {
        case .delete: return NookClip.diffRemovedLineBg
        case .insert: return NookClip.diffAddedLineBg
        case .equal: return .clear
        }
    }

    private var gutterTint: Color {
        switch tag {
        case .delete: return NookClip.diffRemovedGutter
        case .insert: return NookClip.diffAddedGutter
        case .equal: return NookClip.textTertiary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(lineNo == 0 ? "" : String(lineNo))
                .font(.nookClipMono(9.5))
                .monospacedDigit()
                .foregroundStyle(gutterTint)
                .lineLimit(1)
                .frame(width: 20, alignment: .trailing)
                .padding(.vertical, 1.5)

            Text(text)
                .font(.nookClipMono(11))
                .foregroundStyle(NookClip.textPrimary)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 6)
                .padding(.trailing, 8)
                .padding(.vertical, 1.5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(rowBackground)
    }
}

/// Split 视图中另一侧多出/缺失行时的等高占位格
private struct DiffSplitEmptyCell: View {
    var body: some View {
        Rectangle()
            .fill(NookClip.bgInset.opacity(0.35))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 18)
    }
}

// MARK: - 单行

/// 一行差异：旧行号 + 新行号 + 文本。整行底色回答「这行变了」，
/// 字词深底色回答「这行里哪几个字变了」。
private struct DiffLineRow: View {
    let oldNo: UInt32
    let newNo: UInt32
    let tag: FfiDiffTag
    let text: AttributedString

    private var rowBackground: Color {
        switch tag {
        case .delete: return NookClip.diffRemovedLineBg
        case .insert: return NookClip.diffAddedLineBg
        case .equal: return .clear
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            gutter(oldNo, tint: tag == .delete ? NookClip.diffRemovedGutter : NookClip.textTertiary, width: 24)
            gutter(newNo, tint: tag == .insert ? NookClip.diffAddedGutter : NookClip.textTertiary, width: 24)
            Text(text)
                .font(.nookClipMono(11.5))
                .foregroundStyle(NookClip.textPrimary)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 8)
                .padding(.trailing, 10)
                .padding(.vertical, 1.5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(rowBackground)
    }

    /// 行号：0 表示这一侧没有此行（删除行没有新行号，反之亦然），留空不写 0
    private func gutter(_ number: UInt32, tint: Color, width: CGFloat) -> some View {
        Text(number == 0 ? "" : String(number))
            .font(.nookClipMono(10))
            .monospacedDigit()
            .foregroundStyle(tint)
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
            .padding(.vertical, 1.5)
    }
}



// MARK: - 行内富文本构建（字词级深底色 + 删除线 / 加粗）

private enum DiffTextBuilder {
    @MainActor
    static func attributed(_ spans: [FfiDiffSpan], palette: DiffPalette) -> AttributedString {
        var out = AttributedString()
        for span in spans where !span.text.isEmpty {
            var part = AttributedString(span.text)
            switch span.tag {
            case .equal:
                break
            case .delete:
                if span.emphasized {
                    part.backgroundColor = palette.removedWordBg
                    part.strikethroughStyle = .single
                    part.strikethroughColor = palette.removedText
                } else {
                    part.foregroundColor = palette.removedText
                }
            case .insert:
                if span.emphasized {
                    part.backgroundColor = palette.addedWordBg
                    part.inlinePresentationIntent = .stronglyEmphasized
                } else {
                    part.foregroundColor = palette.addedText
                }
            }
            out.append(part)
        }
        if out.characters.isEmpty {
            return AttributedString(" ")
        }
        return out
    }
}

// MARK: - 左侧列表底部的对比态操作栏（54pt，与 BatchBar 完全同构）

/// 对比态激活时替换 `BatchBar` / `HintsFooterView`：
/// - 落在左列底部 54pt 热区（`DraggablePanel.isInteractiveArea` 原生放行，点击零穿透）；
/// - 主按钮「粘贴合并版 ⏎」吃满剩余宽度，次按钮「复制合并版 ⌘C」与「退出 Esc」并排，
///   消除此前左列与右列双底栏重复展示同一组操作的问题。
struct DiffSessionHintsBar: View {
    var onPasteMerged: () -> Void = {}
    var onCopyMerged: () -> Void = {}
    let onClose: () -> Void

    @State private var isPasteHovered = false

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: NookClipIcon.Action.diff)
                    .font(.system(size: NookClipIconSize.micro, weight: .semibold))
                    .foregroundStyle(NookClip.accent)
                Text(L10n.tr("diff.bar.title"))
                    .font(.nookClipSubheadMedium)
                    .foregroundStyle(NookClip.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                HStack(spacing: 6) {
                    HStack(spacing: 3) {
                        KbdView(text: "↑↓", fontSize: 9)
                        Text(L10n.tr("diff.hint.switch"))
                            .font(.nookClipCaption)
                            .foregroundStyle(NookClip.textTertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    HStack(spacing: 3) {
                        KbdView(text: "⌥↑↓", fontSize: 9)
                        Text(L10n.tr("diff.hint.jump"))
                            .font(.nookClipCaption)
                            .foregroundStyle(NookClip.textTertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                }
            }

            HStack(spacing: 4) {
                Button(action: onPasteMerged) {
                    HStack(spacing: 5) {
                        Image(systemName: NookClipIcon.Action.merge)
                            .font(.system(size: NookClipIconSize.compactMedium, weight: .medium))
                        Text(L10n.tr("diff.action.paste_merged"))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        KbdView(text: "⏎", fontSize: 9)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .font(.nookClipSubheadMedium)
                    .foregroundStyle(NookClip.accent)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                    .background {
                        RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                            .fill(isPasteHovered ? NookClip.bgRowSelected : NookClip.bgChipSelected)
                            .overlay {
                                RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                                    .strokeBorder(NookClip.borderRowSelectedSubtle, lineWidth: 0.5)
                            }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .onHover { hovering in
                    withAnimation(NookClip.animHover) { isPasteHovered = hovering }
                }
                .accessibilityLabel(L10n.tr("diff.action.paste_merged"))

                BatchActionButton(
                    title: L10n.tr("diff.action.copy_merged"),
                    shortcut: "⌘C",
                    role: .primary,
                    action: onCopyMerged
                )

                BatchActionButton(
                    title: L10n.tr("diff.action.close"),
                    shortcut: "Esc",
                    role: .primary,
                    action: onClose
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(height: 54)
        .background(NookClip.bgFooter)
    }
}
