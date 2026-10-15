import SwiftUI

// MARK: - 行内别名输入框（⌘R / 右键「设置别名」进入）

/// ⏎ 与失焦 = 提交（等价）；Esc = 放弃修改。
/// 提交文本经 trim + 128 字符截断后上抛；空串 = title 置空（覆盖即失，
/// 展示层回退内容预览；InMemoryHistoryStore/HistoryStore.updateTitle）。
/// 编辑期间行点击/双击手势由行视图屏蔽。
struct RowRenameField: View {
    let initialText: String
    var onCommit: (String) -> Void
    var onCancel: () -> Void
    /// 宿主行是否为实底强调色选中态：此时输入框描边反白（accent 描边与行底同色不可见）
    var isOnSolidAccentRow: Bool = false

    @State private var text: String
    @FocusState private var focused: Bool
    /// 会话已结束（提交/取消）标记：Esc 取消后的失焦回调、移除视图时的
    /// 失焦回调不再重复提交
    @State private var finished = false

    /// 行内编辑文本长度上限（提交时截断；默认标题本身截 48 字符，别名放宽）
    static let maxLength = 128

    init(
        initialText: String,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void,
        isOnSolidAccentRow: Bool = false
    ) {
        self.initialText = initialText
        self.onCommit = onCommit
        self.onCancel = onCancel
        self.isOnSolidAccentRow = isOnSolidAccentRow
        _text = State(initialValue: initialText)
    }

    var body: some View {
        HStack(spacing: 4) {
            TextField(L10n.tr("rename.placeholder"), text: $text)
                .textFieldStyle(.plain)
                .font(.nookClipBody)
                .foregroundStyle(NookClip.textPrimary)
                .focused($focused)
                .onSubmit { commit() }
                .onKeyPress(.escape) {
                    cancel()
                    return .handled
                }
                .onChange(of: focused) { _, isFocused in
                    // 失焦 = 提交（与 ⏎ 等价）；Esc 路径已置 finished，不会误提交
                    if !isFocused { commit() }
                }
                .onAppear { focused = true }

            Button {
                commit()
            } label: {
                Image(systemName: NookClipIcon.Control.checkmark)
                    .font(.system(size: NookClipIconSize.micro, weight: .bold))
                    .foregroundStyle(NookClip.accent)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(L10n.tr("common.confirm"))
            .accessibilityLabel(L10n.tr("common.confirm"))
        }
        .padding(.leading, 5)
        .padding(.trailing, 2)
        .frame(height: 20)
        .background(
            // 不透明输入面：选中行（solidAccent 实底）上也能与行底拉开对比；
            // 此前的 focusRing 半透明填充在实底选中行上几乎不可见
            RoundedRectangle(cornerRadius: NookClip.radiusThumb, style: .continuous)
                .fill(NookClip.bgInputControl)
        )
        .overlay {
            RoundedRectangle(cornerRadius: NookClip.radiusThumb, style: .continuous)
                .strokeBorder(isOnSolidAccentRow ? NookClip.textOnAccent : NookClip.accent, lineWidth: 1)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func commit() {
        guard !finished else { return }
        finished = true
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        onCommit(String(trimmed.prefix(Self.maxLength)))
    }

    private func cancel() {
        guard !finished else { return }
        finished = true
        onCancel()
    }
}
