import SwiftUI
import AppKit

// MARK: - 标签编辑器浮层（TagEditorPopover）
//
// 轻量浮层，支持**单选**（编辑单条）与**批量三态**（编辑选中集）两种模式：
// - 输入框实时过滤已有标签候选（从已有标签全集传入，通常为 store.listTags()）
// - ↑↓ 选择候选、⏎ 勾选已有或创建新标签、退格删末尾已选、点击候选切换
// - 可移除当前已选胶囊
// - 批量：共有标签（每个条目都有）可一键移除；部分选中半选标记可补齐；新标签追加给全部
//
// 数据落地由 MainView 决定：组件只发意图回调（onToggleTag / onAddNewTag / onRemoveTag），
// 具体单选/批量如何落库由宿主 map 到 store.setTags/addTag/removeTag。

/// 浮层编辑目标：单选某条 / 批量选中集
enum TagEditTarget: Equatable {
    case single(UUID)
    case batch([UUID])

    var ids: [UUID] {
        switch self {
        case .single(let id): return [id]
        case .batch(let ids): return ids
        }
    }

    var isBatch: Bool {
        if case .batch = self { return true }
        return false
    }
}

/// 一条候选标签的选中状态（单选模式用 checked；批量模式用 triState）
enum TagCandidateState {
    /// 所有目标任务都已有该标签
    case all
    /// 目标任务部分已有（批量半选）
    case partial
    /// 都没有
    case none

    var isOn: Bool { self == .all }
    var isPartial: Bool { self == .partial }
}

struct TagEditorPopover: View {
    /// 浮层标题（如「标签」）
    var title: String = L10n.tr("tag.title")
    /// 编辑目标
    let target: TagEditTarget
    /// 已有标签全集（按 count 降序；用于候选与排序）
    let knownTags: [TagStat]
    /// 每个标签在目标上的状态（由宿主根据选中条目计算）
    /// 批量模式：all/partial/none；单选模式：all/none
    let stateForTag: (String) -> TagCandidateState
    /// 当前目标共有的已选标签（展示在顶部胶囊区，可移除）
    /// 单条：该条全部标签；批量：共有标签（partial 不算共有，仅 all 展示为已完成）
    let appliedTags: [String]
    /// 追加一个已有标签（状态 none→all；批量 partial→all）
    let onSelectTag: (String) -> Void
    /// 移除一个已有标签（all→none / partial→none）
    let onRemoveTag: (String) -> Void
    /// 创建并应用一个全新标签（追加给全部目标）
    let onAddNewTag: (String) -> Void
    /// 关闭浮层
    let onClose: () -> Void

    @State private var query: String = ""
    @State private var highlightedIndex: Int = 0
    @FocusState private var inputFocused: Bool

    /// 候选列表：过滤后的已有标签（排除已应用的共有标签）
    private var filteredCandidates: [TagStat] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .leadingHashesStripped
        let base = knownTags.filter { stat in
            // 已完全应用的标签仍展示（可点击移除），不作为「待添加候选」隐藏
            if q.isEmpty { return true }
            return stat.name.localizedCaseInsensitiveContains(q)
        }
        return base
    }

    /// 是否可创建新标签（输入非空且不与已有标签大小写不敏感重名）
    private var canCreateNew: Bool {
        let raw = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = raw.leadingHashesStripped
        guard !normalized.isEmpty else { return false }
        return !knownTags.contains { $0.name.caseInsensitiveCompare(normalized) == .orderedSame }
    }

    private var listCount: Int {
        filteredCandidates.count + (canCreateNew ? 1 : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部：已选胶囊区（可移除）
            if !appliedTags.isEmpty {
                appliedTagRow
            }
            inputRow
            if !filteredCandidates.isEmpty || canCreateNew {
                Divider().opacity(0.5)
                candidateList
            }
        }
        .frame(width: 260)
        .background {
            RoundedRectangle(cornerRadius: NookClip.radiusCard, style: .continuous)
                .fill(NookClip.bgPopover)
                .overlay {
                    RoundedRectangle(cornerRadius: NookClip.radiusCard, style: .continuous)
                        .strokeBorder(NookClip.separator, lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
        }
        .onAppear { inputFocused = true }
        .onChange(of: query) { _, _ in
            highlightedIndex = 0
        }
    }

    // MARK: - 已选胶囊
    private var appliedTagRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(appliedTags, id: \.self) { tag in
                    TagChipView(
                        tag: tag,
                        size: .regular,
                        isSelected: true,
                        onRemove: { onRemoveTag(tag) }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
        }
        .frame(maxWidth: 244)
    }

    // MARK: - 输入行
    private var inputRow: some View {
        HStack(spacing: 4) {
            Image(systemName: "number")
                .font(.system(size: NookClipIconSize.compact))
                .foregroundStyle(NookClip.textTertiary)
            TagInputField(
                text: $query,
                placeholder: L10n.tr("tag.input_placeholder"),
                isFocused: $inputFocused,
                onSubmit: { commitCurrent() },
                onArrow: { step in moveHighlight(step) },
                onBackspaceEmpty: {
                    if let last = appliedTags.last { onRemoveTag(last) }
                }
            )
            .frame(height: 20)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
    }

    // MARK: - 候选列表
    private var candidateList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 1) {
                    ForEach(Array(filteredCandidates.enumerated()), id: \.element.name) { index, stat in
                        candidateRow(
                            text: stat.name,
                            count: Int(stat.count),
                            state: stateForTag(stat.name),
                            isHighlighted: index == highlightedIndex,
                            isCreate: false
                        )
                        .id(index)
                        .onTapGesture { toggleCandidate(stat.name) }
                    }
                    if canCreateNew {
                        let index = filteredCandidates.count
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.system(size: NookClipIconSize.micro, weight: .bold))
                                .foregroundStyle(NookClip.accent)
                            Text(L10n.tr("tag.create", query.trimmingCharacters(in: .whitespacesAndNewlines).leadingHashesStripped))
                                .font(.nookClipMeta)
                                .foregroundStyle(NookClip.accent)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                                .fill(index == highlightedIndex ? NookClip.bgRowOn : Color.clear)
                        )
                        .contentShape(Rectangle())
                        .id(index)
                        .onTapGesture { commitNewTag() }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 180)
            .onChange(of: highlightedIndex) { _, idx in
                withAnimation(.easeOut(duration: 0.08)) {
                    proxy.scrollTo(idx, anchor: .center)
                }
            }
        }
    }

    private func candidateRow(
        text: String,
        count: Int,
        state: TagCandidateState,
        isHighlighted: Bool,
        isCreate: Bool
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: state.isOn ? "checkmark" : (state.isPartial ? "minus" : "number"))
                .font(.system(size: NookClipIconSize.micro, weight: .bold))
                .foregroundStyle(state.isOn ? NookClip.accent : NookClip.textTertiary)
                .frame(width: 12)
            Text(text)
                .font(.nookClipMeta)
                .foregroundStyle(NookClip.textPrimary)
                .lineLimit(1)
            if count > 0 {
                Text("\(count)")
                    .font(.nookClipBadge)
                    .monospacedDigit()
                    .foregroundStyle(NookClip.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                .fill(isHighlighted ? NookClip.bgRowOn : Color.clear)
        )
        .contentShape(Rectangle())
    }

    // MARK: - 交互
    private func moveHighlight(_ step: Int) {
        guard listCount > 0 else { return }
        highlightedIndex = (highlightedIndex + step + listCount) % listCount
    }

    private func toggleCandidate(_ name: String) {
        let state = stateForTag(name)
        if state.isOn {
            onRemoveTag(name)
        } else {
            // none 或 partial 都补齐为「应用」
            onSelectTag(name)
        }
    }

    /// ⏎：高亮项若为创建新标签则创建；否则切换高亮候选；无候选但有输入则创建
    private func commitCurrent() {
        if highlightedIndex < filteredCandidates.count {
            toggleCandidate(filteredCandidates[highlightedIndex].name)
        } else if canCreateNew {
            commitNewTag()
        } else if let first = filteredCandidates.first {
            toggleCandidate(first.name)
        }
    }

    private func commitNewTag() {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).leadingHashesStripped
        guard !normalized.isEmpty else { return }
        onAddNewTag(normalized)
        query = ""
        highlightedIndex = 0
    }
}

// MARK: - 输入框（AppKit 桥：拦截 ↑↓/⏎/退格，实时受控）

/// 轻量单行输入：SwiftUI TextField 无法在中文输入法下可靠拦截 ↑↓/⏎，
/// 用 NSTextField 包装，正向/退格事件在上游处理（组字态交还输入法）。
private struct TagInputField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var isFocused: FocusState<Bool>.Binding
    let onSubmit: () -> Void
    let onArrow: (Int) -> Void
    let onBackspaceEmpty: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 12)
        field.textColor = NSColor.labelColor
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
        nsView.placeholderString = placeholder
        if isFocused.wrappedValue, nsView.window?.firstResponder !== nsView.currentEditor() {
            DispatchQueue.main.async { nsView.window?.makeFirstResponder(nsView) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TagInputField
        init(_ parent: TagInputField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        @objc func submit() { parent.onSubmit() }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onArrow(-1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onArrow(1)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.deleteBackward(_:)):
                if parent.text.isEmpty {
                    parent.onBackspaceEmpty()
                    return true
                }
                return false
            default:
                return false
            }
        }
    }
}

extension String {
    /// 剥离前导 `#` 与首尾空白（与 Rust normalize_tag 的输入清洗对齐的前端简化版）
    var leadingHashesStripped: String {
        var s = trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("#") { s.removeFirst() }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
