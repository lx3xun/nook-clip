import XCTest
@testable import NookClip

/// ⌘D 行内对比会话状态机测试（feature #5）。
///
/// 只测状态迁移与规则（谁是新版谁是旧版、默认选择、合并文本、跳转循环），
/// 不测渲染 —— 渲染由 DiffPreviewCard 的 SwiftUI 快照与手工验证覆盖。
/// 这些规则一旦悄悄变了，用户看到的就是「保留新版」却拿到旧内容，
/// 属于肉眼极难发现的错误，所以必须有断言钉住。
@MainActor
final class DiffSessionStateTests: XCTestCase {

    private func makeSide(
        title: String = "item",
        text: String,
        containsSensitive: Bool = false,
        isOCRText: Bool = false
    ) -> DiffSide {
        DiffSide(
            itemID: UUID(),
            title: title,
            text: text,
            containsSensitive: containsSensitive,
            isOCRText: isOCRText
        )
    }

    private func makeActiveSession(
        old: String = "a\nb\nc",
        new: String = "a\nB\nc"
    ) -> DiffSessionState {
        let session = DiffSessionState()
        session.start(old: makeSide(title: "旧", text: old), new: makeSide(title: "新", text: new), failure: nil)
        return session
    }

    // MARK: - 进入与退出

    func testStartActivatesSessionAndComputesResult() {
        let session = makeActiveSession()
        XCTAssertTrue(session.isActive)
        XCTAssertNil(session.failure)
        XCTAssertEqual(session.oldSide?.text, "a\nb\nc")
        XCTAssertEqual(session.newSide?.text, "a\nB\nc")
        XCTAssertNotNil(session.result)
        XCTAssertGreaterThan(session.hunkCount, 0)
        XCTAssertTrue(session.hasChanges)
    }

    func testStartWithFailureStaysInactive() {
        let session = DiffSessionState()
        session.start(old: nil, new: nil, failure: .tooManySelected(3))
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(session.failure, .tooManySelected(3))
        XCTAssertNil(session.result)
    }

    func testResetClearsEverything() {
        let session = makeActiveSession()
        session.autoSelectedPair = true
        session.previousSelectedID = UUID()
        session.reset()
        XCTAssertFalse(session.isActive)
        XCTAssertFalse(session.autoSelectedPair, "退出对比时必须一并重置自动多选标记")
        XCTAssertNil(session.previousSelectedID, "退出对比时必须一并清除进入前的单选锚点")
        XCTAssertNil(session.newSide)
        XCTAssertNil(session.result)
        XCTAssertNil(session.failure)
        XCTAssertNil(session.focusedHunkID)
        XCTAssertEqual(session.mergedText, "")
        XCTAssertFalse(session.hasChanges)
    }

    /// 失败原因也必须可关闭：右列在 failure != nil 时会一直显示提示卡，
    /// 若 Esc/⌘D 只认 isActive，用户看到提示后按键毫无反应，会被当成卡死。
    func testFailureStateIsDismissible() {
        let session = DiffSessionState()
        session.start(old: nil, new: nil, failure: .noTextForDiff("截图"))
        XCTAssertNotNil(session.failure)
        // 退出条件与 MainView.exitDiff 的判定保持一致
        XCTAssertTrue(session.isActive || session.failure != nil)
        session.reset()
        session.clearFailure()
        XCTAssertFalse(session.isActive || session.failure != nil, "退出后右列必须回到常规预览")
    }

    func testClearFailureKeepsSessionInactiveButDropsReason() {
        let session = DiffSessionState()
        session.start(old: nil, new: nil, failure: .notEnoughItems)
        session.clearFailure()
        XCTAssertNil(session.failure)
        XCTAssertFalse(session.isActive)
    }

    // MARK: - 相同文本快路径

    /// 两侧完全相同也必须进入对比态：用户要的是「确实一样」这个结论，
    /// 直接弹回列表反而让人怀疑快捷键没生效。
    func testIdenticalTextUsesFastPathAndStaysActive() {
        let session = makeActiveSession(old: "same", new: "same")
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(session.result?.hunks.count, 0)
        XCTAssertTrue(session.result?.stats.isIdentical ?? false)
        XCTAssertEqual(session.result?.stats.similarityPermille, 1000)
        XCTAssertFalse(session.hasChanges)
        XCTAssertEqual(session.mergedText, "same")
    }

    func testIdenticalFastPathLeavesNoHunkChoices() {
        let session = makeActiveSession(old: "x", new: "x")
        XCTAssertEqual(session.hunkChoices.count, 0)
        XCTAssertNil(session.focusedHunkID)
    }

    // MARK: - 默认选择：改动块一律保留新版

    /// 默认保留新版是产品决策：用户的直觉是「第二条最新，我要它」。
    /// 想回退到旧版必须逐块主动选择，不能靠默认值偷偷回退。
    func testChangeHunksDefaultToKeepNewAndMergedEqualsNewText() {
        let session = makeActiveSession(old: "a\nb\nc", new: "a\nB\nc")
        XCTAssertFalse(session.changeHunks.isEmpty)
        for hunk in session.changeHunks {
            XCTAssertEqual(session.choice(forHunk: hunk.id), .new)
        }
        XCTAssertEqual(session.mergedText, "a\nB\nc", "全部保留新版时合并结果必须等于新文本原文")
    }

    func testHunkChoicesArrayAlignsWithAllHunks() {
        let session = makeActiveSession()
        XCTAssertEqual(session.hunkChoices.count, session.hunkCount, "选择数组长度必须与全部差异块对齐")
    }

    func testFirstChangeHunkIsFocusedByDefault() {
        let session = makeActiveSession()
        XCTAssertEqual(session.focusedHunkID, session.changeHunks.first?.id)
    }

    // MARK: - 逐块选择

    func testKeepOldReplacesOnlyThatHunk() {
        let session = makeActiveSession(old: "a\nb\nc", new: "a\nB\nc")
        guard let hunk = session.changeHunks.first else { return XCTFail("应当有改动块") }
        session.setChoice(.old, forHunk: hunk.id)
        XCTAssertEqual(session.choice(forHunk: hunk.id), .old)
        XCTAssertEqual(session.mergedText, "a\nb\nc", "只保留旧版时合并结果回到旧文本")
    }

    func testKeepBothAppendsBothVersions() {
        let session = makeActiveSession(old: "a\nb\nc", new: "a\nB\nc")
        guard let hunk = session.changeHunks.first else { return XCTFail("应当有改动块") }
        session.setChoice(.both, forHunk: hunk.id)
        XCTAssertEqual(session.mergedText, "a\nb\nB\nc")
    }

    func testCycleChoiceRotatesNewOldBoth() {
        let session = makeActiveSession()
        guard let hunk = session.changeHunks.first else { return XCTFail("应当有改动块") }
        XCTAssertEqual(session.choice(forHunk: hunk.id), .new)
        session.cycleChoice(forHunk: hunk.id)
        XCTAssertEqual(session.choice(forHunk: hunk.id), .old)
        session.cycleChoice(forHunk: hunk.id)
        XCTAssertEqual(session.choice(forHunk: hunk.id), .both)
        session.cycleChoice(forHunk: hunk.id)
        XCTAssertEqual(session.choice(forHunk: hunk.id), .new)
    }

    func testSetChoiceIgnoresContextHunk() {
        let session = makeActiveSession(old: "a\nb\nc", new: "a\nB\nc")
        guard let contextID = session.result?.hunks.first(where: { !$0.isChange })?.id else {
            return XCTFail("应当有上下文块")
        }
        session.setChoice(.old, forHunk: contextID)
        // 上下文块不参与合并决策：合并结果仍等于新文本
        XCTAssertEqual(session.mergedText, "a\nB\nc")
    }

    func testSetChoiceIgnoresOutOfRangeID() {
        let session = makeActiveSession()
        let before = session.hunkChoices
        session.setChoice(.both, forHunk: UInt32.max)
        XCTAssertEqual(session.hunkChoices, before, "越界 id 不得改变任何状态")
    }

    func testSetAllChoicesKeepsContextSlotsAtNew() {
        let session = makeActiveSession(old: "a\nb\nc", new: "a\nB\nc")
        session.setAllChoices(.old)
        XCTAssertEqual(session.mergedText, "a\nb\nc")
        for hunk in session.result?.hunks ?? [] where !hunk.isChange {
            XCTAssertEqual(session.choice(forHunk: hunk.id), .new, "上下文块占位值固定为默认，不跟随批量选择")
        }
    }

    func testPartialPerHunkChoicesMergeCorrectly() {
        let session = makeActiveSession(
            old: "keep\nold1\nmid\nold2\nend",
            new: "keep\nnew1\nmid\nnew2\nend"
        )
        let changes = session.changeHunks
        XCTAssertEqual(changes.count, 2)
        guard changes.count == 2 else { return }
        session.setChoice(.old, forHunk: changes[0].id)
        session.setChoice(.new, forHunk: changes[1].id)
        XCTAssertEqual(session.mergedText, "keep\nold1\nmid\nnew2\nend")
    }

    // MARK: - 差异块跳转

    func testFocusNextChangeHunkCyclesForwardAndBackward() {
        let session = makeActiveSession(
            old: "keep\nold1\nmid\nold2\nend",
            new: "keep\nnew1\nmid\nnew2\nend"
        )
        let changes = session.changeHunks
        XCTAssertEqual(changes.count, 2)
        guard changes.count == 2 else { return }
        XCTAssertEqual(session.focusedHunkID, changes[0].id)

        XCTAssertEqual(session.focusNextChangeHunk(forward: true), changes[1].id)
        XCTAssertEqual(session.focusNextChangeHunk(forward: true), changes[0].id, "尾部循环回首块")
        XCTAssertEqual(session.focusNextChangeHunk(forward: false), changes[1].id, "头部循环到末块")
    }

    func testFocusNextChangeHunkReturnsNilWhenNoChanges() {
        let session = makeActiveSession(old: "same", new: "same")
        XCTAssertNil(session.focusNextChangeHunk(forward: true))
        XCTAssertNil(session.focusedHunkID)
    }

    func testFocusSetsTargetHunk() {
        let session = makeActiveSession()
        guard let second = session.changeHunks.dropFirst().first else { return }
        session.focus(hunk: second.id)
        XCTAssertEqual(session.focusedHunkID, second.id)
    }

    // MARK: - 忽略空白 / 忽略大小写

    func testIgnoreWhitespaceDefaultsOffAndRecomputesMerge() {
        let session = DiffSessionState()
        XCTAssertFalse(session.ignoreWhitespace, "默认必须不忽略空白，否则空格改动会被悄悄藏掉")
        XCTAssertFalse(session.ignoreCase)
        session.start(
            old: makeSide(text: "a  b"),
            new: makeSide(text: "a b"),
            failure: nil
        )
        XCTAssertTrue(session.hasChanges, "默认能看到纯空白改动")

        session.ignoreWhitespace = true
        session.recompute()
        XCTAssertFalse(session.hasChanges, "打开忽略空白后同一对文本不再算改动")
        XCTAssertEqual(session.mergedText, "a b", "合并文本必须按当前规则同步重算")
    }

    func testIgnoreCaseRecomputesChangedHunks() {
        let session = DiffSessionState()
        session.start(old: makeSide(text: "Hello"), new: makeSide(text: "hello"), failure: nil)
        XCTAssertTrue(session.hasChanges)

        session.ignoreCase = true
        session.recompute()
        XCTAssertFalse(session.hasChanges)
    }

    // MARK: - 顶部摘要

    func testStatsSummaryForIdenticalText() {
        let session = makeActiveSession(old: "same", new: "same")
        XCTAssertEqual(session.statsSummary, L10n.tr("diff.stats.identical"))
    }

    func testStatsSummaryMentionsAddedAndRemovedLines() {
        let session = makeActiveSession(old: "a\nb\nc", new: "a\nB\nc")
        let summary = session.statsSummary
        XCTAssertTrue(summary.contains("1"), "摘要应含增删行数：\(summary)")
        XCTAssertFalse(summary.isEmpty)
    }

    // MARK: - 敏感与 OCR 标记

    func testSensitiveFlagSurvivesLongestSide() {
        let session = DiffSessionState()
        session.start(
            old: makeSide(text: "a", containsSensitive: false),
            new: makeSide(text: "b", containsSensitive: true),
            failure: nil
        )
        XCTAssertTrue(session.containsSensitive, "任一侧敏感就必须走敏感复制通道")
    }

    func testOCRFlagTracksEitherSide() {
        let session = DiffSessionState()
        session.start(
            old: makeSide(text: "a", isOCRText: true),
            new: makeSide(text: "b", isOCRText: false),
            failure: nil
        )
        XCTAssertTrue(session.usesOCRText)
    }

    // MARK: - 长文本护栏

    /// 契约测试已保证 Rust 侧 2000 行 <2s，这里只保证 Swift 侧不引入额外开销
    func testLargeTextComputesWithoutBlockingForever() {
        let old = (0..<600).map { "line \($0)" }.joined(separator: "\n")
        let new = (0..<600).map { "line \($0 == 300 ? "300 changed" : "\($0)")" }.joined(separator: "\n")
        let session = makeActiveSession(old: old, new: new)
        XCTAssertTrue(session.hasChanges)
        XCTAssertEqual(session.mergedText, new)
    }

    func testTruncatedFlagPropagates() {
        // 超过 Rust 默认 1500 行上限
        let old = (0..<1600).map { "old \($0)" }.joined(separator: "\n")
        let new = (0..<1600).map { "new \($0)" }.joined(separator: "\n")
        let session = makeActiveSession(old: old, new: new)
        XCTAssertTrue(session.result?.stats.isTruncated ?? false, "超长文本必须标记截断")
    }
}

/// 会话便捷属性（`containsSensitive` / `usesOCRText`）与失败文案的独立校验，
/// 它们定义在 MainView+Diff.swift 的扩展里，但语义属于会话本身。
@MainActor
final class DiffSessionHelperTests: XCTestCase {

    private func makeSide(text: String, sensitive: Bool = false, ocr: Bool = false) -> DiffSide {
        DiffSide(itemID: UUID(), title: "t", text: text, containsSensitive: sensitive, isOCRText: ocr)
    }

    func testContainsSensitiveFalseWhenInactive() {
        let session = DiffSessionState()
        XCTAssertFalse(session.containsSensitive)
        XCTAssertFalse(session.usesOCRText)
    }

    func testMessageKeyMappingForEveryFailure() {
        XCTAssertEqual(DiffFailure.notEnoughItems.messageKey, "diff.error.not_enough_items")
        XCTAssertEqual(DiffFailure.tooManySelected(4).messageKey, "diff.error.too_many_selected")
        XCTAssertEqual(DiffFailure.noTextForDiff("t").messageKey, "diff.error.no_text")
        XCTAssertEqual(DiffFailure.revealFailed("t").messageKey, "diff.error.reveal_failed")
    }

    func testMessageArgsMatchPlaceholders() {
        XCTAssertTrue(DiffFailure.notEnoughItems.messageArgs.isEmpty)
        XCTAssertEqual(DiffFailure.tooManySelected(5).messageArgs, ["5"])
        XCTAssertEqual(DiffFailure.revealFailed("笔记").messageArgs, ["笔记"])
    }

    func testViewModeNextCyclesThroughAllThree() {
        XCTAssertEqual(DiffViewMode.inline.next, .sideBySide)
        XCTAssertEqual(DiffViewMode.sideBySide.next, .changesOnly)
        XCTAssertEqual(DiffViewMode.changesOnly.next, .inline)
    }

    func testHunkKeepRawValuesMatchRustChoiceCodes() {
        // 与 Rust `HunkChoice` 的编码一一对应：0 新 / 1 旧 / 2 都留
        XCTAssertEqual(DiffHunkKeep.new.rawValue, 0)
        XCTAssertEqual(DiffHunkKeep.old.rawValue, 1)
        XCTAssertEqual(DiffHunkKeep.both.rawValue, 2)
        XCTAssertEqual(DiffHunkKeep.allCases.count, 3)
    }

    // MARK: - 对比记录配对规则（resolvePairForDiff）

    private func makeRow(title: String) -> ClipboardRowModel {
        ClipboardRowModel(
            item: ClipboardItem(type: .text, title: title, summary: title)
        )
    }

    func testResolvePairWhenTopRowSelectedComparesTopTwo() {
        let r0 = makeRow(title: "latest")
        let r1 = makeRow(title: "second")
        let r2 = makeRow(title: "third")
        let resolution = MainView.resolvePairForDiff(
            flatRows: [r0, r1, r2],
            selectedID: r0.id,
            selectionIDs: []
        )
        guard case .pair(let old, let new) = resolution else {
            return XCTFail("应当成功选出两条记录")
        }
        XCTAssertEqual(old.id, r1.id, "选中第 1 条时，第 2 条作为旧版")
        XCTAssertEqual(new.id, r0.id, "选中第 1 条时，第 1 条作为新版")
    }

    func testResolvePairWhenLowerRowSingleSelectedComparesAgainstTopRow() {
        let r0 = makeRow(title: "latest")
        let r1 = makeRow(title: "second")
        let r2 = makeRow(title: "third")
        let resolution = MainView.resolvePairForDiff(
            flatRows: [r0, r1, r2],
            selectedID: r2.id,
            selectionIDs: []
        )
        guard case .pair(let old, let new) = resolution else {
            return XCTFail("单选第 3 条时应与第 1 条配对")
        }
        XCTAssertEqual(old.id, r2.id, "单选下方条目时，当前选中条目作为旧版")
        XCTAssertEqual(new.id, r0.id, "单选下方条目时，列表顶部最新条目作为新版")
    }

    func testResolvePairWhenTwoRowsMultiSelectedRespectsListOrder() {
        let r0 = makeRow(title: "latest")
        let r1 = makeRow(title: "second")
        let r2 = makeRow(title: "third")
        let resolution = MainView.resolvePairForDiff(
            flatRows: [r0, r1, r2],
            selectedID: r2.id,
            selectionIDs: [r1.id, r2.id]
        )
        guard case .pair(let old, let new) = resolution else {
            return XCTFail("多选 2 条时应直接配对这两条")
        }
        XCTAssertEqual(old.id, r2.id, "列表里靠下的为旧版")
        XCTAssertEqual(new.id, r1.id, "列表里靠上的为新版")
    }

    func testResolvePairFailsWhenMoreThanTwoSelectedOrNotEnoughItems() {
        let r0 = makeRow(title: "only")
        let notEnough = MainView.resolvePairForDiff(
            flatRows: [r0],
            selectedID: r0.id,
            selectionIDs: []
        )
        if case .failure(let f) = notEnough {
            XCTAssertEqual(f, .notEnoughItems)
        } else {
            XCTFail("仅 1 条记录时应返回 notEnoughItems")
        }

        let r1 = makeRow(title: "two")
        let r2 = makeRow(title: "three")
        let tooMany = MainView.resolvePairForDiff(
            flatRows: [r0, r1, r2],
            selectedID: r0.id,
            selectionIDs: [r0.id, r1.id, r2.id]
        )
        if case .failure(let f) = tooMany {
            XCTAssertEqual(f, .tooManySelected(3))
        } else {
            XCTFail("选中 3 条时应返回 tooManySelected(3)")
        }
    }

    func testNextDiffCursorRowSkipsPinnedAnchorAndClampsAtBounds() {
        let r0 = makeRow(title: "r0")
        let r1 = makeRow(title: "r1")
        let r2 = makeRow(title: "r2")
        let r3 = makeRow(title: "r3")
        let rows = [r0, r1, r2, r3]

        // 基准固定在 r0（首行），游标在 r1：按 ↑ 不能跳到基准行 r0，应返回 nil
        XCTAssertNil(
            MainView.nextDiffCursorRow(flatRows: rows, currentSelectedID: r1.id, anchorID: r0.id, step: -1),
            "基准在首行且游标在第二行时，向上无可移动目标"
        )

        // 基准固定在 r0，游标在 r1：按 ↓ 移动到 r2
        let downFromR1 = MainView.nextDiffCursorRow(flatRows: rows, currentSelectedID: r1.id, anchorID: r0.id, step: 1)
        XCTAssertEqual(downFromR1?.id, r2.id)

        // 基准固定在中间行 r2，游标在 r1：按 ↓ 应自动跨过 r2 落到 r3
        let skipAnchorDown = MainView.nextDiffCursorRow(flatRows: rows, currentSelectedID: r1.id, anchorID: r2.id, step: 1)
        XCTAssertEqual(skipAnchorDown?.id, r3.id, "经过基准行时应自动跨过，避免自己与自己对比")

        // 基准固定在中间行 r2，游标在 r3：按 ↑ 应自动跨过 r2 落到 r1
        let skipAnchorUp = MainView.nextDiffCursorRow(flatRows: rows, currentSelectedID: r3.id, anchorID: r2.id, step: -1)
        XCTAssertEqual(skipAnchorUp?.id, r1.id)
    }

    func testResolvePairWithAnchorOrdersNewAndOldByListPosition() {
        let r0 = makeRow(title: "r0")
        let r1 = makeRow(title: "r1")
        let r2 = makeRow(title: "r2")
        let rows = [r0, r1, r2]

        // 基准 r1 在上、目标 r2 在下 → r1 为新、r2 为旧
        let below = MainView.resolvePairWithAnchor(flatRows: rows, anchorID: r1.id, targetID: r2.id)
        XCTAssertEqual(below?.new.id, r1.id)
        XCTAssertEqual(below?.old.id, r2.id)

        // 基准 r1 在下、目标 r0 在上 → r0 为新、r1 为旧
        let above = MainView.resolvePairWithAnchor(flatRows: rows, anchorID: r1.id, targetID: r0.id)
        XCTAssertEqual(above?.new.id, r0.id)
        XCTAssertEqual(above?.old.id, r1.id)
    }

    func testSwitchingRecordsInSessionPreservesViewModeAndAnchor() {
        let session = DiffSessionState()
        let s0 = makeSide(text: "line 1\nline 2")
        let s1 = makeSide(text: "line 1\nline 2 old")
        let s2 = makeSide(text: "line 1\nline 2 older")

        session.start(old: s1, new: s0, failure: nil)
        XCTAssertEqual(session.anchorItemID, s0.itemID, "默认固定新版为基准")

        session.viewMode = .sideBySide
        session.setAnchor(s1.itemID)
        XCTAssertEqual(session.anchorItemID, s1.itemID, "点击固定侧应切换 anchorItemID")

        // 实时切换到 s2（保留 s1）
        session.start(old: s2, new: s1, failure: nil)
        XCTAssertEqual(session.viewMode, .sideBySide, "实时切换记录时必须保留用户选中的视图模式")
        XCTAssertEqual(session.anchorItemID, s1.itemID, "实时切换记录时必须保留已固定的基准 ID")
    }
}
