import XCTest
@testable import NookClip

/// 复制链镜像状态规格（接缝 A：InMemoryHistoryStore 公共 API）。
/// save 增量应用持久化结果（见 SavePathQueryBudgetTests 的查询预算），
/// 这里锁定镜像状态契约：去重合并的真实 id/copyCount/createdAt、页上限与
/// 翻页信号。实现退回「用输入条目而非持久化结果更新镜像」时必红。
@MainActor
final class SavePathMirrorStateTests: XCTestCase {

    func test_reCopySameContentWithDifferentID_keepsOriginalIdentityAndBumpsCopyCount() {
        let store = makeIsolatedStore()
        let originalID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_000)
        store.save(ClipboardItem(
            id: originalID,
            type: .text,
            title: "原始标题",
            summary: "重复内容 needle",
            createdAt: createdAt
        ))

        // 重复捕获：同内容、新 UUID（捕获层每次生成新 id，去重由存储层合并）
        store.save(ClipboardItem(
            id: UUID(),
            type: .text,
            title: "原始标题",
            summary: "重复内容 needle"
        ))

        XCTAssertEqual(store.items.count, 1, "同内容去重合并，不得出现第二行")
        let merged = try! XCTUnwrap(store.items.first)
        XCTAssertEqual(merged.id, originalID, "镜像必须持有去重合并后的原条目 id，而非捕获层新 UUID")
        XCTAssertEqual(merged.copyCount, 2, "重复捕获累计使用次数")
        XCTAssertEqual(merged.createdAt, createdAt, "去重合并保留原条目的创建时间")
    }

    func test_mirrorNeverExceedsPageSize_andSignalsHasMore() {
        let store = makeIsolatedStore()
        let extra = 3
        for i in 0..<(InMemoryHistoryStore.pageSize + extra) {
            store.save(ClipboardItem(
                id: UUID(),
                type: .text,
                title: "条目 \(i)",
                summary: "page-bound needle \(i)"
            ))
        }

        XCTAssertEqual(store.items.count, InMemoryHistoryStore.pageSize, "镜像最多持有一页")
        XCTAssertTrue(store.hasMoreItems, "镜像写满时必须给出还有剩余的翻页信号")
        XCTAssertEqual(store.items.first?.title, "条目 \(InMemoryHistoryStore.pageSize + extra - 1)", "最新条目置顶")

        store.loadMoreItems()
        XCTAssertGreaterThan(store.items.count, InMemoryHistoryStore.pageSize, "翻页信号可用：剩余条目可加载")
    }

    func test_saveFailureLeavesMirrorUntouched() throws {
        // 保存失败（空文本被拒）不得改动镜像
        let store = makeIsolatedStore()
        store.save(ClipboardItem(id: UUID(), type: .text, title: "有效", summary: "valid needle"))
        let before = try XCTUnwrap(store.items.first)

        store.save(ClipboardItem(id: UUID(), type: .text, title: "", summary: ""))

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.id, before.id)
    }
}
