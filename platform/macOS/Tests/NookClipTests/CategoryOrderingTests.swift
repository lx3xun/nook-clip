import XCTest
@testable import NookClip

// 分类自定义排序（手动序）：解析/序列化/应用/重排纯函数测试。
// 行为约定见 ClipboardRowModel.swift 的 CategoryOrdering：
// 「全部」恒居首位不参与重排；序对全部 id 生效（隐藏分类保留序位）；
// 默认自动数量序，首次拖拽切入手动序，可重置。

final class CategoryOrderingTests: XCTestCase {

    private func category(_ id: Int, count: Int = 1) -> SidebarCategory {
        SidebarCategory(id: id, name: "c\(id)", symbol: "circle", count: count)
    }

    // MARK: 解析 / 序列化

    func testParseEmptyIsNil() {
        XCTAssertNil(CategoryOrdering.parse(""))
        XCTAssertNil(CategoryOrdering.parse("   "))
    }

    func testParseFiltersInvalidAndDuplicates() {
        // 0（全部）不可重排；99 不存在；重复去重保序
        XCTAssertEqual(CategoryOrdering.parse("0,8,99,8,1,1"), [8, 1])
    }

    func testSerializeRoundTrip() {
        XCTAssertEqual(CategoryOrdering.serialize([8, 1, 5]), "8,1,5")
        // 非法 id 与重复被清洗
        XCTAssertEqual(CategoryOrdering.serialize([0, 8, 8, 99, 2]), "8,2")
        XCTAssertEqual(CategoryOrdering.serialize([]), "")
    }

    // MARK: 生效序（存储序 + 可见序补全 + 默认序兜底）

    func testEffectiveOrderFillsVisibleThenDefault() {
        // 存储序 [5]；可见序 [8,1,2]（数量序）→ 5 在前 + 可见补中 + 其余默认序补尾
        let order = CategoryOrdering.effectiveOrder(stored: [5], visible: [8, 1, 2])
        XCTAssertEqual(order, [5, 8, 1, 2, 3, 4, 6, 7])
    }

    func testEffectiveOrderAutoModeSeedsFromVisible() {
        // 自动序（stored = nil）：可见数量序在前，隐藏类目按默认序补尾——
        // 首次拖拽即从当前可见排列切入手动序
        let order = CategoryOrdering.effectiveOrder(stored: nil, visible: [8, 2, 4])
        XCTAssertEqual(order, [8, 2, 4, 1, 3, 5, 6, 7])
    }

    // MARK: 应用到分类列表

    func testApplyPutsAllFirstAndHiddenKeepPosition() {
        // 手动序 [5,8,1]；可见分类含全部；隐藏中的 2/3 不在列表但序位保留
        let categories = [category(0), category(8), category(5), category(1)]
        let ordered = CategoryOrdering.apply([5, 8, 2, 1, 3], to: categories)
        XCTAssertEqual(ordered.map(\.id), [0, 5, 8, 1])
    }

    func testApplyAppendsUnknownCategories() {
        // 兜底：未收录进序的类目按传入相对序补尾（新 id/防御路径）
        let categories = [category(0), category(9, count: 0), category(8)]
        let ordered = CategoryOrdering.apply([8], to: categories)
        XCTAssertEqual(ordered.map(\.id), [0, 8, 9])
    }

    // MARK: 拖拽重排

    func testReorderMovesDraggingBeforeTarget() {
        // 向下拖：dragging 1 移到 target 5 之前
        XCTAssertEqual(
            CategoryOrdering.reorder([1, 2, 5, 8], dragging: 1, before: 5),
            [2, 1, 5, 8]
        )
        // 向上拖：dragging 8 移到 target 2 之前
        XCTAssertEqual(
            CategoryOrdering.reorder([1, 2, 5, 8], dragging: 8, before: 2),
            [1, 8, 2, 5]
        )
    }

    func testReorderAdjacentBeforeIsNoOp() {
        // 已紧邻其前 → 原样返回（防拖拽悬停时 dropEntered 反复触发的振荡）
        XCTAssertEqual(
            CategoryOrdering.reorder([1, 2, 5, 8], dragging: 1, before: 2),
            [1, 2, 5, 8]
        )
    }

    func testReorderSelfOrMissingIsNoOp() {
        XCTAssertEqual(
            CategoryOrdering.reorder([1, 2, 5], dragging: 1, before: 1),
            [1, 2, 5]
        )
        XCTAssertEqual(
            CategoryOrdering.reorder([1, 2, 5], dragging: 7, before: 2),
            [1, 2, 5]
        )
    }

    // MARK: 选中类目被挤出可见条

    func testSelectionPushedOutOfBar() {
        // 条 = 前 5 位（含「全部」）。选中 m5（条内末位）被拖到条外 → true
        XCTAssertTrue(CategoryOrdering.selectionPushedOutOfBar(
            oldVisible: [0, 1, 2, 3, 4, 5, 6],
            newVisible: [0, 1, 2, 3, 5, 4, 6],
            selected: 4
        ))
        // 选中类目从条内拖入更前 → 仍在条内 → false
        XCTAssertFalse(CategoryOrdering.selectionPushedOutOfBar(
            oldVisible: [0, 1, 2, 3, 4, 5, 6],
            newVisible: [0, 4, 1, 2, 3, 5, 6],
            selected: 4
        ))
        // 原本就在条外的深位选中（下拉点选/Tab 循环）→ 重排后仍在条外 → false
        XCTAssertFalse(CategoryOrdering.selectionPushedOutOfBar(
            oldVisible: [0, 1, 2, 3, 4, 5, 6],
            newVisible: [0, 2, 1, 3, 4, 5, 6],
            selected: 6
        ))
        // 选中「全部」/未选中 → 永不重置
        XCTAssertFalse(CategoryOrdering.selectionPushedOutOfBar(
            oldVisible: [0, 1, 2, 3, 4, 5, 6],
            newVisible: [0, 1, 2, 3, 4, 6, 5],
            selected: 0
        ))
        // 他者插入把选中类目从条内挤到条外 → true
        XCTAssertTrue(CategoryOrdering.selectionPushedOutOfBar(
            oldVisible: [0, 1, 2, 3, 4, 5, 6],
            newVisible: [0, 6, 1, 2, 3, 4, 5],
            selected: 4
        ))
    }

    // MARK: - CategoryBarCoordinator 循环与槽位固定测试

    @MainActor
    func testCycleCategoryPreservesPinnedSlot5InsteadOfJumpingToHighCountCategory() {
        let defaults = UserDefaults(suiteName: "test.category.coordinator.\(UUID().uuidString)")!
        let coordinator = CategoryBarCoordinator(defaults: defaults)

        // 全部(0), 收藏(8), 文本(1, 10条), 图片(2, 2条), 代码(5, 5条)
        // 注意：代码条数 (5) 高于图片 (2)
        let categories = [
            category(0, count: 17),
            category(8, count: 0),
            category(1, count: 10),
            category(2, count: 2),
            category(5, count: 5),
        ]

        // 用户将第 4 槽固定为图片 (2)
        coordinator.slot5PinnedID = 2
        // 1. 固定 chip 为全部(0)、收藏(8)、文本(1)
        XCTAssertEqual(coordinator.fixedCategories(in: categories).map(\.id), [0, 8, 1])

        // 2. 槽位展示项为图片(2)
        XCTAssertEqual(coordinator.slot5Category(in: categories, effective: 0)?.id, 2)
        // 3. 可切换类目中，固定的图片(2)优先排在首位，高于数量更大的代码(5)
        XCTAssertEqual(coordinator.switchableCategories(in: categories).map(\.id), [2, 5])

        // 4. Tab 循环序保持和界面一致：[0, 8, 1, 2, 5]
        XCTAssertEqual(coordinator.orderedCategoryIDs(in: categories), [0, 8, 1, 2, 5])

        // 5. 从文本(1)按 Tab，下一个目标必须是图片(2)，绝不能跳到代码(5)！
        let nextFromText = coordinator.cycledCategory(selection: 1, step: 1, in: categories)
        XCTAssertEqual(nextFromText, 2, "从文本循环切换必须优先进入当前第 4 槽展示的图片分类")

        // 6. 从图片(2)按下一个，目标为代码(5)
        let nextFromImage = coordinator.cycledCategory(selection: 2, step: 1, in: categories)
        XCTAssertEqual(nextFromImage, 5)

        // 7. 从代码(5)按 Tab，循环回全部(0)
        let nextFromCode = coordinator.cycledCategory(selection: 5, step: 1, in: categories)
        XCTAssertEqual(nextFromCode, 0)

        // 8. 从图片(2)按 ⇧Tab，回到文本(1)
        let prevFromImage = coordinator.cycledCategory(selection: 2, step: -1, in: categories)
        XCTAssertEqual(prevFromImage, 1)
    }

}
