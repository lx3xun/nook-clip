import XCTest
@testable import NookClip

@MainActor
final class ClipboardWorkflowTests: XCTestCase {

    final class MockClipboardWriter: ClipboardWriter {
        var copyOnlyCalledWith: (ClipboardItem, Bool)?
        var copyTextCalledWith: (String, Bool)?
        var pasteCalledWith: (ClipboardItem, NSRunningApplication?, Bool)?
        var pasteTextCalledWith: (String, NSRunningApplication?, Bool)?
        var staleFileMessageOverride: ((ClipboardItem) -> String?)?

        func copyOnly(_ item: ClipboardItem, plainTextOnly: Bool) -> Bool {
            copyOnlyCalledWith = (item, plainTextOnly)
            return true
        }

        func copyText(_ text: String, containsSensitive: Bool) -> Bool {
            copyTextCalledWith = (text, containsSensitive)
            return true
        }

        func paste(_ item: ClipboardItem, targetApplication: NSRunningApplication?, plainTextOnly: Bool) -> Bool {
            pasteCalledWith = (item, targetApplication, plainTextOnly)
            return true
        }

        func pasteText(_ text: String, targetApplication: NSRunningApplication?, containsSensitive: Bool) -> Bool {
            pasteTextCalledWith = (text, targetApplication, containsSensitive)
            return true
        }

        func clearClipboardIfContent(matches plainText: String) {}

        func staleFileMessage(for item: ClipboardItem) -> String? {
            staleFileMessageOverride?(item)
        }
    }

    private func makeStore() -> InMemoryHistoryStore {
        let store = makeIsolatedStore()
        store.clearHistory(keepFavorites: false)
        return store
    }

    func testSinglePasteSuccessClosesPanelAndMarksUsed() {
        let store = makeStore()
        let writer = MockClipboardWriter()
        let workflow = ClipboardWorkflow(store: store, clipboardWriter: writer)

        let item = ClipboardItem(type: .text, title: "Test", summary: "Content to paste")
        store.save(item)
        let initialCopyCount = store.item(withID: item.id)?.copyCount ?? 0

        var panelClosed = false
        let outcome = workflow.pasteSingle(
            id: item.id,
            targetApplication: nil,
            plainTextOnly: false,
            closePanel: { panelClosed = true }
        )

        XCTAssertEqual(outcome, .pasted)
        XCTAssertTrue(panelClosed, "粘贴成功后必须回调关闭面板")
        XCTAssertEqual(writer.pasteCalledWith?.0.id, item.id)
        XCTAssertEqual(writer.pasteCalledWith?.2, false)
        XCTAssertEqual(store.item(withID: item.id)?.copyCount, initialCopyCount + 1, "粘贴成功应递增 copyCount")
    }

    func testSinglePasteItemMissing() {
        let store = makeStore()
        let writer = MockClipboardWriter()
        let workflow = ClipboardWorkflow(store: store, clipboardWriter: writer)

        var panelClosed = false
        let outcome = workflow.pasteSingle(
            id: UUID(),
            targetApplication: nil,
            plainTextOnly: false,
            closePanel: { panelClosed = true }
        )

        XCTAssertEqual(outcome, .itemMissing)
        XCTAssertFalse(panelClosed, "条目不存在时不应关闭面板")
        XCTAssertNil(writer.pasteCalledWith)
    }

    func testSinglePasteStaleFileDoesNotClosePanelAndDoesNotMarkUsed() {
        let store = makeStore()
        let writer = MockClipboardWriter()
        let workflow = ClipboardWorkflow(store: store, clipboardWriter: writer)

        let fileItem = ClipboardItem(
            type: .file,
            title: "missing.pdf",
            summary: "/Volumes/External/missing.pdf",
            payloadPath: "/Volumes/External/missing.pdf"
        )
        store.save(fileItem)
        let initialCopyCount = store.item(withID: fileItem.id)?.copyCount ?? 0

        let expectedMsg = "文件已失效：原文件不存在"
        writer.staleFileMessageOverride = { _ in expectedMsg }

        var panelClosed = false
        let outcome = workflow.pasteSingle(
            id: fileItem.id,
            targetApplication: nil,
            plainTextOnly: false,
            closePanel: { panelClosed = true }
        )

        XCTAssertEqual(outcome, .staleFile(message: expectedMsg))
        XCTAssertFalse(panelClosed, "文件失效时不得关闭面板，保留现场提示用户")
        XCTAssertNil(writer.pasteCalledWith, "文件失效时不应触发实际击键粘贴")
        XCTAssertEqual(store.item(withID: fileItem.id)?.copyCount, initialCopyCount, "文件失效不计入使用次数")
    }

    func testBatchPasteCombinesEntriesAndRespectsSensitiveFlag() {
        let store = makeStore()
        let writer = MockClipboardWriter()
        let workflow = ClipboardWorkflow(store: store, clipboardWriter: writer)

        let secret = "sk-proj-batch-paste-secret-token"
        let detection = SensitiveDataDetector.detect(text: secret)!
        let item1 = ClipboardItem(
            type: .text,
            title: "Normal",
            summary: "Line 1"
        )
        let item2 = ClipboardItem(
            type: .text,
            title: "",
            summary: detection.maskedText,
            isSensitive: true,
            encryptedContent: KeychainCryptoService.shared.encrypt(text: secret)
        )
        store.save(item1)
        store.save(item2)

        let entries = [
            ClipboardWorkflow.BatchEntry(id: item1.id, summary: item1.summary, isSensitive: false),
            ClipboardWorkflow.BatchEntry(id: item2.id, summary: item2.summary, isSensitive: true)
        ]

        var panelClosed = false
        let success = workflow.pasteBatch(
            entries: entries,
            targetApplication: nil,
            closePanel: { panelClosed = true }
        )

        XCTAssertTrue(success)
        XCTAssertTrue(panelClosed, "批量粘贴成功应关闭面板")
        XCTAssertNotNil(writer.pasteTextCalledWith)

        let pastedText = writer.pasteTextCalledWith?.0 ?? ""
        let containsSensitive = writer.pasteTextCalledWith?.2 ?? false

        XCTAssertEqual(pastedText, "Line 1\n\(secret)", "文本应按换行连接，敏感项解密还原为明文")
        XCTAssertTrue(containsSensitive, "含敏感项时必须置位 containsSensitive 标志以调度自毁")
        XCTAssertEqual(store.item(withID: item1.id)?.copyCount, 1, "合并粘贴不修改条目的 copyCount")
        XCTAssertEqual(store.item(withID: item2.id)?.copyCount, 1, "合并粘贴不修改条目的 copyCount")
    }

    /// 列表行只载入 summary 前缀（内存优化）后，批量合并粘贴必须仍取全文：
    /// 非敏感条目 revealPlainContent 恒为 nil，此前会落到截断前缀
    func testBatchPasteUsesFullTextForTruncatedListEntry() {
        let store = makeStore()
        let writer = MockClipboardWriter()
        let workflow = ClipboardWorkflow(store: store, clipboardWriter: writer)

        let longText = String(repeating: "批量全文", count: 150) + "结尾标记"
        let item = ClipboardItem(type: .text, title: "", summary: longText)
        store.save(item)

        // 模拟列表行传入的截断前缀
        let truncated = String(longText.prefix(RustHistoryStore.summaryPrefixLimit))
        let entries = [
            ClipboardWorkflow.BatchEntry(id: item.id, summary: truncated, isSensitive: false)
        ]

        XCTAssertTrue(workflow.pasteBatch(entries: entries, targetApplication: nil))
        XCTAssertEqual(writer.pasteTextCalledWith?.0, longText, "批量粘贴必须粘贴全文而非截断前缀")
    }
    /// 合并粘贴不应刷新被合并条目的使用时间，亦不得将其置顶
    func testBatchPasteDoesNotModifyLastUsedAtOrReorderItems() {
        let store = makeStore()
        let writer = MockClipboardWriter()
        let workflow = ClipboardWorkflow(store: store, clipboardWriter: writer)

        let oldDate1 = Date(timeIntervalSince1970: 1000)
        let oldDate2 = Date(timeIntervalSince1970: 2000)
        let newDate3 = Date(timeIntervalSince1970: 3000)

        let item1 = ClipboardItem(type: .text, title: "1", summary: "Old 1", lastUsedAt: oldDate1)
        let item2 = ClipboardItem(type: .text, title: "2", summary: "Old 2", lastUsedAt: oldDate2)
        let item3 = ClipboardItem(type: .text, title: "3", summary: "New 3", lastUsedAt: newDate3)

        store.save(item1)
        store.save(item2)
        store.save(item3)

        // 当前 item3 最前，item2 居中，item1 在后
        XCTAssertEqual(store.items.map(\.id), [item3.id, item2.id, item1.id])

        let success = workflow.pasteBatch(
            entries: [
                .init(id: item1.id, summary: "Old 1", isSensitive: false),
                .init(id: item2.id, summary: "Old 2", isSensitive: false)
            ],
            targetApplication: nil
        )

        XCTAssertTrue(success)
        XCTAssertEqual(store.items.first?.id, item3.id, "最前方的条目不应被合并粘贴的旧条目顶替跑到最前面")
        XCTAssertEqual(store.item(withID: item1.id)?.lastUsedAt.timeIntervalSince1970 ?? 0, oldDate1.timeIntervalSince1970, accuracy: 0.001, "合并粘贴不应改变旧条目的记录时间")
    }
    /// 合并拷贝（⌘C）不应刷新被合并条目的使用时间，亦不得将其置顶
    func testBatchCopyDoesNotModifyLastUsedAtOrReorderItems() {
        let store = makeStore()
        let writer = MockClipboardWriter()
        let workflow = ClipboardWorkflow(store: store, clipboardWriter: writer)

        let oldDate1 = Date(timeIntervalSince1970: 1000)
        let oldDate2 = Date(timeIntervalSince1970: 2000)
        let newDate3 = Date(timeIntervalSince1970: 3000)

        let item1 = ClipboardItem(type: .text, title: "1", summary: "Old 1", lastUsedAt: oldDate1)
        let item2 = ClipboardItem(type: .text, title: "2", summary: "Old 2", lastUsedAt: oldDate2)
        let item3 = ClipboardItem(type: .text, title: "3", summary: "New 3", lastUsedAt: newDate3)

        store.save(item1)
        store.save(item2)
        store.save(item3)

        // 当前 item3 最前，item2 居中，item1 在后
        XCTAssertEqual(store.items.map(\.id), [item3.id, item2.id, item1.id])

        let success = workflow.copyBatch(
            entries: [
                .init(id: item1.id, summary: "Old 1", isSensitive: false),
                .init(id: item2.id, summary: "Old 2", isSensitive: false)
            ]
        )

        XCTAssertTrue(success)
        XCTAssertEqual(store.items.first?.id, item3.id, "最前方的条目不应被合并拷贝的旧条目顶替跑到最前面")
        XCTAssertEqual(store.item(withID: item1.id)?.lastUsedAt.timeIntervalSince1970 ?? 0, oldDate1.timeIntervalSince1970, accuracy: 0.001, "合并拷贝不应改变旧条目的记录时间")
    }


    func testBatchPasteEmptyReturnsFalse() {
        let store = makeStore()
        let writer = MockClipboardWriter()
        let workflow = ClipboardWorkflow(store: store, clipboardWriter: writer)

        var panelClosed = false
        let success = workflow.pasteBatch(
            entries: [],
            targetApplication: nil,
            closePanel: { panelClosed = true }
        )

        XCTAssertFalse(success)
        XCTAssertFalse(panelClosed)
        XCTAssertNil(writer.pasteTextCalledWith)
    }

    func testSingleCopySuccessClosesPanelMarksUsedAndDoesNotPaste() {
        let store = makeStore()
        let writer = MockClipboardWriter()
        let workflow = ClipboardWorkflow(store: store, clipboardWriter: writer)

        let item = ClipboardItem(type: .text, title: "Test", summary: "Content to copy")
        store.save(item)

        var panelClosed = false
        let outcome = workflow.copySingle(
            id: item.id,
            plainTextOnly: false,
            closePanel: { panelClosed = true }
        )

        XCTAssertEqual(outcome, .pasted)
        XCTAssertTrue(panelClosed, "仅拷贝成功后应关闭面板")
        XCTAssertNotNil(writer.copyOnlyCalledWith, "必须调用 copyOnly 写入剪贴板")
        XCTAssertNil(writer.pasteCalledWith, "仅拷贝不应调用前台 paste")
        XCTAssertEqual(store.item(withID: item.id)?.copyCount, 2, "成功拷贝应递增 copyCount")
    }

    func testBatchCopyCombinesEntriesAndDoesNotPaste() {
        let store = makeStore()
        let writer = MockClipboardWriter()
        let workflow = ClipboardWorkflow(store: store, clipboardWriter: writer)

        let item1 = ClipboardItem(type: .text, title: "1", summary: "Line 1")
        let item2 = ClipboardItem(type: .text, title: "2", summary: "Line 2")
        store.save(item1)
        store.save(item2)

        var panelClosed = false
        let success = workflow.copyBatch(
            entries: [
                .init(id: item1.id, summary: "Line 1", isSensitive: false),
                .init(id: item2.id, summary: "Line 2", isSensitive: false)
            ],
            closePanel: { panelClosed = true }
        )

        XCTAssertTrue(success)
        XCTAssertTrue(panelClosed)
        XCTAssertEqual(writer.copyTextCalledWith?.0, "Line 1\nLine 2")
        XCTAssertNil(writer.pasteTextCalledWith, "批量仅拷贝不应调用 pasteText")
    }

    /// 敏感条目解密失败时批量粘贴必须跳过该条（对齐 PasteService.copyOnly
    /// 的拒绝策略）：掩码不得进入剪贴板，被跳过条目不计使用次数
    func testBatchPasteSkipsSensitiveEntryWhenDecryptFails() {
        let store = makeStore()
        let writer = MockClipboardWriter()
        let workflow = ClipboardWorkflow(store: store, clipboardWriter: writer)

        let normal = ClipboardItem(type: .text, title: "N", summary: "Line 1")
        store.save(normal)
        // 损坏密文：revealPlainContent 必然返回 nil（密钥不可用/数据损坏同路径）
        let corrupted = ClipboardItem(
            type: .text, title: "凭证", summary: "sk-••••••••abcd",
            isSensitive: true, encryptedContent: Data([0x01, 0x02, 0x03, 0x04])
        )
        store.items.append(corrupted)
        let corruptedInitialCopyCount = corrupted.copyCount

        var panelClosed = false
        let success = workflow.pasteBatch(
            entries: [
                .init(id: normal.id, summary: "Line 1", isSensitive: false),
                .init(id: corrupted.id, summary: "sk-••••••••abcd", isSensitive: true)
            ],
            targetApplication: nil,
            closePanel: { panelClosed = true }
        )

        XCTAssertTrue(success, "存在可粘贴条目时批量粘贴应执行")
        XCTAssertTrue(panelClosed)
        XCTAssertEqual(writer.pasteTextCalledWith?.0, "Line 1", "解密失败的敏感条目必须被跳过，掩码不得进入合并文本")
        XCTAssertEqual(writer.pasteTextCalledWith?.2, false, "有效条目均非敏感时不得置敏感标记")
        XCTAssertEqual(store.item(withID: corrupted.id)?.copyCount, corruptedInitialCopyCount, "被跳过条目不计使用次数")
    }

    /// 全部条目解密失败时批量粘贴不动作（不关面板、不写剪贴板）
    func testBatchPasteReturnsFalseWhenAllSensitiveEntriesFailToDecrypt() {
        let store = makeStore()
        let writer = MockClipboardWriter()
        let workflow = ClipboardWorkflow(store: store, clipboardWriter: writer)

        let corrupted = ClipboardItem(
            type: .text, title: "凭证", summary: "sk-••••••••abcd",
            isSensitive: true, encryptedContent: Data([0x01, 0x02, 0x03, 0x04])
        )
        store.items.append(corrupted)

        var panelClosed = false
        let success = workflow.pasteBatch(
            entries: [.init(id: corrupted.id, summary: "sk-••••••••abcd", isSensitive: true)],
            targetApplication: nil,
            closePanel: { panelClosed = true }
        )

        XCTAssertFalse(success, "全部条目被跳过时批量粘贴不得执行")
        XCTAssertFalse(panelClosed)
        XCTAssertNil(writer.pasteTextCalledWith)
    }

    /// 批量拷贝同策略：解密失败的敏感条目跳过，不写入剪贴板
    func testBatchCopySkipsSensitiveEntryWhenDecryptFails() {
        let store = makeStore()
        let writer = MockClipboardWriter()
        let workflow = ClipboardWorkflow(store: store, clipboardWriter: writer)

        let normal = ClipboardItem(type: .text, title: "N", summary: "Line 1")
        store.save(normal)
        let corrupted = ClipboardItem(
            type: .text, title: "凭证", summary: "sk-••••••••1234",
            isSensitive: true, encryptedContent: Data([0x05, 0x06])
        )
        store.items.append(corrupted)

        XCTAssertTrue(workflow.copyBatch(entries: [
            .init(id: normal.id, summary: "Line 1", isSensitive: false),
            .init(id: corrupted.id, summary: "sk-••••••••1234", isSensitive: true)
        ]))
        XCTAssertEqual(writer.copyTextCalledWith?.0, "Line 1", "解密失败的敏感条目必须被跳过")
        XCTAssertEqual(writer.copyTextCalledWith?.1, false)
    }

}
