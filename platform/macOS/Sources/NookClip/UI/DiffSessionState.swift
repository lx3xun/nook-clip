import AppKit
import Foundation

// MARK: - ⌘D 行内 Diff 的会话状态机（specs/013 · feature #5）
//
// 只负责「当前在对比哪两条、两份文本从哪来、每个差异块选了保留谁」，
// 不碰任何视图。视图层（DiffPreviewCard）只读这里算好的结果。
// 拆成独立类型而不是塞进 MainView 的理由与 MainViewFilterState 一致：
// 状态迁移要能脱离 SwiftUI 单测，规则（谁是新版谁是旧版、什么时候拒绝对比）
// 必须写在一处，否则列表顺序一变就会悄悄对调两边。

/// 对比的一侧（旧版或新版）
struct DiffSide: Equatable {
    /// 条目 id（列表里的行 id）
    let itemID: UUID
    /// 列表中的展示标题（供顶部「A ⇄ B」展示）
    let title: String
    /// 参与对比的文本
    let text: String
    /// 该条目是否含敏感信息：合并结果复制/粘贴时要透传，触发 30 秒自毁
    let containsSensitive: Bool
    /// 文本来自 OCR（图片/文件条目）：顶部要标明，避免用户以为是原文
    let isOCRText: Bool
}

/// 每个差异块用户选择的保留方式，与 Rust 侧 `HunkChoice` 的编码一一对应：
/// 0 = 保留新版，1 = 保留旧版，2 = 两者都保留。
enum DiffHunkKeep: UInt8, CaseIterable {
    case new = 0
    case old = 1
    case both = 2
}

/// 视图呈现方式
enum DiffViewMode: String, CaseIterable {
    /// 行内对比：旧行与新行上下相邻，字词级红绿高亮（默认）
    case inline
    /// 上下对照：左旧右新两栏同步滚动
    case sideBySide
    /// 仅看差异：折叠未改动的上下文
    case changesOnly

    var next: DiffViewMode {
        switch self {
        case .inline: return .sideBySide
        case .sideBySide: return .changesOnly
        case .changesOnly: return .inline
        }
    }
}

/// 对比失败的明确原因：每一种都要给用户一句人话，不允许静默失败。
enum DiffFailure: Equatable {
    /// 列表里不足 2 条记录
    case notEnoughItems
    /// 选中了 3 条以上
    case tooManySelected(Int)
    /// 选中的条目没有可比对的文本（图片无 OCR / 文件无 OCR / 纯空内容）
    case noTextForDiff(String)
    /// 敏感条目无法解密
    case revealFailed(String)

    /// 对应的本地化文案键
    var messageKey: String {
        switch self {
        case .notEnoughItems: return "diff.error.not_enough_items"
        case .tooManySelected: return "diff.error.too_many_selected"
        case .noTextForDiff: return "diff.error.no_text"
        case .revealFailed: return "diff.error.reveal_failed"
        }
    }

    /// 文案插值参数
    var messageArgs: [String] {
        switch self {
        case .notEnoughItems, .noTextForDiff: return []
        case .tooManySelected(let count): return [String(count)]
        case .revealFailed(let title): return [title]
        }
    }
}

/// Diff 对比会话（⌘D 进入，⌘D/Esc 退出）
@MainActor
@Observable
final class DiffSessionState {
    /// nil = 未在对比态
    private(set) var oldSide: DiffSide?
    private(set) var newSide: DiffSide?

    /// Rust 算出的差异结果（nil = 还没算完）
    private(set) var result: FfiTextDiffResult?
    /// 正在计算（超大文本时有可感知耗时，顶部要显示「正在对比」）
    private(set) var isComputing = false
    /// 计算失败/不可对比的原因（nil = 正常）
    private(set) var failure: DiffFailure?
    /// 是否由「未多选时触发对比」自动勾选了两条记录：
    /// 退出对比时若仍为 true，自动清空多选并恢复进入对比前的单选锚点，避免按 Esc 后停留在批量多选模式。
    var autoSelectedPair = false
    /// 自动勾选进入对比前的单选条目 ID（退出时恢复）
    var previousSelectedID: UUID?
    /// 对比态下固定不动的「基准条目 ID」：用户在左侧按 ↑/↓ 或点击其它行时，
    /// 保持该基准条目不变，实时替换另一侧并重算差异（默认固定靠上的新版条目）
    var anchorItemID: UUID?
    /// 视图模式
    var viewMode: DiffViewMode = .inline
    /// 是否忽略空白差异。**默认不忽略**：一键对比的全部价值是「到底改了什么」，
    /// 悄悄藏掉缩进/空格类改动会让人误以为内容没变。想做「格式化后对比」的用户
    /// 可在对比态顶栏手动打开（开关状态保留在会话里）。
    var ignoreWhitespace = false
    /// 是否忽略大小写——默认不忽略（大小写在代码与配置里通常有语义）
    var ignoreCase = false

    /// 每个差异块的保留选择（下标 = hunk.id）。缺失项按「保留新版」处理。
    private(set) var hunkChoices: [DiffHunkKeep] = []
    /// 当前高亮的差异块序号（键盘 ↑↓ 在差异块之间跳转用）
    private(set) var focusedHunkID: UInt32?
    /// 合并结果缓存：任何选择变化都要重算，缓存避免每帧跨 FFI 调用
    private(set) var mergedText: String = ""

    var isActive: Bool { oldSide != nil && newSide != nil }
    /// 是否正处于对比会话中（含在对比中途切到无文本条目时的瞬态提示，按 ↑/↓ 可继续切换其它条目）
    var isInSession: Bool { isActive || anchorItemID != nil || failure != nil }
    /// 可选择的差异块（只有改动块；上下文块不参与合并选择）
    var changeHunks: [FfiDiffHunk] {
        result?.hunks.filter(\.isChange) ?? []
    }

    /// 差异块总数（含上下文），合并选择数组按全部 hunk 顺序对齐
    var hunkCount: Int { result?.hunks.count ?? 0 }

    /// 是否有任何改动（用于禁用「复制合并版」之类的按钮）
    var hasChanges: Bool {
        (result?.stats.changedHunks ?? 0) > 0
    }

    // MARK: - 进入 / 退出

    /// 进入对比态。调用方（MainView）负责把行模型/条目解析成 `DiffSide`。
    /// 两侧都为 nil 且带 failure 时，会话保持非激活并把失败原因留给 toast。
    func start(old: DiffSide?, new: DiffSide?, failure: DiffFailure?) {
        guard let old, let new, failure == nil else {
            reset()
            self.failure = failure
            return
        }
        oldSide = old
        newSide = new
        if anchorItemID == nil || (anchorItemID != old.itemID && anchorItemID != new.itemID) {
            anchorItemID = new.itemID
        }
        self.failure = nil
        focusedHunkID = nil
        hunkChoices = []
        mergedText = ""
        recompute()
    }

    /// 切换固定基准侧（点击顶栏「旧」或「新」胶囊，或在列表点已处于对比中的某一条时触发）
    func setAnchor(_ id: UUID) {
        guard id == oldSide?.itemID || id == newSide?.itemID else { return }
        anchorItemID = id
    }

    /// 对比态中途切换到不可比条目（如无 OCR 的纯图片）时记录瞬态原因，
    /// 保留 anchorItemID / viewMode / 忽略开关，使用户继续按 ↑/↓ 或点下一条即可恢复实时对比
    func setTransientFailure(_ failure: DiffFailure) {
        self.failure = failure
        self.result = nil
        self.hunkChoices = []
        self.focusedHunkID = nil
        self.mergedText = ""
    }

    /// 退出对比态（⌘D 再按一次 / Esc）
    func reset() {
        oldSide = nil
        newSide = nil
        result = nil
        failure = nil
        autoSelectedPair = false
        previousSelectedID = nil
        anchorItemID = nil
        viewMode = .inline
        isComputing = false
        hunkChoices = []
        focusedHunkID = nil
        mergedText = ""
    }

    /// 清掉失败原因（toast 展示完/用户重新操作后）
    func clearFailure() {
        failure = nil
    }

    // MARK: - 计算

    /// 调 Rust 核心算差异并把每个改动块默认设为「保留新版」。
    ///
    /// 为什么默认保留新版：用户的直觉永远是「第二条是最新的，我要的是它」。
    /// 想让某一处回退到旧版，是逐块主动选择，而不是全局默认。
    func recompute() {
        guard let oldSide, let newSide else {
            result = nil
            mergedText = ""
            return
        }
        guard oldSide.text != newSide.text else {
            // 完全相同：仍然进入对比态（用户要看的是「确实一样」这个结论），
            // 但顶部显示「两侧内容相同」而不是空白
            isComputing = false
            hunkChoices = []
            mergedText = newSide.text
            result = FfiTextDiffResult(
                hunks: [],
                stats: FfiDiffStats(
                    addedLines: 0,
                    removedLines: 0,
                    changedHunks: 0,
                    addedWords: 0,
                    removedWords: 0,
                    similarityPermille: 1000,
                    isIdentical: true,
                    isTruncated: false
                )
            )
            return
        }

        isComputing = true
        let computed = computeTextDiff(
            oldText: oldSide.text,
            newText: newSide.text,
            ignoreWhitespace: ignoreWhitespace,
            ignoreCase: ignoreCase,
            maxLines: 0,
            maxInlineTokens: 0
        )
        result = computed
        // 改动块默认「保留新版」，上下文块给 0 占位（不参与合并决策）
        hunkChoices = Array(repeating: DiffHunkKeep.new, count: computed.hunks.count)
        focusedHunkID = computed.hunks.first(where: { $0.isChange })?.id
        isComputing = false
        recomputeMergedText()
    }

    /// 重新调用 Rust 拼出合并文本（选择变化后必须调用）
    func recomputeMergedText() {
        guard let oldSide, let newSide else {
            mergedText = ""
            return
        }
        guard let result, !result.hunks.isEmpty else {
            mergedText = newSide.text
            return
        }
        // 上下文块的 choices 也一并发过去：Rust 侧对非改动块忽略选择值，
        // 但数组长度必须与 hunks 对齐（缺失项按 KeepNew 处理，不会崩）
        let codes = Data(hunkChoices.map(\.rawValue))
        mergedText = mergeTextDiff(
            oldText: oldSide.text,
            newText: newSide.text,
            ignoreWhitespace: ignoreWhitespace,
            ignoreCase: ignoreCase,
            maxLines: 0,
            maxInlineTokens: 0,
            choices: codes
        )
    }

    // MARK: - 逐块选择

    /// 设置某个差异块的保留方式并重算合并文本
    func setChoice(_ choice: DiffHunkKeep, forHunk id: UInt32) {
        guard Int(id) < hunkChoices.count else { return }
        guard result?.hunks[safe: Int(id)]?.isChange == true else { return }
        hunkChoices[Int(id)] = choice
        recomputeMergedText()
    }

    func choice(forHunk id: UInt32) -> DiffHunkKeep {
        guard Int(id) < hunkChoices.count else { return .new }
        return hunkChoices[Int(id)]
    }

    /// 循环切换某个差异块的选择：新版 → 旧版 → 两者都保留 → 新版
    func cycleChoice(forHunk id: UInt32) {
        switch choice(forHunk: id) {
        case .new: setChoice(.old, forHunk: id)
        case .old: setChoice(.both, forHunk: id)
        case .both: setChoice(.new, forHunk: id)
        }
    }

    /// 全部改成同一种选择（顶部「全部保留新版/旧版」快捷操作）
    func setAllChoices(_ choice: DiffHunkKeep) {
        guard let result else { return }
        hunkChoices = result.hunks.map { $0.isChange ? choice : .new }
        recomputeMergedText()
    }

    // MARK: - 差异块跳转

    /// 在改动块之间前后跳转（↑↓ 或 ⌘↑⌘↓），首尾循环。
    /// 返回目标块序号，供视图滚动定位。
    @discardableResult
    func focusNextChangeHunk(forward: Bool) -> UInt32? {
        let changes = changeHunks
        guard !changes.isEmpty else { return nil }
        guard let current = focusedHunkID,
              let index = changes.firstIndex(where: { $0.id == current }) else {
            focusedHunkID = forward ? changes.first?.id : changes.last?.id
            return focusedHunkID
        }
        let nextIndex: Int
        if forward {
            nextIndex = (index + 1) % changes.count
        } else {
            nextIndex = (index - 1 + changes.count) % changes.count
        }
        focusedHunkID = changes[nextIndex].id
        return focusedHunkID
    }

    func focus(hunk id: UInt32) {
        focusedHunkID = id
    }

    // MARK: - 顶部摘要文字

    /// 顶部统计：「+12 −8 · 相似度 87%」这类一眼可读的摘要。
    /// 数字口径与 `git diff --stat` 一致（增删行数），相似度取千分比取整。
    var statsSummary: String {
        guard let stats = result?.stats else { return "" }
        if stats.isIdentical {
            return L10n.tr("diff.stats.identical")
        }
        let percent = Int((Double(stats.similarityPermille) / 10.0).rounded())
        return L10n.tr(
            "diff.stats.summary",
            String(stats.addedLines),
            String(stats.removedLines),
            String(percent)
        )
    }
}

// MARK: - 安全下标

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
