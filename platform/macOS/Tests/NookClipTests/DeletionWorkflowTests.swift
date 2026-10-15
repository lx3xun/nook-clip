import XCTest
@testable import NookClip

@MainActor
final class DeletionWorkflowTests: XCTestCase {

    private func makeStore() -> InMemoryHistoryStore {
        let store = makeIsolatedStore()
        store.clearHistory(keepFavorites: false)
        return store
    }
    private func makeItem(summary: String) -> ClipboardItem {
        ClipboardItem(type: .text, title: summary, summary: summary)
    }

    func testDeleteEntersPendingUndoAndRestoresSuccessfully() {
        let store = makeStore()
        let workflow = DeletionWorkflow(store: store)

        let item1 = makeItem(summary: "first")
        let item2 = makeItem(summary: "second")
        store.save(item1)
        store.save(item2)
        XCTAssertEqual(store.items.count, 2)

        // 1. 删除单条
        workflow.delete([item1.id])
        XCTAssertEqual(store.items.count, 1)
        XCTAssertTrue(store.trashItems.contains(where: { $0.id == item1.id }))
        XCTAssertTrue(workflow.pendingUndoIDs.contains(item1.id))
        XCTAssertTrue(workflow.undoToastDeadline > Date())

        // 2. 撤销删除
        let restored = workflow.undoDelete()
        XCTAssertEqual(restored, [item1.id])
        XCTAssertTrue(workflow.pendingUndoIDs.isEmpty)
        XCTAssertEqual(store.items.count, 2)
        XCTAssertFalse(store.trashItems.contains(where: { $0.id == item1.id }))
    }

    func testMultipleDeletesMergeIntoSingleUndoBatch() {
        let store = makeStore()
        let workflow = DeletionWorkflow(store: store)

        let item1 = makeItem(summary: "one")
        let item2 = makeItem(summary: "two")
        store.save(item1)
        store.save(item2)

        // 第一次删除 item1
        workflow.delete([item1.id])
        XCTAssertEqual(workflow.pendingUndoIDs, [item1.id])

        // 窗口内接着删除 item2（应当合并进同一批撤销）
        workflow.delete([item2.id])
        XCTAssertEqual(workflow.pendingUndoIDs, [item1.id, item2.id])
        XCTAssertEqual(store.items.count, 0)

        // 撤销应整体恢复两个条目
        let restored = workflow.undoDelete()
        XCTAssertEqual(restored, [item1.id, item2.id])
        XCTAssertEqual(store.items.count, 2)
        XCTAssertTrue(workflow.pendingUndoIDs.isEmpty)
    }

    func testUndoWhenEmptyReturnsNil() {
        let store = makeStore()
        let workflow = DeletionWorkflow(store: store)

        XCTAssertNil(workflow.undoDelete())
    }

    func testDeletionWorkflowWorksWithCustomSoftDeletableStore() {
        final class MockNoteStore: SoftDeletableStore {
            var activeIDs: Set<UUID> = []
            var trashedIDs: Set<UUID> = []
            var purgeScheduled = false
            func delete(_ id: UUID) {
                activeIDs.remove(id)
                trashedIDs.insert(id)
            }
            func deleteMultiple(_ ids: Set<UUID>) {
                activeIDs.subtract(ids)
                trashedIDs.formUnion(ids)
            }
            func restoreFromTrash(_ ids: Set<UUID>) {
                trashedIDs.subtract(ids)
                activeIDs.formUnion(ids)
            }
            func scheduleExpiredTrashPurge() {
                purgeScheduled = true
            }
        }
        let noteStore = MockNoteStore()
        let id1 = UUID()
        let id2 = UUID()
        noteStore.activeIDs = [id1, id2]
        let workflow = DeletionWorkflow(store: noteStore)

        workflow.delete([id1, id2])
        XCTAssertTrue(noteStore.activeIDs.isEmpty)
        XCTAssertEqual(noteStore.trashedIDs, [id1, id2])
        XCTAssertEqual(workflow.pendingUndoIDs, [id1, id2])

        let restored = workflow.undoDelete()
        XCTAssertEqual(restored, [id1, id2])
        XCTAssertEqual(noteStore.activeIDs, [id1, id2])
        XCTAssertTrue(noteStore.trashedIDs.isEmpty)
    }
}
