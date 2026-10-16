import XCTest
import SwiftUI
@testable import NookClip

@MainActor
final class UIComponentTests: XCTestCase {

    private func renderView<V: View>(_ view: V) -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 120)
        host.layoutSubtreeIfNeeded()
        return host
    }

    // MARK: - SensitiveMaskCard 测试

    func testSensitiveMaskCardStatesAndToggle() {
        var toggleFired = false
        let card = SensitiveMaskCard(
            maskedText: "sk-••••••••7890",
            revealedText: "sk-proj-super-secret-1234",
            isRevealed: false,
            revealFailure: nil,
            onToggle: { toggleFired = true }
        )

        XCTAssertFalse(card.isRevealed)
        XCTAssertEqual(card.maskedText, "sk-••••••••7890")
        XCTAssertNotNil(renderView(card), "遮罩卡片应正常生成视图层级")

        card.onToggle()
        XCTAssertTrue(toggleFired, "点击切换必须触发 onToggle 回调")
    }

    func testSensitiveMaskCardFailureStates() {
        // 1. 钥匙串权限被拒或不可用
        let deniedCard = SensitiveMaskCard(
            maskedText: "sk-••••",
            revealedText: nil,
            isRevealed: false,
            revealFailure: .keyUnavailable,
            onToggle: {}
        )
        XCTAssertEqual(deniedCard.revealFailure, .keyUnavailable)
        XCTAssertNotNil(renderView(deniedCard))

        // 2. 密文损坏无法解密
        let corruptCard = SensitiveMaskCard(
            maskedText: "sk-••••",
            revealedText: nil,
            isRevealed: false,
            revealFailure: .decryptFailed,
            onToggle: {}
        )
        XCTAssertEqual(corruptCard.revealFailure, .decryptFailed)
        XCTAssertNotNil(renderView(corruptCard))
    }

    func testSensitiveMaskCardRevealedState() {
        let revealedCard = SensitiveMaskCard(
            maskedText: "sk-••••",
            revealedText: "sk-proj-full-plaintext",
            isRevealed: true,
            revealFailure: nil,
            onToggle: {}
        )
        XCTAssertTrue(revealedCard.isRevealed)
        XCTAssertEqual(revealedCard.revealedText, "sk-proj-full-plaintext")
        XCTAssertNotNil(renderView(revealedCard))
    }

    // MARK: - BatchBar 测试

    func testBatchBarConfigurationAndCallbacks() {
        var mergeFired = false
        var deleteFired = false

        let bar = BatchBar(
            selectedCount: 5,
            onMergePaste: { mergeFired = true },
            onDelete: { deleteFired = true }
        )

        XCTAssertEqual(bar.selectedCount, 5)
        XCTAssertNotNil(renderView(bar), "底部批量工具栏应正常渲染")

        bar.onMergePaste()
        XCTAssertTrue(mergeFired, "点击合并粘贴按钮必须执行 onMergePaste")

        bar.onDelete()
        XCTAssertTrue(deleteFired, "点击批量删除按钮必须执行 onDelete")
    }

    // MARK: - RowRenameField 测试

    func testRowRenameFieldConstantsAndCreation() {
        XCTAssertEqual(RowRenameField.maxLength, 128, "别名最大长度上限应为 128 字符")

        var committed: String?
        var cancelled = false
        let field = RowRenameField(
            initialText: "Initial Title",
            onCommit: { committed = $0 },
            onCancel: { cancelled = true }
        )

        XCTAssertEqual(field.initialText, "Initial Title")

        field.onCommit("New Title")
        XCTAssertEqual(committed, "New Title")

        field.onCancel()
        XCTAssertTrue(cancelled)
    }

    // MARK: - UndoToast 测试

    func testUndoToastConfigurationAndCallbacks() {
        var undoFired = false
        let toast = UndoToast(
            pendingCount: 3,
            undoDeadline: Date().addingTimeInterval(5),
            onUndo: { undoFired = true }
        )

        XCTAssertEqual(toast.pendingCount, 3)
        XCTAssertNotNil(renderView(toast), "撤销 Toast 胶囊应正常渲染")

        toast.onUndo()
        XCTAssertTrue(undoFired, "点击撤销按钮必须触发 onUndo")
    }

    // MARK: - AccessibilityPermissionBanner 测试

    func testAccessibilityPermissionBannerRendersAndTriggersCallback() {
        var openSettingsFired = false
        let banner = AccessibilityPermissionBanner {
            openSettingsFired = true
        }
        XCTAssertNotNil(renderView(banner), "辅助功能权限引导横幅应正常渲染")
        banner.onOpenSettings()
        XCTAssertTrue(openSettingsFired, "点击打开系统设置按钮必须触发回调")
    }

    // MARK: - ThumbnailPlaceholderView 测试

    func testThumbnailPlaceholderViewRendersImageCategoryIconTile() {
        let normalPlaceholder = ThumbnailPlaceholderView(isSolidSelected: false)
        XCTAssertFalse(normalPlaceholder.isSolidSelected)
        XCTAssertNotNil(renderView(normalPlaceholder), "普通态缩略图占位符应正常生成视图")

        let selectedPlaceholder = ThumbnailPlaceholderView(isSolidSelected: true)
        XCTAssertTrue(selectedPlaceholder.isSolidSelected)
        XCTAssertNotNil(renderView(selectedPlaceholder), "选中态缩略图占位符应正常生成视图")
    }

    func testRowThumbnailViewRendersWithMissingPath() {
        let missingThumbnail = RowThumbnailView(path: "/nonexistent/path/to/missing.png", isSolidSelected: false)
        XCTAssertEqual(missingThumbnail.path, "/nonexistent/path/to/missing.png")
        XCTAssertFalse(missingThumbnail.isSolidSelected)
        XCTAssertNotNil(renderView(missingThumbnail), "图片路径不存在时缩略图行组件应正常生成回退占位视图")
    }

    // MARK: - HintsFooterView 测试

    func testHintsFooterViewRendersWithAndWithoutMoreHints() {
        let hints: [HintsFooterView.Hint] = [
            .init(kbds: ["↑", "↓"], label: "选择"),
            .init(kbds: ["⏎"], label: "粘贴"),
            .init(kbds: ["⌘\u{200A}[", "⌘\u{200A}]"], label: "分类"),
        ]

        let footerView = HintsFooterView(hints: hints)
        XCTAssertEqual(footerView.hints.count, 3)
        XCTAssertTrue(footerView.moreHints.isEmpty)
        XCTAssertNotNil(renderView(footerView), "无额外提示时底栏应正常渲染")

        let moreHints: [HintsFooterView.Hint] = [
            .init(kbds: ["⌘C"], label: "拷贝"),
        ]
        let footerViewWithMore = HintsFooterView(hints: hints, moreHints: moreHints)
        XCTAssertEqual(footerViewWithMore.moreHints.count, 1)
        XCTAssertNotNil(renderView(footerViewWithMore), "带额外提示时底栏应正常渲染")
    }

    // MARK: - NookClipRowShell 通用行容器测试

    func testNookRowShellRendersCustomSlotsIndependentOfClipboardRowModel() {
        let shell = NookClipRowShell(
            isSelected: true,
            style: .batch(isChecked: true, isRemoving: false),
            isFavorite: true,
            timestampText: "刚刚",
            accessibilitySummary: "待办示例、刚刚",
            leading: { _ in Image(systemName: "checkmark.circle") },
            title: { _ in Text("完成周报") },
            titleAccessory: { _ in EmptyView() },
            subtitle: { _ in Text("截止今天 18:00") }
        )
        XCTAssertTrue(shell.isSelected)
        XCTAssertTrue(shell.isFavorite)
        XCTAssertEqual(shell.timestampText, "刚刚")
        XCTAssertNotNil(renderView(shell), "NookClipRowShell 应能独立于 ClipboardRowModel 承载自定义笔记/待办插槽")
    }

    // MARK: - CategoryFilterBar 测试

    func testCategoryFilterBarRendersSlotButtonWithAndWithoutMenu() {
        let chips: [SidebarCategory] = [
            SidebarCategory(id: 0, name: "全部", symbol: "square.grid.2x2", count: 10),
            SidebarCategory(id: 8, name: "收藏", symbol: "star", count: 2),
            SidebarCategory(id: 1, name: "文本", symbol: "doc.text", count: 5),
        ]
        let slot = SidebarCategory(id: 2, name: "链接", symbol: "link", count: 3)

        let barWithMenu = CategoryFilterBar(
            chips: chips,
            slotCategory: slot,
            hasSlotMenu: true,
            selectedID: 0,
            isSlotMenuOpen: false,
            onSelect: { _ in },
            onToggleSlotMenu: {}
        )
        XCTAssertNotNil(renderView(barWithMenu), "带有动态槽下拉菜单的分类筛选条应正常渲染")

        let barWithoutMenu = CategoryFilterBar(
            chips: chips,
            slotCategory: slot,
            hasSlotMenu: false,
            selectedID: 2,
            isSlotMenuOpen: false,
            onSelect: { _ in },
            onToggleSlotMenu: nil
        )
        XCTAssertNotNil(renderView(barWithoutMenu), "选中第 4 槽的分类筛选条应正常渲染")
    }

    // MARK: - GroupHeaderView 下拉菜单测试

    func testGroupHeaderViewRendersDropdownButtonWhenGroupsProvided() {
        let items: [TimelineRailItem] = [
            TimelineRailItem(id: "today", title: "今天", count: 6),
            TimelineRailItem(id: "yesterday", title: "昨天", count: 2),
        ]
        var selectedGroupID: String?
        let header = GroupHeaderView(
            title: "今天",
            count: 6,
            allGroups: items,
            onSelectGroup: { selectedGroupID = $0 }
        )
        XCTAssertEqual(header.allGroups?.count, 2)
        XCTAssertNotNil(renderView(header), "带有 allGroups 的吸顶分组头应始终渲染时间跳转下拉菜单入口")
        header.onSelectGroup?("yesterday")
        XCTAssertEqual(selectedGroupID, "yesterday")
    }

    func testGroupHeaderViewHidesDropdownWhenGroupsNotProvided() {
        let header = GroupHeaderView(
            title: "今天",
            count: 6,
            allGroups: nil,
            onSelectGroup: nil
        )
        XCTAssertNil(header.allGroups)
        XCTAssertNil(header.onSelectGroup)
        XCTAssertNotNil(renderView(header), "不传 allGroups 的吸顶分组头（如 indexRail 模式下）应正常渲染且不含下拉")
    }
}
