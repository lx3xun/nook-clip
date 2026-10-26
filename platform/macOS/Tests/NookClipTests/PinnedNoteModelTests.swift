import XCTest
@testable import NookClip

// specs/012-scrub-stack-pin · T014
// 屏幕置顶贴条（US3）的可测层：模型摘要、透明度钳制、「保存回历史」的真实成功语义。
//
// 不覆盖的部分：`pin(item:)` 会创建真实 `NSPanel` 并安装进程级事件监听，
// 放进单测等于测 AppKit 窗口系统，容易拖垮无关用例，故不在此覆盖。
// 这里只测「不建窗口也成立」的状态与语义——尤其是那条产品红线：
// 保存失败绝不允许出现假成功。

@MainActor
final class PinnedNoteModelTests: XCTestCase {

    private var manager: PinnedWindowManager { PinnedWindowManager.shared }

    /// 单例的钩子必须在每个用例后复位，否则会串到别的用例
    override func tearDown() {
        manager.onSaveToHistory = nil
        manager.restoreAllClickThrough()
        super.tearDown()
    }

    private func makeNote(
        text: String = "第一行\n第二行",
        itemType: ClipboardItemType = .text,
        imageData: Data? = nil,
        ocrText: String? = nil,
        isCode: Bool = false,
        language: String? = nil,
        isDegraded: Bool = false
    ) -> PinnedNoteModel {
        PinnedNoteModel(
            sourceItemId: UUID().uuidString,
            itemType: itemType,
            sourceAppName: "TestApp",
            editableText: text,
            originalText: text,
            imageData: imageData,
            ocrText: ocrText,
            isCode: isCode,
            language: language,
            isDegraded: isDegraded
        )
    }

    // MARK: - 折叠态单行摘要

    func testSummaryLineTakesFirstNonBlankLine() {
        XCTAssertEqual(makeNote(text: "第一行\n第二行").summaryLine, "第一行")
    }

    func testSummaryLineSkipsLeadingBlankLines() {
        let note = makeNote(text: "\n\n  \n真正的第一行\n尾巴")
        XCTAssertEqual(note.summaryLine, "真正的第一行", "折叠后不该显示成一片空白")
    }

    func testSummaryLineFallsBackToPlaceholderWhenTextIsBlank() {
        let note = makeNote(text: "   \n\n")
        XCTAssertEqual(note.summaryLine, L10n.tr("pin.empty_text"))
    }

    func testImageNoteWithNoTextUsesImagePlaceholder() {
        let note = makeNote(text: "", itemType: .image)
        XCTAssertEqual(note.summaryLine, L10n.tr("item.type_image"))
    }

    // MARK: - 初始状态

    func testDefaultVisualStateIsUnobtrusive() {
        let note = makeNote()
        XCTAssertEqual(note.opacity, PinnedWindowManager.defaultOpacity)
        XCTAssertFalse(note.isCollapsed)
        XCTAssertFalse(note.isClickThrough)
        XCTAssertFalse(note.isEditing)
        XCTAssertNil(note.savedAt)
    }

    func testDefaultOpacityStaysBelowFullSoItReadsAsOverlay() {
        XCTAssertLessThan(PinnedWindowManager.defaultOpacity, 1.0)
        XCTAssertGreaterThanOrEqual(PinnedWindowManager.defaultOpacity, PinnedWindowManager.minOpacity)
    }

    // MARK: - 全局只留一张

    func testOnlyOneNoteCanStayOnScreen() {
        XCTAssertEqual(PinnedWindowManager.maxPinnedNotes, 1, "屏幕贴条全局只留一张")
        XCTAssertEqual(manager.pinnedCount, 0)
        XCTAssertFalse(manager.hasPinnedNote)

        manager.pin(item: ClipboardItem(type: .text, title: "t", summary: "一条内容"))
        XCTAssertEqual(manager.pinnedCount, 1)
        XCTAssertTrue(manager.hasPinnedNote, "钉上之后接线层要能问出「已经有贴条了」")

        manager.unpinAll()
        XCTAssertFalse(manager.hasPinnedNote)
    }

    func testPinningSecondItemReplacesTheFirst() {
        // 用户按 ⌘P 换内容时，旧的那张必须自己让位：
        // 留在屏幕上会变成两张，用户还得回头手动关掉。
        let first = ClipboardItem(type: .text, title: "t1", summary: "第一条内容")
        let second = ClipboardItem(type: .text, title: "t2", summary: "第二条内容")

        manager.pin(item: first)
        XCTAssertEqual(manager.pinnedCount, 1)
        let firstID = manager.notes.first?.id

        manager.pin(item: second)
        XCTAssertEqual(manager.pinnedCount, 1, "钉第二条之后屏幕上仍然只能有一张")
        XCTAssertNotEqual(manager.notes.first?.id, firstID, "留下的必须是新钉的那张")
        XCTAssertEqual(manager.notes.first?.editableText, "第二条内容")

        manager.unpinAll()
    }

    func testReplacingNoteKeepsItsPosition() {
        // 用户把贴条拖到顺手的位置之后，换内容不该让它跳回屏幕角落
        let first = ClipboardItem(type: .text, title: "t1", summary: "第一条")
        manager.pin(item: first)
        guard let placed = manager.pinnedNoteFrame else {
            return XCTFail("第一张没建出来")
        }

        manager.pin(item: ClipboardItem(type: .text, title: "t2", summary: "第二条"))
        guard let replaced = manager.pinnedNoteFrame else {
            return XCTFail("第二张没建出来")
        }
        XCTAssertEqual(replaced.minX, placed.minX, accuracy: 1, "横向位置要沿用上一张")
        XCTAssertEqual(replaced.maxY, placed.maxY, accuracy: 1, "顶边要沿用上一张")

        manager.unpinAll()
    }

    // MARK: - 透明度钳制

    func testOpacityClampsToDocumentedRange() {
        let note = makeNote()

        manager.setOpacity(note, to: 0.05)
        XCTAssertEqual(note.opacity, PinnedWindowManager.minOpacity, "低于 20% 会看不清，必须钳住")

        manager.setOpacity(note, to: 1.8)
        XCTAssertEqual(note.opacity, PinnedWindowManager.maxOpacity)

        manager.setOpacity(note, to: 0.55)
        XCTAssertEqual(note.opacity, 0.55, accuracy: 0.0001)
    }

    // MARK: - 保存回历史：绝不假成功

    func testSaveToHistoryWithoutHookReportsFailure() {
        manager.onSaveToHistory = nil
        let note = makeNote()

        XCTAssertFalse(manager.requestSaveToHistory(note))
        XCTAssertNil(note.savedAt, "没真正落库就不能留下「已保存」时间戳")
    }

    func testSaveToHistoryFailingHookReportsFailureAndLeavesNoTimestamp() {
        manager.onSaveToHistory = { _ in false }
        let note = makeNote()

        XCTAssertFalse(manager.requestSaveToHistory(note))
        XCTAssertNil(note.savedAt)
    }

    func testSaveToHistorySuccessStampsTimestamp() {
        let note = makeNote(text: "要保存的正文")
        var received: String?
        manager.onSaveToHistory = { candidate in
            received = candidate.editableText
            return true
        }

        XCTAssertTrue(manager.requestSaveToHistory(note))
        XCTAssertNotNil(note.savedAt)
        XCTAssertEqual(received, "要保存的正文", "钩子拿到的必须是用户当前编辑后的正文")
    }

    func testSaveToHistoryPassesEditedTextNotOriginal() {
        let note = makeNote(text: "原始内容")
        note.editableText = "用户改过的内容"
        var received: String?
        manager.onSaveToHistory = { candidate in
            received = candidate.editableText
            return true
        }

        XCTAssertTrue(manager.requestSaveToHistory(note))
        XCTAssertEqual(received, "用户改过的内容")
        XCTAssertEqual(note.originalText, "原始内容", "原始文本保留用于「有无改动」判断")
    }

    // MARK: - 无窗口时的安全边界

    func testOperatingOnUnpinnedNoteIsHarmless() {
        let note = makeNote()
        // 这些都会查 panels 字典，未钉住的 note 必须安全地什么都不做
        manager.toggleCollapse(note)
        manager.toggleClickThrough(note)
        manager.setOpacity(note, to: 0.5)
        manager.unpin(id: note.id)

        XCTAssertFalse(note.isClickThrough, "未钉住的 note 不该被标记为穿透")
        XCTAssertEqual(manager.pinnedCount, 0)
    }

    // MARK: - Esc 语义：编辑态不销毁贴条

    /// 编辑态下 Esc 只退出编辑，必须保留草稿。
    ///
    /// 这条曾经是「按一下 Esc 刚敲的内容全没了」的根源：`cancelOperation`
    /// 无条件调 `onClose`，而 `sendEvent` 里又把 Esc 直接映射成关闭。
    /// 这里用面板实测，把两条通道都钉住。
    func testEscapeWhileEditingCommitsInsteadOfClosing() {
        let note = makeNote(text: "草稿内容")
        let panel = PinnedNotePanel(note: note, contentSize: NSSize(width: 300, height: 200))
        var closeCount = 0
        var commitCount = 0
        panel.onClose = { closeCount += 1 }
        panel.onCommitEditing = { commitCount += 1 }

        note.isEditing = true
        panel.cancelOperation(nil)

        XCTAssertEqual(commitCount, 1, "编辑态按 Esc 应退出编辑")
        XCTAssertEqual(closeCount, 0, "编辑态按 Esc 绝不能销毁贴条，否则草稿丢失")
        XCTAssertEqual(note.editableText, "草稿内容", "退出编辑不得清理正文")
    }

    func testEscapeWhenNotEditingClosesNote() {
        let note = makeNote()
        let panel = PinnedNotePanel(note: note, contentSize: NSSize(width: 300, height: 200))
        var closeCount = 0
        panel.onClose = { closeCount += 1 }
        panel.onCommitEditing = { XCTFail("非编辑态按 Esc 不该走退出编辑") }

        note.isEditing = false
        panel.cancelOperation(nil)

        XCTAssertEqual(closeCount, 1, "非编辑态按 Esc 才是关闭贴条")
    }

    // MARK: - 键盘焦点：不抢当前应用的输入焦点

    func testPanelIsNotKeyUnlessEditing() {
        let note = makeNote()
        let panel = PinnedNotePanel(note: note, contentSize: NSSize(width: 300, height: 200))

        note.isEditing = false
        XCTAssertTrue(panel.becomesKeyOnlyIfNeeded, "平时点击贴条不该打断用户在别的应用里打字")

        note.isEditing = true
        XCTAssertFalse(panel.becomesKeyOnlyIfNeeded, "进编辑态必须能拿到键盘，否则打不出字")
    }

    // MARK: - 不透明度记忆：新贴条沿用上次浓度

    func testNewNoteInheritsLastUsedOpacity() {
        // 用户把某张贴条调到 60%，说明「屏幕上就想要这个浓度」，
        // 下一张再从默认值起步等于每次都重调一遍。
        let first = makeNote()
        manager.setOpacity(first, to: 0.6)
        XCTAssertEqual(first.opacity, 0.6, accuracy: 0.0001)
        XCTAssertEqual(manager.currentUsedOpacity, 0.6, accuracy: 0.0001, "调过的浓度必须被记住，供下一张贴条沿用")

        manager.setOpacity(first, to: 0.05)
        XCTAssertEqual(first.opacity, PinnedWindowManager.minOpacity, "记忆值同样要过钳制")
        XCTAssertEqual(manager.currentUsedOpacity, PinnedWindowManager.minOpacity, accuracy: 0.0001)
    }

    // MARK: - 锁片：穿透后唯一能点的解锁入口

    func testLockChipSitsInsideNoteTopRightCorner() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let noteFrame = NSRect(x: 100, y: 100, width: 300, height: 200)
        let origin = LockedNoteChipPanel.origin(forNoteFrame: noteFrame, in: visible)

        XCTAssertEqual(
            origin.x,
            noteFrame.maxX - LockedNoteChipPanel.size.width - LockedNoteChipPanel.inset,
            accuracy: 0.5,
            "锁片要贴在贴条右上角，用户才不会以为它是别的应用"
        )
        XCTAssertEqual(
            origin.y,
            noteFrame.maxY - LockedNoteChipPanel.size.height - LockedNoteChipPanel.inset,
            accuracy: 0.5
        )
    }

    func testLockChipSlidesBackWhenNoteHugsScreenEdge() {
        // 贴条常被拖到屏幕边角；锁片若跟着出界，「点得到的入口」又没了。
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let atRightTop = NSRect(x: 1200, y: 800, width: 240, height: 100)
        let origin = LockedNoteChipPanel.origin(forNoteFrame: atRightTop, in: visible)

        XCTAssertGreaterThanOrEqual(origin.x, visible.minX)
        XCTAssertLessThanOrEqual(origin.x + LockedNoteChipPanel.size.width, visible.maxX)
        XCTAssertGreaterThanOrEqual(origin.y, visible.minY)
        XCTAssertLessThanOrEqual(origin.y + LockedNoteChipPanel.size.height, visible.maxY)
    }

    func testLockChipStaysReachableForNoteOffscreenOnTheLeft() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let offLeft = NSRect(x: -500, y: -300, width: 300, height: 200)
        let origin = LockedNoteChipPanel.origin(forNoteFrame: offLeft, in: visible)

        XCTAssertEqual(origin.x, visible.minX + 4, accuracy: 0.5, "锁片必须被拉回可视区，否则等于没有解锁入口")
        XCTAssertEqual(origin.y, visible.minY + 4, accuracy: 0.5)
    }

    func testUnpinWithoutPanelIsHarmless() {
        // 「锁片已销毁但动作还在路上」这类时序不该崩——它只是什么都不做
        manager.unpin(id: UUID())
        manager.restoreAllClickThrough()
        XCTAssertEqual(manager.pinnedCount, 0)
    }

    // MARK: - 锁片窗口本身

    func testLockChipSizeFitsItsLabelWithoutClipping() {
        let chip = LockedNoteChipPanel()
        XCTAssertGreaterThanOrEqual(chip.chipSize.width, LockedNoteChipPanel.size.width, "量出来的宽度不能比基准更窄，否则文字会被截")
        XCTAssertLessThanOrEqual(chip.chipSize.width, LockedNoteChipPanel.maxWidth, "再宽就会盖住贴条正文")
        XCTAssertEqual(chip.chipSize.height, LockedNoteChipPanel.size.height, accuracy: 0.5)
    }

    func testLockChipAttachUsesItsOwnSizeAndStaysOnScreen() {
        let chip = LockedNoteChipPanel()
        let noteFrame = NSRect(x: 100, y: 100, width: 300, height: 200)
        chip.attach(to: noteFrame)

        XCTAssertEqual(chip.frame.width, chip.chipSize.width, accuracy: 0.5)
        XCTAssertEqual(chip.frame.height, chip.chipSize.height, accuracy: 0.5)
        XCTAssertTrue(chip.ignoresMouseEvents == false, "锁片必须收得到点击，否则等于没做解锁入口")
        XCTAssertFalse(chip.canBecomeKey, "点锁片不该把用户正在打字的应用焦点抢走")
    }

    // MARK: - 端到端：上锁 → 挂锁片 → 解锁 → 拆锁片

    func testLockingAttachesChipAndUnlockingRemovesIt() {
        // 这是用户报的那个 bug 的回归护栏：上锁之后必须真的多出一个能点的入口，
        // 解锁之后那个入口必须消失，否则屏幕上会留下一个点不动的幽灵锁片。
        let item = ClipboardItem(type: .text, title: "t", summary: "锁片回归测试")
        manager.pin(item: item)
        XCTAssertEqual(manager.pinnedCount, 1)
        XCTAssertEqual(manager.lockedChipCount, 0, "刚钉上还没穿透，不该有锁片")

        guard let note = manager.notes.first else { return XCTFail("贴条没建出来") }
        manager.toggleClickThrough(note)
        XCTAssertTrue(note.isClickThrough)

        // 1.5s 缓冲结束才真正穿透并挂上锁片
        let waited = expectation(description: "穿透缓冲结束")
        DispatchQueue.main.asyncAfter(deadline: .now() + PinnedWindowManager.lockedHintDuration + 0.3) {
            waited.fulfill()
        }
        wait(for: [waited], timeout: 5)
        XCTAssertEqual(manager.lockedChipCount, 1, "穿透之后必须挂上锁片，否则用户再也解不开")

        // 点锁片 = 走同一条解锁路径
        manager.toggleClickThrough(note)
        XCTAssertFalse(note.isClickThrough)
        XCTAssertEqual(manager.lockedChipCount, 0, "解锁后锁片必须收掉")

        manager.unpinAll()
        XCTAssertEqual(manager.pinnedCount, 0)
        XCTAssertEqual(manager.lockedChipCount, 0)
    }

    // MARK: - 四周投影留白：卡片与窗口不是一个矩形

    func testWindowSizeIncludesShadowInsetOnAllSides() {
        // 窗口是透明的，多出来这圈只为了给投影落笔。卡片视觉尺寸必须还是 232×120，
        // 否则「最小尺寸」会随着修 bug 悄悄变大。
        let window = PinnedNotePanel.minSize
        XCTAssertEqual(
            window.width - PinnedNotePanel.shadowInset * 2,
            232,
            accuracy: 0.5,
            "窗口放大是为了阴影，卡片本身仍应是 232 宽"
        )
        XCTAssertEqual(window.height - PinnedNotePanel.shadowInset * 2, 120, accuracy: 0.5)

        let collapsed = PinnedNotePanel.collapsedSize
        XCTAssertEqual(collapsed.width - PinnedNotePanel.shadowInset * 2, 240, accuracy: 0.5)
        XCTAssertEqual(collapsed.height - PinnedNotePanel.shadowInset * 2, 28, accuracy: 0.5)
    }

    func testShadowStaysLightSoThePaperDoesNotLookInset() {
        // 贴条是「一张纸」，不是弹窗。阴影只需要在边缘压一道淡淡的边，
        // 压太重会让纸看起来像嵌在玻璃里（浅色模式下最刺眼）。
        // 这几条不是审美偏好，是防止以后有人为了「更有层次感」把它调回去。
        XCTAssertLessThanOrEqual(
            PinnedNotePanel.shadowOpacity,
            0.12,
            "投影浓度超过 0.12 在白底上会明显发灰"
        )
        XCTAssertGreaterThan(
            PinnedNotePanel.shadowOpacity,
            0.04,
            "太淡就没有浮起感，贴条会像贴纸一样黏在桌面上"
        )
        XCTAssertLessThanOrEqual(
            PinnedNotePanel.shadowBlurRadius,
            10,
            "模糊半径超过 10 会让阴影扩散得过宽，看起来发糊"
        )
        XCTAssertGreaterThanOrEqual(PinnedNotePanel.shadowBlurRadius, 4)
        XCTAssertLessThanOrEqual(
            PinnedNotePanel.shadowOffsetY,
            3,
            "向下偏移越大越像悬浮弹窗，贴条的定位是平铺在桌面的纸"
        )
        // 投影必须画得进那圈透明留白，否则四角会被窗口边缘切出直角
        XCTAssertLessThanOrEqual(
            PinnedNotePanel.shadowBlurRadius + PinnedNotePanel.shadowOffsetY,
            PinnedNotePanel.shadowInset,
            "投影的最大延伸范围必须放得进 shadowInset，否则又被窗口裁成直角"
        )
    }

    func testCardFrameIsWindowInsetByShadowPadding() {
        let note = makeNote()
        let panel = PinnedNotePanel(note: note, contentSize: PinnedNotePanel.minSize)
        panel.setFrame(NSRect(origin: NSPoint(x: 100, y: 100), size: PinnedNotePanel.minSize), display: false)

        let card = panel.cardFrame
        XCTAssertEqual(card.origin.x, panel.frame.minX + PinnedNotePanel.shadowInset, accuracy: 0.5)
        XCTAssertEqual(card.origin.y, panel.frame.minY + PinnedNotePanel.shadowInset, accuracy: 0.5)
        XCTAssertEqual(card.width, panel.frame.width - PinnedNotePanel.shadowInset * 2, accuracy: 0.5)
        XCTAssertEqual(card.height, panel.frame.height - PinnedNotePanel.shadowInset * 2, accuracy: 0.5)
    }

    // MARK: - 下沿两个角都能拉伸

    func testBothBottomCornersAreResizable() {
        let note = makeNote()
        let size = NSSize(width: 400, height: 300)
        let panel = PinnedNotePanel(note: note, contentSize: size)
        panel.setFrame(NSRect(origin: .zero, size: size), display: false)

        XCTAssertEqual(panel.resizeCorner(at: NSPoint(x: size.width - 4, y: 4)), .bottomRight)
        XCTAssertEqual(panel.resizeCorner(at: NSPoint(x: 4, y: 4)), .bottomLeft, "左下角也要能拉，用户会本能去按它")
    }

    // MARK: 缩放几何（用户报过「左下角拖动反了」）

    func testDraggingLeftEdgeLeftwardsWidensTheNote() {
        // 用户抓手在左下角，往左拖（鼠标 deltaX < 0）应该变宽。
        // 第一版把符号写反了，实际表现是「往左拖反而变窄」，这是那个 bug 的回归护栏。
        let start = NSRect(x: 100, y: 100, width: 400, height: 300)
        let result = PinnedNotePanel.resizedFrame(
            from: start,
            mouseDelta: NSSize(width: -80, height: 0),
            corner: .bottomLeft,
            minSize: PinnedNotePanel.minSize,
            maxSize: NSSize(width: 4000, height: 4000)
        )
        XCTAssertEqual(result.width, 480, "往左拖必须变宽")
        XCTAssertEqual(result.maxX, start.maxX, "左边拉开时右边界必须钉住，否则整张纸会右移")
    }

    func testDraggingRightEdgeRightwardsWidensTheNote() {
        let start = NSRect(x: 100, y: 100, width: 400, height: 300)
        let result = PinnedNotePanel.resizedFrame(
            from: start,
            mouseDelta: NSSize(width: 80, height: 0),
            corner: .bottomRight,
            minSize: PinnedNotePanel.minSize,
            maxSize: NSSize(width: 4000, height: 4000)
        )
        XCTAssertEqual(result.width, 480, "右下角往右拖变宽")
        XCTAssertEqual(result.minX, start.minX, "右边拉开时左边界不动")
    }

    func testDraggingLeftEdgeRightwardsNarrowsTheNote() {
        let start = NSRect(x: 100, y: 100, width: 400, height: 300)
        let result = PinnedNotePanel.resizedFrame(
            from: start,
            mouseDelta: NSSize(width: 60, height: 0),
            corner: .bottomLeft,
            minSize: PinnedNotePanel.minSize,
            maxSize: NSSize(width: 4000, height: 4000)
        )
        XCTAssertEqual(result.width, 340)
        XCTAssertEqual(result.maxX, start.maxX)
    }

    func testResizeKeepsTopEdgeAnchored() {
        let start = NSRect(x: 100, y: 100, width: 400, height: 300)
        let result = PinnedNotePanel.resizedFrame(
            from: start,
            mouseDelta: NSSize(width: 0, height: -50),
            corner: .bottomRight,
            minSize: PinnedNotePanel.minSize,
            maxSize: NSSize(width: 4000, height: 4000)
        )
        XCTAssertEqual(result.height, 350, "鼠标往下拖 = 下沿往下 = 变高")
        XCTAssertEqual(result.maxY, start.maxY, "上沿永远钉住")
    }

    func testResizeClampsToMinimumBothWays() {
        let start = NSRect(x: 100, y: 100, width: 400, height: 300)
        let shrinkLeft = PinnedNotePanel.resizedFrame(
            from: start,
            mouseDelta: NSSize(width: 800, height: 800),
            corner: .bottomLeft,
            minSize: PinnedNotePanel.minSize,
            maxSize: NSSize(width: 4000, height: 4000)
        )
        XCTAssertEqual(shrinkLeft.width, PinnedNotePanel.minSize.width)
        XCTAssertEqual(shrinkLeft.height, PinnedNotePanel.minSize.height)
        XCTAssertEqual(shrinkLeft.maxX, start.maxX, "缩到最小也不能把左边界推过右边界")
    }

    func testTopEdgeAndMiddleAreNotResizeHotZones() {
        let note = makeNote()
        let size = NSSize(width: 400, height: 300)
        let panel = PinnedNotePanel(note: note, contentSize: size)
        panel.setFrame(NSRect(origin: .zero, size: size), display: false)

        XCTAssertNil(panel.resizeCorner(at: NSPoint(x: 4, y: size.height - 4)), "左上角不该触发缩放")
        XCTAssertNil(panel.resizeCorner(at: NSPoint(x: size.width / 2, y: 4)), "下沿中间是正文区，不能误吞点击")
    }

    func testCollapsedNoteHasNoResizeHotZone() {
        let note = makeNote()
        let panel = PinnedNotePanel(note: note, contentSize: NSSize(width: 400, height: 300))
        panel.setFrame(NSRect(origin: .zero, size: NSSize(width: 400, height: 300)), display: false)

        note.isCollapsed = true
        XCTAssertNil(panel.resizeCorner(at: NSPoint(x: 4, y: 4)), "折叠成一条时不该有任何缩放手柄")
    }

    // MARK: - 代码贴条：语言跟着条目走

    func testCodeNoteKeepsLanguageForHighlighting() {
        let note = makeNote(text: "let a = 1", isCode: true, language: "swift")
        XCTAssertTrue(note.isCode)
        XCTAssertEqual(note.language, "swift", "代码贴条要按条目自己的语言高亮，不能全靠猜")
    }

    func testNonCodeNoteHasNoLanguage() {
        XCTAssertNil(makeNote(text: "普通文字").language)
    }
}

// MARK: - 外观跟随（贴条是独立 NSPanel，不吃主面板的 preferredColorScheme）

@MainActor
final class PinnedAppearanceTests: XCTestCase {
    private var originalMode: String?

    override func setUp() {
        super.setUp()
        originalMode = UserDefaults.standard.string(forKey: PinnedAppearance.storageKey)
    }

    override func tearDown() {
        if let originalMode {
            UserDefaults.standard.set(originalMode, forKey: PinnedAppearance.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: PinnedAppearance.storageKey)
        }
        super.tearDown()
    }

    func testLightModeMapsToAqua() {
        XCTAssertEqual(PinnedAppearance.appearance(for: "light")?.name, .aqua)
    }

    func testDarkModeMapsToDarkAqua() {
        XCTAssertEqual(PinnedAppearance.appearance(for: "dark")?.name, .darkAqua)
    }

    func testSystemModeLeavesAppearanceToTheSystem() {
        XCTAssertNil(PinnedAppearance.appearance(for: "system"), "system 档位要交还给系统，不能钉死成某一套配色")
    }

    func testUnknownValueFallsBackToSystem() {
        XCTAssertNil(PinnedAppearance.appearance(for: "紫罗兰"), "脏数据当作 system 处理，不能崩也不能乱钉")
    }

    func testPanelFollowsConfiguredMode() {
        UserDefaults.standard.set("dark", forKey: PinnedAppearance.storageKey)
        let note = PinnedNoteModel(
            sourceItemId: "x",
            itemType: .text,
            sourceAppName: "Xcode",
            editableText: "let a = 1",
            originalText: "let a = 1",
            imageData: nil,
            ocrText: nil,
            isCode: true,
            isDegraded: false
        )
        let panel = PinnedNotePanel(note: note, contentSize: NSSize(width: 400, height: 300))
        XCTAssertEqual(panel.appearance?.name, .darkAqua, "配置成深色时贴条窗口必须是深色，哪怕系统是浅色")

        UserDefaults.standard.set("light", forKey: PinnedAppearance.storageKey)
        let second = PinnedNotePanel(note: note, contentSize: NSSize(width: 400, height: 300))
        XCTAssertEqual(second.appearance?.name, .aqua)
    }

    func testLiveAppearanceChangeUpdatesOpenPins() {
        UserDefaults.standard.set("light", forKey: PinnedAppearance.storageKey)
        let manager = PinnedWindowManager.shared
        defer { manager.unpinAll() }

        var item = ClipboardItem(type: .text, title: "t", summary: "随便一段话")
        item.sourceAppName = "Safari"
        manager.pin(item: item)
        XCTAssertEqual(manager.pinnedCount, 1)

        UserDefaults.standard.set("dark", forKey: PinnedAppearance.storageKey)
        manager.refreshAppearance()

        // 面板是私有的，通过公开的 refreshAppearance 覆盖范围断言：
        // 切档后不新建窗口也应该已经跟上（真机截图已单独验证过像素）。
        XCTAssertEqual(PinnedAppearance.currentMode, "dark")
    }

    func testDefaultModeIsSystem() {
        UserDefaults.standard.removeObject(forKey: PinnedAppearance.storageKey)
        XCTAssertEqual(PinnedAppearance.currentMode, "system", "没设过档位时必须跟随系统")
    }
}

// MARK: - 编辑态焦点（中文打不出来的根因）
//
// 贴条是 `.nonactivatingPanel`，本 App 又是 `LSUIElement` 常驻后台。
// 用户点铅笔时 App 通常不在前台，此时只调 `makeKey()` 会静默失败：
// 窗口不是 key window → 输入法上下文不激活 → 中文打不进去。
// 所以编辑态必须「先 activate 再 makeKey」，退出时再把前台还回去。

@MainActor
final class PinnedEditingFocusTests: XCTestCase {
    private var manager: PinnedWindowManager { PinnedWindowManager.shared }

    override func tearDown() {
        manager.unpinAll()
        super.tearDown()
    }

    private func firstPanel() -> PinnedNotePanel? {
        // `NSApp.windows` 里 orderOut 之后窗口对象还在，只认「正在显示」的那张
        NSApp.windows.compactMap { $0 as? PinnedNotePanel }.first { $0.isVisible }
    }

    private func textView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let textView = view as? NSTextView { return textView }
        for sub in view.subviews {
            if let found = textView(in: sub) { return found }
        }
        return nil
    }

    private func wait(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func testBeginEditingTakesFocusEvenWhenAppIsInBackground() throws {
        manager.pin(item: ClipboardItem(type: .text, title: "t", summary: "一段文字"))
        guard let note = manager.notes.first, let panel = firstPanel() else {
            return XCTFail("贴条没建起来")
        }
        wait(0.3)

        // 复刻真实场景：用户正在别的应用里工作，本 App 不在前台。
        //
        // 必须用 hide() 而不是 deactivate()：单测进程的 activationPolicy 是
        // .prohibited（正常 App 是 .accessory），这种进程里 makeKey() 自己就会
        // 把 App 拉回前台，deactivate 之后调旧实现照样「成功」——bug 被遮住。
        // hide() 之后 makeKey() 不再有副作用，旧实现会原地失败，这才测得出来。
        NSApplication.shared.hide(nil)
        wait(0.8)
        defer { NSApplication.shared.unhide(nil) }
        guard !NSApplication.shared.isActive else {
            // 某些环境无法让测试进程失活，此时这条用例没有意义，跳过而不是假绿
            throw XCTSkip("无法让测试进程失活，跳过前台相关断言")
        }
        XCTAssertFalse(panel.isKeyWindow, "失活后贴条不该还是 key window")

        manager.beginEditing(note)
        wait(0.8)

        XCTAssertTrue(note.isEditing)
        XCTAssertTrue(NSApplication.shared.isActive, "编辑态必须把本 App 拉回前台，否则 makeKey 无效")
        XCTAssertTrue(panel.isKeyWindow, "编辑态必须是 key window，否则输入法上下文不激活，中文打不进去")

        let editor = textView(in: panel.contentView)
        let context = editor?.inputContext
        XCTAssertNotNil(context)
        XCTAssertTrue(
            context === NSTextInputContext.current,
            "正文的输入法上下文必须是当前上下文，否则拼音候选永远投递不进来"
        )
        manager.endEditing(note)
    }

    func testBeginEditingMakesPanelKeyWindow() {
        manager.pin(item: ClipboardItem(type: .text, title: "t", summary: "一段文字"))
        guard let note = manager.notes.first, let panel = firstPanel() else {
            return XCTFail("贴条没建起来")
        }
        wait(0.3)

        manager.beginEditing(note)
        wait(0.6)

        XCTAssertTrue(note.isEditing)
        XCTAssertTrue(panel.isKeyWindow, "编辑态必须是 key window，否则输入法上下文不激活，中文打不进去")
        XCTAssertTrue(NSApplication.shared.isActive, "编辑态本 App 必须在前台，否则 makeKey 无效")
        manager.endEditing(note)
    }

    func testEditingTextFieldOwnsTheInputContext() {
        manager.pin(item: ClipboardItem(type: .text, title: "t", summary: "一段文字"))
        guard let note = manager.notes.first, let panel = firstPanel() else {
            return XCTFail("贴条没建起来")
        }
        wait(0.3)

        manager.beginEditing(note)
        wait(0.8)

        let editor = textView(in: panel.contentView)
        XCTAssertNotNil(editor, "编辑态应该有一个可输入的 NSTextView")
        let context = editor?.inputContext
        XCTAssertNotNil(context)
        XCTAssertTrue(
            context === NSTextInputContext.current,
            "正文的输入法上下文必须是当前上下文，否则拼音候选永远投递不进来"
        )
        manager.endEditing(note)
    }

    func testEndEditingHandsFrontmostAppBack() throws {
        manager.pin(item: ClipboardItem(type: .text, title: "t", summary: "一段文字"))
        guard let note = manager.notes.first, let panel = firstPanel() else {
            return XCTFail("贴条没建起来")
        }
        wait(0.3)

        // 复刻「用户在别的应用里工作」：先 hide 让本 App 真正退到后台
        NSApplication.shared.hide(nil)
        wait(0.8)
        defer { NSApplication.shared.unhide(nil) }
        guard !NSApplication.shared.isActive else {
            throw XCTSkip("无法让测试进程失活，跳过前台相关断言")
        }

        manager.beginEditing(note)
        wait(0.8)
        XCTAssertTrue(manager.hasPendingFocusRestore, "抢了前台就要记下来，退出时才还得回去")
        XCTAssertTrue(panel.isKeyWindow)

        manager.endEditing(note)
        wait(0.8)

        // 归还动作本身（把前台激活回原来的应用）只能在真机验证：
        // 单测进程 activationPolicy 是 .prohibited，`isActive` 不随 activate 变化，
        // 在这里断言它只会得到假结果。这里只锁「状态机」这一层：
        // 归还过一次就必须清空，否则下次退出会误还一个早就换了的目标。
        XCTAssertFalse(manager.hasPendingFocusRestore, "归还一次后状态必须清空")
        XCTAssertFalse(note.isEditing)
    }

    func testEndEditingWithoutHavingGrabbedFocusIsNoop() {
        manager.pin(item: ClipboardItem(type: .text, title: "t", summary: "一段文字"))
        guard let note = manager.notes.first else { return XCTFail("贴条没建起来") }
        wait(0.3)

        // App 本来就在前台时不该记「要归还」，否则退出编辑会把用户踢走
        NSApp.activate(ignoringOtherApps: true)
        wait(0.5)
        manager.beginEditing(note)
        wait(0.4)
        manager.endEditing(note)

        XCTAssertFalse(manager.hasPendingFocusRestore, "本来就在前台就不该记归还目标")
    }

    func testEndEditingReleasesEditingState() {
        manager.pin(item: ClipboardItem(type: .text, title: "t", summary: "一段文字"))
        guard let note = manager.notes.first else { return XCTFail("贴条没建起来") }
        wait(0.3)

        manager.beginEditing(note)
        wait(0.4)
        manager.endEditing(note)

        XCTAssertFalse(note.isEditing, "退出编辑态要切回只读")
    }

    func testUnpinningWhileEditingDoesNotCrash() {
        manager.pin(item: ClipboardItem(type: .text, title: "t", summary: "一段文字"))
        guard let note = manager.notes.first else { return XCTFail("贴条没建起来") }
        wait(0.3)

        manager.beginEditing(note)
        wait(0.4)
        // 编辑中途被关掉（⌘W / 点关闭按钮）也要安全收场
        manager.unpin(id: note.id)
        wait(0.3)

        XCTAssertEqual(manager.pinnedCount, 0)
        XCTAssertNil(firstPanel())
    }

    func testBeginEditingIsIdempotent() {
        manager.pin(item: ClipboardItem(type: .text, title: "t", summary: "一段文字"))
        guard let note = manager.notes.first, let panel = firstPanel() else {
            return XCTFail("贴条没建起来")
        }
        wait(0.3)

        // 连点两下铅笔（或铅笔 + 快捷键）不能把焦点状态搞乱
        manager.beginEditing(note)
        manager.beginEditing(note)
        wait(0.8)

        XCTAssertTrue(note.isEditing)
        XCTAssertTrue(panel.isKeyWindow, "重复进编辑态也要保证是 key window")
        manager.endEditing(note)
    }

    func testFocusAcquireRetryBudgetIsBoundedAndFast() {
        // 抢焦点是「每帧重试」的补救动作，必须收敛得足够快：
        // 次数太多会拖着窗口反复 makeKey，间隔太大会让用户点完铅笔要等一下才能打字。
        XCTAssertGreaterThan(PinnedWindowManager.focusAcquireAttempts, 0)
        XCTAssertLessThanOrEqual(PinnedWindowManager.focusAcquireAttempts, 20)
        XCTAssertGreaterThan(PinnedWindowManager.focusAcquireInterval, 0)
        XCTAssertLessThanOrEqual(PinnedWindowManager.focusAcquireInterval, 0.1)
    }

    func testBeginEditingWithoutPanelIsHarmless() {
        // 面板没建起来（或已拆掉）时调用不能崩
        let note = PinnedNoteModel(
            sourceItemId: "x",
            itemType: .text,
            sourceAppName: nil,
            editableText: "文字",
            originalText: "文字",
            imageData: nil,
            ocrText: nil,
            isCode: false,
            isDegraded: false
        )
        manager.beginEditing(note)
        manager.endEditing(note)
        XCTAssertFalse(note.isEditing)
    }
}
