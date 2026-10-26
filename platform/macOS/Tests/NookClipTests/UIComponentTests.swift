import XCTest
import SwiftUI
import AppKit
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
    func testSensitiveMaskCardCountdownButtonText() {
        let cardWithCountdown = SensitiveMaskCard(
            maskedText: "sk-••••",
            revealedText: "sk-proj-plaintext",
            isRevealed: true,
            countdownSeconds: 25,
            revealFailure: nil,
            onToggle: {}
        )
        XCTAssertTrue(cardWithCountdown.isRevealed)
        XCTAssertEqual(cardWithCountdown.countdownSeconds, 25)
        XCTAssertNotNil(renderView(cardWithCountdown))
    }

    func testSensitivePreviewCardShowsSummaryWhenAliasIsSet() {
        let itemWithAlias = ClipboardItem(
            type: .text,
            title: "My OpenAI Secret Alias",
            summary: "sk-••••••••7890",
            isSensitive: true
        )
        let row = ClipboardRowModel(item: itemWithAlias)
        XCTAssertEqual(row.displayTitle, "My OpenAI Secret Alias")
        XCTAssertEqual(row.summary, "sk-••••••••7890")

        let maskedText = row.summary.isEmpty ? row.displayTitle : row.summary
        let card = SensitiveMaskCard(
            maskedText: maskedText,
            revealedText: nil,
            isRevealed: false,
            revealFailure: nil,
            onToggle: {}
        )
        XCTAssertEqual(card.maskedText, "sk-••••••••7890", "设置别名后，脱敏卡片仍必须展示脱敏摘要而非别名")
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

    /// 顺序粘贴栈入口（⌥⏎）与标签入口（⌘L）都是可选参数，缺省时不应影响渲染或既有回调
    func testBatchBarOptionalActionsAreWiredWhenProvided() {
        var pasteStackFired = false
        var editTagsFired = false

        let bar = BatchBar(
            selectedCount: 3,
            onMergePaste: {},
            onStartPasteStack: { pasteStackFired = true },
            onDelete: {},
            onEditTags: { editTagsFired = true }
        )

        XCTAssertNotNil(renderView(bar), "带顺序粘贴/标签入口的批量工具栏应正常渲染")

        bar.onStartPasteStack?()
        XCTAssertTrue(pasteStackFired, "点击顺序粘贴按钮必须执行 onStartPasteStack")

        bar.onEditTags?()
        XCTAssertTrue(editTagsFired, "点击标签按钮必须执行 onEditTags")
    }

    /// 工具栏只有 310pt 列宽：四个动作必须全部可辨识，不能退化成「合…」「…」。
    /// 这里锁定「常量布局」——四个动作都常驻文字，宽度只由文字决定，鼠标悬停只改底色
    /// 不改尺寸。一旦有人把文字改成悬停才出现的伸缩按钮，鼠标扫过时整排会动起来。
    func testBatchBarKeepsSinglePrimaryTextButtonForNarrowColumn() {
        let bar = BatchBar(
            selectedCount: 2,
            onMergePaste: {},
            onStartPasteStack: {},
            onDelete: {},
            onEditTags: {}
        )

        XCTAssertNotNil(renderView(bar), "窄列下批量工具栏必须能完整渲染")
        XCTAssertNotNil(bar.onStartPasteStack)
        XCTAssertNotNil(bar.onEditTags)
    }

    /// 布局必须是「常量」的：四个动作的文字常驻，宽度不随鼠标变化。
    /// 之前试过悬停才展开的写法——鼠标扫过工具栏时整排按钮都在伸缩，想点的那个
    /// 会在指针底下换位置。这里锁定：次要按钮自己带文字和悬停状态，不依赖外部展开标志。
    func testBatchBarLayoutIsConstantAndHoverIndependent() {
        var pasteStackFired = false
        var tagFired = false
        var deleteFired = false

        let pasteStack = BatchActionButton(
            title: L10n.tr("batch.paste_stack"),
            shortcut: "⌥⏎",
            role: .primary,
            action: { pasteStackFired = true }
        )
        let tag = BatchActionButton(
            title: L10n.tr("tag.action"),
            shortcut: "⌘L",
            role: .primary,
            action: { tagFired = true }
        )
        let delete = BatchActionButton(
            title: L10n.tr("batch.delete"),
            shortcut: "⌘⌫",
            role: .danger,
            action: { deleteFired = true }
        )

        XCTAssertNotNil(renderView(pasteStack), "顺序粘贴按钮必须可渲染")
        XCTAssertNotNil(renderView(tag), "标签按钮必须可渲染")
        XCTAssertNotNil(renderView(delete), "删除按钮必须可渲染")

        pasteStack.action()
        tag.action()
        delete.action()
        XCTAssertTrue(pasteStackFired, "顺序粘贴按钮必须执行回调")
        XCTAssertTrue(tagFired, "标签按钮必须执行回调")
        XCTAssertTrue(deleteFired, "删除按钮必须执行回调")
    }

    /// 主操作收起成图标（不再有让位场景，但合并箭头仍是唯一的动作图标）
    func testBatchBarMergeIconExists() {
        XCTAssertNotNil(NSImage(systemSymbolName: NookClipIcon.Action.merge, accessibilityDescription: nil),
                        "合并粘贴按钮的箭头图标必须是系统可用的 SF Symbol")
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
            subtitle: { _, _ in Text("截止今天 18:00") }
        )
        XCTAssertTrue(shell.isSelected)
        XCTAssertTrue(shell.isFavorite)
        XCTAssertEqual(shell.timestampText, "刚刚")
        XCTAssertNotNil(renderView(shell), "NookClipRowShell 应能独立于 ClipboardRowModel 承载自定义笔记/待办插槽")
    }

    /// 回归：多选（批量）模式下「当前记录 / 锚点」可能未勾选（取消勾选锚点、↑↓ 导航、
    /// shift 扩选后锚点都会落在未勾选行上）。此时该行必须仍有可见高亮背景，
    /// 不能只剩 1pt 描边。此处构造锚点选中但未勾选的行，确保能正常渲染（背景分支成立）。
    func testNookRowShellBatchAnchorUncheckedStillRendersHighlighted() {
        let anchorUnchecked = NookClipRowShell(
            isSelected: true,
            style: .batch(isChecked: false, isRemoving: false),
            leading: { _ in Image(systemName: "checkmark.circle") },
            title: { _ in Text("当前记录") },
            titleAccessory: { _ in EmptyView() },
            subtitle: { _, _ in Text("未勾选但为预览锚点") }
        )
        XCTAssertTrue(anchorUnchecked.isSelected)
        XCTAssertNotNil(
            renderView(anchorUnchecked),
            "批量模式下未勾选的当前记录行也应有高亮背景（回归：曾仅剩描边、缺少底色）"
        )
    }

    // MARK: - CategoryFilterPanel 测试（搜索框展开面板）

    func testCategoryFilterPanelRendersWithFixedGridAndTags() {
        var picked: (category: Int?, tag: String?) = (nil, nil)
        let categories: [SidebarCategory] = [
            SidebarCategory(id: 8, name: "收藏", symbol: "star.fill", count: 2),
            SidebarCategory(id: 2, name: "图片", symbol: "photo.fill", count: 3),
            SidebarCategory(id: 1, name: "文本", symbol: "doc.text", count: 5),
            SidebarCategory(id: 4, name: "链接", symbol: "globe.americas.fill", count: 1),
            SidebarCategory(id: 5, name: "代码", symbol: "chevron.left.forwardslash.chevron.right", count: 4),
            SidebarCategory(id: 3, name: "文件", symbol: "doc.fill", count: 0),
            SidebarCategory(id: 6, name: "颜色", symbol: "paintpalette.fill", count: 0),
            SidebarCategory(id: 7, name: "回收站", symbol: "trash.fill", count: 0),
        ]
        let tags = [TagStat(name: "灵感", count: 3), TagStat(name: "api", count: 2), TagStat(name: "待办", count: 1)]

        let panel = CategoryFilterPanel(
            categories: categories,
            selectedCategoryID: 2,
            tags: tags,
            selectedTag: "灵感",
            onSelectCategory: { picked.category = $0 },
            onSelectTag: { picked.tag = $0 }
        )
        XCTAssertNotNil(renderView(panel), "带固定类型网格与标签胶囊的过滤面板应正常渲染")
        panel.onSelectCategory(5)
        XCTAssertEqual(picked.category, 5)
        panel.onSelectTag("api")
        XCTAssertEqual(picked.tag, "api")
    }

    func testCategoryFilterPanelRendersWithoutTags() {
        let categories = [SidebarCategory(id: 8, name: "收藏", symbol: "star.fill", count: 0)]
        let panel = CategoryFilterPanel(
            categories: categories,
            selectedCategoryID: 0,
            tags: [],
            selectedTag: nil,
            onSelectCategory: { _ in },
            onSelectTag: { _ in }
        )
        XCTAssertNotNil(renderView(panel), "无标签时下半区隐藏，面板仍应正常渲染（卡片变薄）")
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

    /// 方案 B：标题即入口 —— 有分组数据时整个标题可点；
    /// 视口固定 24pt 高，悬停前不显示 ⌄，因此渲染宽度不应因图标而额外占用。
    func testGroupHeaderTitleEntryRendersWithinFixedHeight() {
        let items: [TimelineRailItem] = [
            TimelineRailItem(id: "today", title: "今天", count: 6),
            TimelineRailItem(id: "yesterday", title: "昨天", count: 2),
        ]
        let header = GroupHeaderView(
            title: "今天",
            count: 6,
            allGroups: items,
            onSelectGroup: { _ in }
        )
        let host = NSHostingView(rootView: header)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        XCTAssertEqual(size.height, NookClip.heightGroupHeader, accuracy: 0.5, "组头高度必须仍是恒定 24pt，点击目标扩到标题不得撑高")
        XCTAssertLessThan(size.width, NookClip.widthListCol, "标题即入口不应把组头撑出列表列宽")
    }

    /// 无分组数据时不注入跳转入口（避免弹出空菜单）
    func testGroupHeaderWithoutGroupsCarriesNoJumpEntry() {
        let plain = GroupHeaderView(title: "今天", count: 6, allGroups: nil, onSelectGroup: nil)
        XCTAssertNil(plain.allGroups)
        XCTAssertNil(plain.onSelectGroup)
        XCTAssertNotNil(renderView(plain))
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
