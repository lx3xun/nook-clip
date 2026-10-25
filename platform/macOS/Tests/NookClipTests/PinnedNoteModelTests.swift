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

    func testCapacityIsTwelveNotes() {
        XCTAssertEqual(PinnedWindowManager.maxPinnedNotes, 12)
        XCTAssertEqual(manager.isAtCapacity, manager.pinnedCount >= 12)
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
}
