import AppKit
import SwiftUI

// MARK: - ⌘D 一键行内对比的视图层实现（feature #5）
//
// 这一层只做「路由」：从当前选择态挑出两条记录、把条目解析成可对比的文本、
// 调 `DiffSessionState` 起会话、失败时给一句人话。差异算法在 Rust 核心
// （`crates/nookclip-core/src/algorithms/diff.rs`），渲染在 DiffPreviewCard。
// 拆文件理由与 MainView+ScrubActions 一致：MainView.swift 已 1100+ 行。

extension MainView {

    // MARK: - ⌘D 入口

    /// 当前是否满足发起对比的前置条件（列表至少 2 条，且未勾选超过 2 条）
    var canDiffSelection: Bool {
        flatRows.count >= 2 && selectionCoordinator.selectionIDs.count <= 2
    }

    /// ⌘D / 预览顶栏「对比」/ 多选底栏「对比」/ 右键「对比两条记录」：进入或退出行内对比。
    ///
    /// 进入规则（用户零学习成本优先）：
    /// - 已勾选 2 条 → 就比这两条，列表里靠下的是旧版（列表按复制时间倒序，
    ///   越靠下越旧，这样「A ⇄ B」与用户在列表里看到的上下关系一致）；
    /// - 单选了第 N 条（N > 1）→ 拿当前选中的这条（旧版）与列表最上面最新那条（新版）对比；
    /// - 单选第 1 条或未选中 → 直接比列表最上面 2 条（最常用的「刚复制的两条」场景）；
    /// - 勾选 3 条以上 → 提示只支持两条，不做猜测。
    func toggleDiff() {
        // 已在对比态、或右列正显示一句失败原因时，⌘D 一律表示「退出」。
        // 否则用户看到「只支持两条」的提示后再按一次 ⌘D，只会把同一句提示再弹一遍。
        if diffSession.isInSession {
            exitDiff()
            return
        }
        startDiff()
    }

    /// 退出对比态，回到常规预览（若是自动勾选的两条，顺手清空多选并恢复进入前的单选位置）
    func exitDiff() {
        guard diffSession.isInSession else { return }
        let shouldRestoreSingleSelection = diffSession.autoSelectedPair
        let restoredSelectedID = diffSession.previousSelectedID
        diffSession.reset()
        diffSession.clearFailure()
        if shouldRestoreSingleSelection {
            selectionCoordinator.selectionIDs.removeAll()
            if let restoredSelectedID {
                selectionCoordinator.selectedID = restoredSelectedID
            }
        }
    }

    private func startDiff() {
        let ordered = orderedSelectionForDiff()
        switch ordered {
        case .failure(let failure):
            diffSession.start(old: nil, new: nil, failure: failure)
            showScrubFeedback(Self.diffMessage(for: failure))
        case .pair(let oldRow, let newRow):
            let oldSide = resolveDiffSide(for: oldRow)
            let newSide = resolveDiffSide(for: newRow)

            if let failure = oldSide.failure ?? newSide.failure {
                diffSession.start(old: nil, new: nil, failure: failure)
                showScrubFeedback(Self.diffMessage(for: failure))
                return
            }
            guard let oldDiff = oldSide.side, let newDiff = newSide.side else { return }

            // 盲按时把参与对比的两条同步进多选态：右侧在比 A、B，
            // 左侧就应该高亮 A、B，否则用户会怀疑自己比错了东西。
            // 同时记录 autoSelectedPair，退出对比时自动恢复单选。
            let ids = selectionCoordinator.selectionIDs
            let wasAutoSelected = ids.count != 2
            let priorSelectedID = selectionCoordinator.selectedID
            if ids != [oldRow.id, newRow.id] {
                selectionCoordinator.selectionIDs = [oldRow.id, newRow.id]
            }
            if selectionCoordinator.selectedID != oldRow.id {
                selectionCoordinator.selectedID = oldRow.id
            }

            diffSession.anchorItemID = newRow.id
            diffSession.start(old: oldDiff, new: newDiff, failure: nil)
            diffSession.anchorItemID = newRow.id
            diffSession.autoSelectedPair = wasAutoSelected
            diffSession.previousSelectedID = wasAutoSelected ? priorSelectedID : nil
        }
    }

    /// 选出要对比的一对（旧版在前）
    private func orderedSelectionForDiff() -> DiffPairResolution {
        Self.resolvePairForDiff(
            flatRows: flatRows,
            selectedID: selectionCoordinator.selectedID,
            selectionIDs: selectionCoordinator.selectionIDs
        )
    }

    /// 纯函数：从列表与当前选择态挑出待对比的（旧版, 新版）条目对，供单测直接校验
    static func resolvePairForDiff(
        flatRows: [ClipboardRowModel],
        selectedID: UUID?,
        selectionIDs: Set<UUID>
    ) -> DiffPairResolution {
        if selectionIDs.count > 2 {
            return .failure(.tooManySelected(selectionIDs.count))
        }
        if selectionIDs.count == 2 {
            let rows = flatRows.filter { selectionIDs.contains($0.id) }
            guard rows.count == 2 else { return .failure(.notEnoughItems) }
            // flatRows 已是列表显示序（新 → 旧），故 rows[1] 是旧版
            return .pair(old: rows[1], new: rows[0])
        }
        guard flatRows.count >= 2 else { return .failure(.notEnoughItems) }
        // 单选了列表里第 2 条及以后的记录时，拿「当前选中项（旧）」与「最顶最新项（新）」对比；
        // 若当前选中的就是第 1 条（或未选中），对比最顶两条（第 2 条旧 vs 第 1 条新）
        if let selectedID,
           let selectedIdx = flatRows.firstIndex(where: { $0.id == selectedID }),
           selectedIdx > 0 {
            return .pair(old: flatRows[selectedIdx], new: flatRows[0])
        }
        return .pair(old: flatRows[1], new: flatRows[0])
    }

    // MARK: - 对比态内实时切换记录（↑/↓、鼠标点选、顶栏固定侧切换）

    /// 对比态下按 ↑/↓（或 ⇧↑/⇧↓）：保持基准记录不变，移动游标并实时更新右侧差异视图
    func moveDiffComparisonSelection(offset step: Int, changeAnchor: Bool) {
        guard diffSession.isInSession, !flatRows.isEmpty else { return }
        let anchorID: UUID
        if changeAnchor, let currentID = selectionCoordinator.selectedID {
            anchorID = currentID
        } else {
            anchorID = diffSession.anchorItemID ?? diffSession.newSide?.itemID ?? flatRows[0].id
        }
        guard let targetRow = Self.nextDiffCursorRow(
            flatRows: flatRows,
            currentSelectedID: selectionCoordinator.selectedID,
            anchorID: anchorID,
            step: step
        ) else { return }

        switchDiffTarget(to: targetRow, keepingAnchor: anchorID)

        if let idx = flatRows.firstIndex(where: { $0.id == targetRow.id }),
           idx >= flatRows.count - 1,
           queryCoordinator.hasMore {
            loadMoreQueryResults()
        }
    }

    /// 对比态下点击左侧列表行：
    /// - ⌘点击 / ⇧点击：把上一次游标所在行固定为新基准，与当前点击行对比；
    /// - 点击当前正在对比的两条之一：将该条固定为基准，后续点击或 ↑/↓ 将替换另一侧；
    /// - 普通点击其它行：保持当前基准行不变，实时与被点击行对比。
    func handleDiffModeRowTap(_ item: ClipboardRowModel, shiftHeld: Bool, commandHeld: Bool) {
        if shiftHeld || commandHeld {
            if let currentID = selectionCoordinator.selectedID, currentID != item.id {
                switchDiffTarget(to: item, keepingAnchor: currentID)
                return
            }
        }
        if item.id == diffSession.oldSide?.itemID || item.id == diffSession.newSide?.itemID {
            pinDiffAnchor(item.id)
            return
        }
        guard let anchorID = diffSession.anchorItemID ?? diffSession.newSide?.itemID ?? flatRows.first?.id,
              anchorID != item.id else { return }
        switchDiffTarget(to: item, keepingAnchor: anchorID)
    }

    /// 将对比中的某一侧固定为基准，并把列表游标移到另一侧
    func pinDiffAnchor(_ id: UUID) {
        diffSession.setAnchor(id)
        if let oldID = diffSession.oldSide?.itemID, let newID = diffSession.newSide?.itemID {
            let otherID = (id == newID) ? oldID : newID
            if selectionCoordinator.selectedID != otherID {
                selectionCoordinator.selectedID = otherID
            }
        }
    }

    /// 保持 `anchorID` 不变，把另一侧切换为 `targetRow` 并实时重算差异
    func switchDiffTarget(to targetRow: ClipboardRowModel, keepingAnchor anchorID: UUID) {
        guard let pair = Self.resolvePairWithAnchor(
            flatRows: flatRows,
            anchorID: anchorID,
            targetID: targetRow.id
        ) else { return }

        selectionCoordinator.selectionIDs = [pair.old.id, pair.new.id]
        selectionCoordinator.selectedID = targetRow.id

        let oldSide = resolveDiffSide(for: pair.old)
        let newSide = resolveDiffSide(for: pair.new)

        if let failure = oldSide.failure ?? newSide.failure {
            diffSession.anchorItemID = anchorID
            diffSession.setTransientFailure(failure)
            showScrubFeedback(Self.diffMessage(for: failure))
            return
        }
        guard let oldDiff = oldSide.side, let newDiff = newSide.side else { return }

        diffSession.anchorItemID = anchorID
        diffSession.start(old: oldDiff, new: newDiff, failure: nil)
        diffSession.anchorItemID = anchorID
    }

    /// 纯函数：计算对比态下按 ↑/↓ 时的下一条目标行（自动跨过固定基准行，避免自己和自己对比）
    static func nextDiffCursorRow(
        flatRows: [ClipboardRowModel],
        currentSelectedID: UUID?,
        anchorID: UUID,
        step: Int
    ) -> ClipboardRowModel? {
        guard !flatRows.isEmpty, step != 0 else { return nil }
        let currentIdx = flatRows.firstIndex(where: { $0.id == currentSelectedID })
            ?? flatRows.firstIndex(where: { $0.id != anchorID })
            ?? 0
        let dir = step >= 0 ? 1 : -1
        var candidateIdx = currentIdx + step
        if candidateIdx >= 0, candidateIdx < flatRows.count, flatRows[candidateIdx].id == anchorID {
            candidateIdx += dir
        }
        guard candidateIdx >= 0, candidateIdx < flatRows.count else { return nil }
        let candidate = flatRows[candidateIdx]
        guard candidate.id != anchorID else { return nil }
        return candidate
    }

    /// 纯函数：根据基准条目与目标条目在列表中的先后位置，按（旧版, 新版）顺序返回
    static func resolvePairWithAnchor(
        flatRows: [ClipboardRowModel],
        anchorID: UUID,
        targetID: UUID
    ) -> (old: ClipboardRowModel, new: ClipboardRowModel)? {
        guard anchorID != targetID,
              let anchorIdx = flatRows.firstIndex(where: { $0.id == anchorID }),
              let targetIdx = flatRows.firstIndex(where: { $0.id == targetID }) else {
            return nil
        }
        if anchorIdx < targetIdx {
            return (old: flatRows[targetIdx], new: flatRows[anchorIdx])
        } else {
            return (old: flatRows[anchorIdx], new: flatRows[targetIdx])
        }
    }

    /// 把一条记录解析成可对比文本
    private func resolveDiffSide(for row: ClipboardRowModel) -> DiffSideResolution {
        guard let item = store.item(withID: row.id) else {
            return .failure(.noTextForDiff(row.displayTitle))
        }

        // 敏感条目：与 ⌃⏎ 脱敏粘贴同一条规则——用户显式触发才解密，
        // 解密失败明确告知，绝不把掩码串拿去对比（那会得到「全部改动」的假结果）
        if item.isSensitive {
            switch item.revealPlainContentResult() {
            case .success(let plain):
                let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    return .failure(.noTextForDiff(row.displayTitle))
                }
                return .side(
                    DiffSide(
                        itemID: row.id,
                        title: row.displayTitle,
                        text: plain,
                        containsSensitive: true,
                        isOCRText: false
                    )
                )
            case .failure:
                return .failure(.revealFailed(row.displayTitle))
            }
        }

        // 图片/文件：没有正文，退而用 OCR 文字对比（两条截图里的文案改动同样能看）
        if item.type == .image || item.type == .file {
            let ocr = item.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !ocr.isEmpty else {
                return .failure(.noTextForDiff(row.displayTitle))
            }
            return .side(
                DiffSide(
                    itemID: row.id,
                    title: row.displayTitle,
                    text: item.ocrText ?? "",
                    containsSensitive: false,
                    isOCRText: true
                )
            )
        }

        // 文本 / 链接 / 代码 / JSON / 色值：直接用完整正文。
        // store.item 对截断摘要会回查库取全文，故这里拿到的不是前缀。
        let text = item.summary
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.noTextForDiff(row.displayTitle))
        }
        return .side(
            DiffSide(
                itemID: row.id,
                title: row.displayTitle,
                text: text,
                containsSensitive: false,
                isOCRText: false
            )
        )
    }

    // MARK: - 顶栏的两个忽略开关

    /// 忽略空白：改完必须重算差异 + 重算合并文本。
    /// 两个都要重算，否则顶部统计变了、底部合并版还是按旧规则拼的，用户会拿到错的行。
    func toggleDiffIgnoreWhitespace() {
        diffSession.ignoreWhitespace.toggle()
        diffSession.recompute()
    }

    /// 忽略大小写：同上
    func toggleDiffIgnoreCase() {
        diffSession.ignoreCase.toggle()
        diffSession.recompute()
    }

    // MARK: - 合并结果的两个出口（⌘C 复制 / ⏎ 粘贴）

    /// ⌘C：复制合并版。含任一侧敏感内容时透传 containsSensitive，
    /// 由 PasteService 打上 transient 标记并调度 30 秒自毁（安全红线）。
    /// 返回 true 表示对比态接管了本次 ⌘C（否则回落常规「复制选中条目」）
    @discardableResult
    func copyMergedDiff() -> Bool {
        guard diffSession.isActive else { return false }
        let text = diffSession.mergedText
        guard !text.isEmpty else { return false }
        let sensitive = diffSession.containsSensitive
        if clipboardWriter.copyText(text, containsSensitive: sensitive) {
            showScrubFeedback(
                L10n.tr(sensitive ? "diff.copied_sensitive" : "diff.copied")
            )
        }
        return true
    }

    /// ⏎：粘贴合并版并收起面板（与单条粘贴同一个出口，过终端护栏）。
    /// 返回 true 表示对比态接管了本次 ⏎
    @discardableResult
    func pasteMergedDiff() -> Bool {
        guard diffSession.isActive else { return false }
        let text = diffSession.mergedText
        guard !text.isEmpty else { return false }
        let targetApp = getTargetApplication()
        var textToPaste = text
        var toastMessage: String?

        switch TerminalPasteGuard.decide(
            bundleId: targetApp?.bundleIdentifier,
            appName: targetApp?.localizedName,
            text: text
        ) {
        case .passthrough:
            break
        case .silentStrip(let assessment):
            textToPaste = assessment.pasteText
            toastMessage = L10n.tr("terminal.toast.stripped")
        case .confirm(let assessment):
            switch TerminalPasteConfirm.present(assessment) {
            case .cancel:
                // 用户在护栏弹窗上取消：留在对比态，别把会话丢掉
                return true
            case .safe:
                textToPaste = assessment.pasteText
                toastMessage = L10n.tr("terminal.toast.safe_paste")
            case .raw:
                textToPaste = text
            }
        }

        let sensitive = diffSession.containsSensitive
        exitDiff()
        onClose()
        _ = clipboardWriter.pasteText(
            textToPaste,
            targetApplication: targetApp,
            containsSensitive: sensitive
        )
        if let toastMessage {
            TerminalSafePasteNotifier.shared.show(toastMessage)
        }
        return true
    }

    // MARK: - 失败文案

    /// 把 `DiffFailure` 翻成当前语言的提示文案
    static func diffMessage(for failure: DiffFailure) -> String {
        switch failure {
        case .tooManySelected(let count):
            return L10n.tr(failure.messageKey, String(count))
        case .revealFailed(let title):
            return L10n.tr(failure.messageKey, title)
        default:
            return L10n.tr(failure.messageKey)
        }
    }
}

// MARK: - 解析中间态

/// 挑一对记录的结果：要么成对，要么是一句明确原因
enum DiffPairResolution {
    case pair(old: ClipboardRowModel, new: ClipboardRowModel)
    case failure(DiffFailure)
}

/// 解析单侧文本的结果
enum DiffSideResolution {
    case side(DiffSide)
    case failure(DiffFailure)

    var side: DiffSide? {
        if case .side(let side) = self { return side }
        return nil
    }

    var failure: DiffFailure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}

extension DiffSessionState {
    /// 任一侧含敏感内容：合并结果复制/粘贴须按敏感处理
    var containsSensitive: Bool {
        (oldSide?.containsSensitive ?? false) || (newSide?.containsSensitive ?? false)
    }

    /// 是否有任一侧文本来自 OCR（顶部要标明，避免用户以为是原文）
    var usesOCRText: Bool {
        (oldSide?.isOCRText ?? false) || (newSide?.isOCRText ?? false)
    }
}
