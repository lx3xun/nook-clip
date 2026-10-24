import XCTest
@testable import NookClip

/// 轻量标签（Tag）功能 Swift 层测试 —— 契约 `.tag-feature/CONTRACT.md` §9。
///
/// 覆盖：
/// - `RustHistoryStore.toClipboardItem` 映射 tags
/// - `RustHistoryStore` 的 setTags/addTag/removeTag/listTags/renameTag/deleteTag 包装
/// - `InMemoryHistoryStore` 标签方法写成功返回、dataVersion 递增、镜像条目 tags 同步
/// - tag 过滤（search tag 参数）命中
@MainActor
final class TagFeatureTests: XCTestCase {

    private func makeStore() throws -> RustHistoryStore {
        try RustHistoryStore(path: ":memory:", encryptionKey: Data(repeating: 0x42, count: 32))
    }

    private func makeItem(_ title: String, lastUsed: TimeInterval = 1000) -> ClipboardItem {
        ClipboardItem(
            type: .text,
            title: title,
            summary: "\(title) summary",
            createdAt: Date(timeIntervalSince1970: lastUsed),
            lastUsedAt: Date(timeIntervalSince1970: lastUsed)
        )
    }

    // MARK: - RustHistoryStore 映射与包装

    func testToClipboardItemMapsTags() throws {
        let store = try makeStore()
        let item = makeItem("Tagged Item")
        XCTAssertNotNil(store.save(item, rawText: "body"))

        store.setTags(id: item.id, tags: ["Api", "web"])

        // page 返回的 ClipboardItem 应带 tags
        let paged = store.page(limit: 10, offset: 0)
        let found = try XCTUnwrap(paged.first(where: { $0.id == item.id }))
        XCTAssertEqual(found.tags, ["Api", "web"], "toClipboardItem 必须映射 tags")

        // item(id:) 全文路径也应带 tags
        let single = try XCTUnwrap(store.item(id: item.id))
        XCTAssertEqual(single.tags, ["Api", "web"])
    }

    func testRustStoreTagMutations() throws {
        let store = try makeStore()
        let item = makeItem("Mutate")
        XCTAssertNotNil(store.save(item, rawText: "body"))

        // set
        let afterSet = try XCTUnwrap(store.setTags(id: item.id, tags: ["a", "b"]))
        XCTAssertEqual(afterSet.tags, ["a", "b"])

        // add（已存在大小写不敏感不重复；新标签追加）
        let afterAddDup = try XCTUnwrap(store.addTag(id: item.id, tag: "A"))
        XCTAssertEqual(afterAddDup.tags, ["a", "b"])
        let afterAdd = try XCTUnwrap(store.addTag(id: item.id, tag: "#c"))
        XCTAssertEqual(afterAdd.tags, ["a", "b", "c"])

        // remove（大小写不敏感）
        let afterRemove = try XCTUnwrap(store.removeTag(id: item.id, tag: "B"))
        XCTAssertEqual(afterRemove.tags, ["a", "c"])

        // listTags 统计
        let stats = store.listTags()
        let a = try XCTUnwrap(stats.first(where: { $0.name.caseInsensitiveCompare("a") == .orderedSame }))
        XCTAssertEqual(a.count, 1)
    }

    func testRustStoreRenameAndDeleteTag() throws {
        let store = try makeStore()
        let item1 = makeItem("R1", lastUsed: 1000)
        let item2 = makeItem("R2", lastUsed: 2000)
        XCTAssertNotNil(store.save(item1, rawText: "x"))
        XCTAssertNotNil(store.save(item2, rawText: "y"))
        store.setTags(id: item1.id, tags: ["old", "keep"])
        store.setTags(id: item2.id, tags: ["old", "new"])

        // rename：old → new，合并到已有同名标签
        let affected = store.renameTag(old: "old", new: "new")
        XCTAssertEqual(affected, 2)
        XCTAssertEqual(store.item(id: item1.id)?.tags, ["keep", "new"])
        XCTAssertEqual(store.item(id: item2.id)?.tags, ["new"])

        // delete：解除关联，不删条目
        let deleted = store.deleteTag(name: "new")
        XCTAssertEqual(deleted, 2)
        XCTAssertEqual(store.item(id: item1.id)?.tags, ["keep"])
        XCTAssertEqual(store.item(id: item2.id)?.tags, [])
        XCTAssertNotNil(store.item(id: item1.id), "deleteTag 不应删除条目")
    }

    func testRustStoreSearchByTag() throws {
        let store = try makeStore()
        let item1 = makeItem("Alpha", lastUsed: 1000)
        let item2 = makeItem("Beta", lastUsed: 2000)
        XCTAssertNotNil(store.save(item1, rawText: "x"))
        XCTAssertNotNil(store.save(item2, rawText: "y"))
        store.setTags(id: item1.id, tags: ["api"])
        store.setTags(id: item2.id, tags: ["web"])

        let hits = store.search(query: "", categoryID: 0, limit: 50, offset: 0, tag: "api")
        XCTAssertEqual(hits.map(\.id), [item1.id], "tag 过滤应只命中带该标签的条目")
    }

    // MARK: - InMemoryHistoryStore 标签方法与 dataVersion

    func testInMemoryTagMutationsBumpDataVersion() throws {
        let rustStore = try makeStore()
        let store = makeIsolatedStore(rustStore: rustStore)
        let item = makeItem("Memory")
        XCTAssertNotNil(rustStore.save(item, rawText: "body"))
        store.items = rustStore.page(limit: 100, offset: 0)

        let v0 = store.dataVersion

        // setTags → 成功、dataVersion 递增、镜像条目 tags 同步
        XCTAssertTrue(store.setTags(["api"], for: item.id))
        XCTAssertGreaterThan(store.dataVersion, v0, "setTags 后 dataVersion 必须递增")
        XCTAssertEqual(store.items.first(where: { $0.id == item.id })?.tags, ["api"])

        let v1 = store.dataVersion
        XCTAssertTrue(store.addTag("web", to: item.id))
        XCTAssertGreaterThan(store.dataVersion, v1, "addTag 后 dataVersion 必须递增")
        XCTAssertEqual(store.items.first(where: { $0.id == item.id })?.tags, ["api", "web"])

        let v2 = store.dataVersion
        XCTAssertTrue(store.removeTag("api", from: item.id))
        XCTAssertGreaterThan(store.dataVersion, v2, "removeTag 后 dataVersion 必须递增")
        XCTAssertEqual(store.items.first(where: { $0.id == item.id })?.tags, ["web"])
    }

    func testInMemoryRenameAndDeleteTagBumpDataVersion() throws {
        let rustStore = try makeStore()
        let store = makeIsolatedStore(rustStore: rustStore)
        let item = makeItem("Memory2")
        XCTAssertNotNil(rustStore.save(item, rawText: "body"))
        store.items = rustStore.page(limit: 100, offset: 0)
        store.setTags(["old"], for: item.id)

        let v0 = store.dataVersion
        let affected = store.renameTag(old: "old", new: "renamed")
        XCTAssertEqual(affected, 1)
        XCTAssertGreaterThan(store.dataVersion, v0, "renameTag 后 dataVersion 必须递增")
        XCTAssertEqual(store.items.first(where: { $0.id == item.id })?.tags, ["renamed"])

        let v1 = store.dataVersion
        let deleted = store.deleteTag(name: "renamed")
        XCTAssertEqual(deleted, 1)
        XCTAssertGreaterThan(store.dataVersion, v1, "deleteTag 后 dataVersion 必须递增")
        XCTAssertEqual(store.items.first(where: { $0.id == item.id })?.tags, [])
    }

    func testTagStatsExposed() throws {
        let rustStore = try makeStore()
        let store = makeIsolatedStore(rustStore: rustStore)
        let item = makeItem("Stat")
        XCTAssertNotNil(rustStore.save(item, rawText: "body"))
        store.setTags(["stat"], for: item.id)

        let stats = store.tagStats
        XCTAssertTrue(
            stats.contains(where: { $0.name.caseInsensitiveCompare("stat") == .orderedSame && $0.count == 1 }),
            "tagStats 应包含 stat=1"
        )
    }
}
