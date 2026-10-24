import AppKit
import SwiftUI


/// 立即单击识别器：单击当次即判定（零延迟），双击按时间间隔补判。
/// 替代 `.onTapGesture(count: 2)` + `.onTapGesture` 组合——两个手势共存时
/// SwiftUI 为消歧，单击要等满双击判定窗口（系统默认 0.5s）才回调，
/// 列表点击选中因此有可感知延迟。双击语义随之变为「第一击先执行单击
/// 动作，第二击执行双击动作」（与 Finder 双击先选中后打开一致）
struct ImmediateTapDetector {
    enum Kind: Equatable {
        case single
        case double
    }

    private var lastTapAt: Date?

    /// 登记一次点击并立即返回判定：
    /// - isSelected == false：属于切换选中记录的点击，恒为 single 且不开启双击窗口（避免快速切换被误判为粘贴）
    /// - isSelected == true 且距上次点击 < interval → double
    mutating func register(
        isSelected: Bool = true,
        at date: Date = Date(),
        interval: TimeInterval = NSEvent.doubleClickInterval
    ) -> Kind {
        guard isSelected else {
            lastTapAt = nil
            return .single
        }
        if let last = lastTapAt, date.timeIntervalSince(last) < interval {
            lastTapAt = nil
            return .double
        }
        lastTapAt = date
        return .single
    }

    /// 显式重置点击时间窗口（如行失去焦点/失去选中时调用）
    mutating func reset() {
        lastTapAt = nil
    }
}

// MARK: - 标准列表行（52px · 单选/批量双形态 · specs/001-new-ui-cutover/T013）
// 迁移自 nook-swiftui 原型 MainView.swift 的 ClipboardRowView；
// 视觉规格逐项不变，仅替换数据类型（ClipboardItem → ClipboardRowModel）。

/// 行形态
enum RowStyle {
    /// 单选态：点击行选中，右列联动预览
    case single
    /// 多选态：勾选圈 + 删除中淡出（删除动效由后续批量删除故事接线）
    case batch(isChecked: Bool, isRemoving: Bool)
}

/// 通用列表行视觉与交互外壳（52px · 单选/批量双形态 · 局部悬停 · 零延迟单双击 · 行内重命名）：
/// 将行级背景动画（`solidAccent` / `subtleAccent`）、`ImmediateTapDetector` 手势消歧、
/// 批量勾选框与重命名输入框封装为与业务模型无关的容器。
/// 剪贴板行（`ClipboardRowView`）及未来的笔记行、待办行均可直接填入插槽复用。
struct NookClipRowShell<Leading: View, Title: View, TitleAccessory: View, Subtitle: View>: View {
    let isSelected: Bool
    var selectionNamespace: Namespace.ID? = nil
    var style: RowStyle = .single
    /// 未选中且未悬停时的特殊行底色（例如剪贴板敏感条目的微橙色底；默认 nil 透明）
    var restingTintBackground: Color? = nil
    var isFavorite: Bool = false
    var timestampText: String? = nil
    /// 点击时间戳后切换展示的完整时间文本（nil = 不可切换，行为与原先一致）
    var timestampDetailedText: String? = nil
    var accessibilitySummary: String = ""
    var isRenaming: Bool = false
    var renameInitialText: String = ""
    var onRenameCommit: ((String) -> Void)? = nil
    var onRenameCancel: (() -> Void)? = nil
    var onTap: (() -> Void)? = nil
    var onDoubleTap: (() -> Void)? = nil
    @ViewBuilder var leading: (_ isSolidSelected: Bool) -> Leading
    @ViewBuilder var title: (_ isSolidSelected: Bool) -> Title
    @ViewBuilder var titleAccessory: (_ isSolidSelected: Bool) -> TitleAccessory
    /// 副行：入参为（是否实底选中，是否活跃=悬停或选中）。后者供行内标签等
    /// 「静止不显、悬停才露」的次级信息决定显隐。
    @ViewBuilder var subtitle: (_ isSolidSelected: Bool, _ isActive: Bool) -> Subtitle

    /// 悬停态自持（审查 R7/Perf-1，spec FR-007）：由行内局部化，不触发父树重求值
    @State private var isHovered = false
    /// 时间戳展示态：false = 相对时间（默认），true = 完整日期 + 周几 + 时间；点击时间戳来回切换
    @State private var showsDetailedTimestamp = false
    /// 立即单击/双击判定（时间间隔自判，替代双 onTapGesture 组合的消歧等待）
    @State private var tapDetector = ImmediateTapDetector()
    /// 选中行高亮风格（偏好设置驱动）
    @AppStorage(UserDefaultsKey.rowSelectionStyle.rawValue)
    private var selectionStyleRaw: String = RowSelectionStyle.subtleAccent.rawValue

    private var selectionStyle: RowSelectionStyle {
        RowSelectionStyle(rawValue: selectionStyleRaw) ?? .subtleAccent
    }

    private var isSolidSelected: Bool {
        isSelected && selectionStyle == .solidAccent
    }

    private var isRemoving: Bool {
        if case .batch(_, let removing) = style { return removing }
        return false
    }

    var body: some View {
        HStack(spacing: 8) {
            if case .batch = style {
                checkbox
            }
            leading(isSolidSelected)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if isRenaming {
                        RowRenameField(
                            initialText: renameInitialText,
                            onCommit: { onRenameCommit?($0) },
                            onCancel: { onRenameCancel?() },
                            isOnSolidAccentRow: isSolidSelected
                        )
                    } else {
                        title(isSolidSelected)
                    }
                    titleAccessory(isSolidSelected)
                    if isFavorite && !isRenaming {
                        Spacer(minLength: 4)
                        Image(systemName: NookClipIcon.Badge.favorite)
                            .font(.system(size: NookClipIconSize.compact))
                            .foregroundStyle(isSolidSelected ? NookClip.textOnAccent : NookClip.colorFavorite)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    subtitle(isSolidSelected, isHovered || isSelected)
                    Spacer(minLength: 8)
                    if let timestampText, !timestampText.isEmpty {
                        timestampLabel(timestampText, isSolidSelected: isSolidSelected)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(height: NookClip.heightRowList)
        .frame(maxWidth: .infinity)
        .background(rowBackground)
        .opacity(isRemoving ? 0.45 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(effectiveAccessibilitySummary)
        .onTapGesture {
            guard !isRenaming else { return }
            switch tapDetector.register(isSelected: isSelected) {
            case .single: onTap?()
            case .double: onDoubleTap?()
            }
        }
        .onChange(of: isSelected) { _, selected in
            if !selected {
                tapDetector.reset()
            }
        }
        .onChange(of: timestampDetailedText) { _, _ in
            showsDetailedTimestamp = false
        }
        .onChange(of: timestampText) { _, _ in
            showsDetailedTimestamp = false
        }
        .onHover { isHovered = $0 }
        .animation(NookClip.animHover, value: isHovered)
    }

    private var effectiveAccessibilitySummary: String {
        guard showsDetailedTimestamp,
              let compact = timestampText, !compact.isEmpty,
              let detailed = timestampDetailedText, !detailed.isEmpty else {
            return accessibilitySummary
        }
        return accessibilitySummary.replacingOccurrences(of: compact, with: detailed)
    }

    /// 行尾时间戳：默认展示相对时间，点击来回切换为「xx月xx日 周几 时间」
    /// （跨年额外带年份）。点击只切换文本，不触发行选中/粘贴。
    @ViewBuilder
    private func timestampLabel(_ compactText: String, isSolidSelected: Bool) -> some View {
        let isToggleable = !(timestampDetailedText?.isEmpty ?? true)
        let text = (showsDetailedTimestamp ? (timestampDetailedText ?? compactText) : compactText)
        let label = Text(text)
            .font(.nookClipMeta)
            .monospacedDigit()
            .foregroundStyle(isSolidSelected ? NookClip.textOnAccentTertiary : NookClip.textTertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .allowsTightening(true)
            .fixedSize()
            .contentShape(Rectangle())
            .onTapGesture {
                guard isToggleable else { return }
                withAnimation(.easeInOut(duration: 0.12)) {
                    showsDetailedTimestamp.toggle()
                }
            }
        if isToggleable {
            label
                .help(L10n.tr("row.time.toggle_hint"))
                .accessibilityHint(L10n.tr("row.time.toggle_hint"))
        } else {
            label
        }
    }

    @ViewBuilder
    private var checkbox: some View {
        if isRemoving {
            Color.clear.frame(width: 16, height: 16)
        } else if case .batch(let checked, _) = style {
            ZStack {
                Circle()
                    .fill(checked ? NookClip.accent : .clear)
                if checked {
                    Image(systemName: NookClipIcon.Control.checkmark)
                        .font(.system(size: NookClipIconSize.micro, weight: .bold))
                        .foregroundStyle(NookClip.textOnAccent)
                }
            }
            .frame(width: 16, height: 16)
            .overlay {
                Circle().strokeBorder(checked ? NookClip.accent : NookClip.borderCheckboxIdle, lineWidth: 1.2)
            }
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: NookClip.radiusCard, style: .continuous)
        ZStack {
            if isHovered && !isSelected {
                shape.fill(NookClip.bgRowHover)
            } else if let restingTintBackground, !isSelected {
                shape.fill(restingTintBackground)
            }

            if case .batch(let checked, _) = style {
                // 批量模式有两个独立事实，视觉必须分开表达：
                //   1. 这一行被勾选了吗 → 勾选态专用强底（可扫视）
                //   2. 右列预览的是哪一行（当前记录 / 锚点）→ 跟随行选中风格偏好，与普通单选选中态一致
                // 注意：锚点(`isSelected`)与勾选(`checked`)并不绑定——取消勾选锚点、↑↓ 导航、
                // shift 扩选后锚点都可能落在未勾选的行上。
                // 当前记录优先：无论是否勾选，当前记录都跟随行选中风格偏好；
                // 仅「已勾选且非当前记录」才用勾选态专用强底。
                if isSelected {
                    // 当前记录（含已勾选）：跟随行选中风格偏好，与普通单选选中态一致
                    singleSelectionBackground(shape)
                    // 额外描边作为唯一锚点标记
                    shape.strokeBorder(NookClip.borderRowSelected, lineWidth: 1)
                } else if checked {
                    // 已勾选但非当前记录：勾选态专用强底（区别于单选高亮）
                    shape.fill(NookClip.bgRowSelectedStrong)
                }
            } else if isSelected {
                singleSelectionBackground(shape)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }

    /// 单选选中态的背景视觉，跟随 `rowSelectionStyle` 偏好：
    /// - `.solidAccent`：实底强调色
    /// - `.subtleAccent`：微底 + 左侧强调色竖条胶囊
    /// 抽出复用于「批量模式下未勾选的当前记录」，保证二者视觉完全一致。
    @ViewBuilder
    private func singleSelectionBackground(_ shape: RoundedRectangle) -> some View {
        switch selectionStyle {
        case .solidAccent:
            shape.fill(NookClip.accent)
        case .subtleAccent:
            shape
                .fill(NookClip.bgRowSelectedSubtle)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(NookClip.accent)
                        .frame(width: 2.5, height: 20)
                        .padding(.leading, 2.5)
                }
        }
    }
}

struct ClipboardRowView: View {
    let item: ClipboardRowModel
    let isSelected: Bool
    var selectionNamespace: Namespace.ID? = nil
    var style: RowStyle = .single
    /// 搜索命中高亮关键词（nil = 非搜索态，纯文本渲染）
    var highlightKeywords: [String]? = nil
    /// 行点击（单选 = 选中；批量 = 切换勾选，由 MainView 分发）
    var onTap: (() -> Void)? = nil
    /// 行双击（列表 = 粘贴该项，与 ⏎ 一致；nil = 无双击行为）
    var onDoubleTap: (() -> Void)? = nil
    /// 行内重命名态（true = 标题位换成 RowRenameField）
    var isRenaming: Bool = false
    /// 重命名提交（文本已 trim + 截断；空串 = title 置空，展示层回退内容预览）
    var onRenameCommit: ((String) -> Void)? = nil
    /// 重命名放弃（Esc）
    var onRenameCancel: (() -> Void)? = nil

    var body: some View {
        NookClipRowShell(
            isSelected: isSelected,
            selectionNamespace: selectionNamespace,
            style: style,
            restingTintBackground: nil,
            isFavorite: item.isFavorite,
            timestampText: item.timestampText,
            timestampDetailedText: item.timestampDetailedText,
            accessibilitySummary: rowAccessibilitySummary,
            isRenaming: isRenaming,
            renameInitialText: item.title,
            onRenameCommit: onRenameCommit,
            onRenameCancel: onRenameCancel,
            onTap: onTap,
            onDoubleTap: onDoubleTap,
            leading: { isSolidSelected in
                leadingSlot(isSolidSelected: isSolidSelected)
                    .overlay(alignment: .bottomTrailing) {
                        SourceCornerBadge(app: item.source)
                    }
            },
            title: { isSolidSelected in
                RowTitleView(
                    item: item,
                    isSolidSelected: isSolidSelected,
                    highlightKeywords: highlightKeywords
                )
            },
            titleAccessory: { isSolidSelected in
                sensitivePill(isSolidSelected: isSolidSelected)
            },
            subtitle: { isSolidSelected, isActive in
                RowSubtitleView(
                    item: item,
                    isSolidSelected: isSolidSelected,
                    isActive: isActive,
                    highlightKeywords: highlightKeywords
                )
            }
        )
    }

    /// T042④：无障碍摘要（标题 / 来源 App / 相对时间，顿号分隔整行朗读）
    private var rowAccessibilitySummary: String {
        [item.displayTitle, item.source.name, item.timestampText]
            .filter { !$0.isEmpty }
            .joined(separator: "、")
    }

    // MARK: 前置槽（缩略图 / 来源 App 图标 · 方案 1）

    @ViewBuilder
    private func leadingSlot(isSolidSelected: Bool) -> some View {
        if item.kind == .image {
            // 真实缩略图（payloadPath 缺失或加载失败时回退占位符）
            if let path = item.payloadPath, !path.isEmpty {
                RowThumbnailView(path: path, isSolidSelected: isSolidSelected)
            } else {
                ThumbnailPlaceholderView(isSolidSelected: isSolidSelected)
            }
        } else if let swatch = item.swatchColor {
            ColorSwatchTile(color: swatch, isSolidSelected: isSolidSelected)
        } else {
            CategoryIconTile(kind: item.kind, isSolidSelected: isSolidSelected)
        }
    }

    // MARK: 敏感胶囊（单行/双行态共用，恒随标题行展示）

    @ViewBuilder
    private func sensitivePill(isSolidSelected: Bool) -> some View {
        if item.kind == .sensitive {
            Text(L10n.tr("category.sensitive"))
                .font(.nookClipBadge)
                .foregroundStyle(isSolidSelected ? NookClip.textOnAccentSecondary : NookClip.colorSensitive.opacity(0.88))
                .fixedSize()
        }
    }
}
