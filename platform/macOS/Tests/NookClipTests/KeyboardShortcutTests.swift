import AppKit
import Carbon.HIToolbox
import XCTest
@testable import NookClip

/// 快捷键全链路测试（Seam：真实面板 + NSEvent 按键注入）。
/// 按键经 DraggablePanel.sendEvent 键盘分发表（contracts C3 全表，
/// AppKit 层单一事实来源），断言落在公共可观察面：注入的 ClipboardWriter
/// 调用、store 状态、面板开合。
/// 列表行序 = lastUsedAt 倒序（新→旧），播种用 minutesAgo 控制行序。
@MainActor
final class KeyboardShortcutTests: XCTestCase {

    // MARK: - 工具

    /// 剪贴板写入出口侦测（不触达系统剪贴板）
    private final class SpyClipboardWriter: ClipboardWriter {
        var pastedItems: [(item: ClipboardItem, plainTextOnly: Bool)] = []
        var pastedTexts: [(text: String, containsSensitive: Bool)] = []
        var copiedItems: [(item: ClipboardItem, plainTextOnly: Bool)] = []
        var copiedTexts: [String] = []

        func copyOnly(_ item: ClipboardItem, plainTextOnly: Bool) -> Bool {
            copiedItems.append((item, plainTextOnly))
            return true
        }

        func copyText(_ text: String, containsSensitive: Bool) -> Bool {
            copiedTexts.append(text)
            return true
        }

        func paste(_ item: ClipboardItem, targetApplication: NSRunningApplication?, plainTextOnly: Bool) -> Bool {
            pastedItems.append((item, plainTextOnly))
            return true
        }

        func pasteText(_ text: String, targetApplication: NSRunningApplication?, containsSensitive: Bool) -> Bool {
            pastedTexts.append((text, containsSensitive))
            return true
        }

        func clearClipboardIfContent(matches plainText: String) {}

        func staleFileMessage(for item: ClipboardItem) -> String? { nil }
    }

    /// 播种条目：summary + 距今分钟数（越大越旧、行序越靠下）+ 是否收藏 + 条目类型
    private struct Seed {
        let summary: String
        let minutesAgo: Double
        var favorite = false
        var type: ClipboardItemType = .text
        /// 覆盖 minutesAgo 的绝对时间（构造跨日分组用）
        var date: Date?

        var item: ClipboardItem {
            ClipboardItem(
                type: type,
                title: "",
                summary: summary,
                lastUsedAt: date ?? Date(timeIntervalSinceNow: -minutesAgo * 60),
                isFavorite: favorite
            )
        }
    }


    private func makeShortcutPanel(
        seeds: [Seed]
    ) -> (controller: QuickPopoverController, panel: DraggablePanel, writer: SpyClipboardWriter, store: InMemoryHistoryStore) {
        let store = makeIsolatedStore()
        for seed in seeds {
            store.save(seed.item)
        }
        let writer = SpyClipboardWriter()
        let controller = QuickPopoverController(
            historyStore: store,
            targetApplicationProvider: { nil },
            clipboardWriter: writer
        )
        controller.toggle()
        guard let panel = controller.panel as? DraggablePanel else {
            fatalError("DraggablePanel 未创建")
        }
        waitForKeyWiring(panel)
        return (controller, panel, writer, store)
    }

    /// 等待 MainView onAppear 完成并在面板上安装键盘动作表
    private func waitForKeyWiring(_ panel: DraggablePanel) {
        waitFor("键盘动作表接线且成为 KeyWindow") { panel.keyActions != nil && panel.hasKeyFocus }
    }

    /// 轮询等待条件成立（每次 50ms，默认 2s 超时后以消息失败）
    private func waitFor(_ message: String, timeout: Double = 2, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if condition() { return }
        }
        XCTFail("等待超时：\(message)")
    }

    /// 把焦点切到搜索框（经 ⌘F 分发路径，并显式断言持焦）
    private func focusSearchField(to panel: DraggablePanel) {
        sendKey(kVK_ANSI_F, "f", modifiers: [.command], to: panel)
        waitFor("搜索框编辑器持焦") {
            (panel.firstResponder as? NSView).map { panel.isSearchFieldEditor($0) } ?? false
        }
    }

    private func sendKey(
        _ keyCode: Int,
        _ chars: String,
        modifiers: NSEvent.ModifierFlags = [],
        to panel: NSPanel
    ) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: chars,
            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(keyCode)
        )!
        if (panel as? DraggablePanel)?.hasKeyFocus == true || panel.isKeyWindow {
            panel.sendEvent(event)
        } else {
            NSApp.sendEvent(event)
        }
        runLoop(0.2)
    }

    private func sendArrow(_ keyCode: Int, modifiers: NSEvent.ModifierFlags = [], to panel: NSPanel) {
        let functionKey: Int
        switch keyCode {
        case kVK_UpArrow: functionKey = NSUpArrowFunctionKey
        case kVK_DownArrow: functionKey = NSDownArrowFunctionKey
        case kVK_LeftArrow: functionKey = NSLeftArrowFunctionKey
        case kVK_RightArrow: functionKey = NSRightArrowFunctionKey
        default: functionKey = 0
        }
        let chars = String(utf16CodeUnits: [unichar(functionKey)], count: 1)
        sendKey(keyCode, chars, modifiers: modifiers, to: panel)
    }

    private func runLoop(_ seconds: Double) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// 标准播种：Charlie（最新，首行）→ Bravo → Alpha（最旧）
    private let standardSeeds = [
        Seed(summary: "Alpha", minutesAgo: 30),
        Seed(summary: "Bravo", minutesAgo: 20),
        Seed(summary: "Charlie", minutesAgo: 10),
    ]

    /// 混合类型播种：行序 Charlie → Bravo → 链接 → Alpha（收藏，最旧末行）。
    /// 分类循环序 = [全部, 收藏, 文本, 链接]，供 Tab/⇧Tab/下拉用例判别
    private let mixedSeeds = [
        Seed(summary: "Alpha", minutesAgo: 40, favorite: true),
        Seed(summary: "https://example.com/nook", minutesAgo: 25, type: .url),
        Seed(summary: "Bravo", minutesAgo: 20),
        Seed(summary: "Charlie", minutesAgo: 10),
    ]

    /// ANSI 字母键码表（输入文本用）
    private let ansiKeyCodes: [Character: Int] = [
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34,
        "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35, "q": 12,
        "r": 15, "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
    ]

    /// 向当前第一响应者逐键输入文本（等待输入防抖 + 异步查询完成）
    private func typeText(_ text: String, to panel: NSPanel) {
        for char in text.lowercased() {
            guard let code = ansiKeyCodes[char] else { continue }
            sendKey(code, String(char), to: panel)
        }
        runLoop(0.4)
    }

    // MARK: - ⏎ 粘贴选中行

    /// ⏎ 粘贴当前选中行（面板打开默认选中首行 = 最新条目）并收起面板
    func testReturnKeyPastesSelectedRowAndClosesPanel() {
        let (controller, panel, writer, _) = makeShortcutPanel(seeds: standardSeeds)
        defer { controller.close() }

        sendKey(kVK_Return, "\r", to: panel)

        XCTAssertEqual(writer.pastedItems.count, 1, "⏎ 应恰好触发一次单条粘贴")
        XCTAssertEqual(writer.pastedItems.first?.item.summary, "Charlie", "⏎ 应粘贴选中行（首行 = 最新条目）")
        XCTAssertEqual(writer.pastedItems.first?.plainTextOnly, false, "无修饰 ⏎ 不是纯文本模式")
        XCTAssertFalse(panel.isVisible, "粘贴成功后应收起面板")
    }

    // MARK: - ↑↓ 移动选中

    /// ↓ 把选中移到第二行，⏎ 粘贴第二行
    func testArrowDownMovesSelectionToSecondRow() {
        let (controller, panel, writer, _) = makeShortcutPanel(seeds: standardSeeds)
        defer { controller.close() }

        sendArrow(kVK_DownArrow, to: panel)
        sendKey(kVK_Return, "\r", to: panel)

        XCTAssertEqual(writer.pastedItems.first?.item.summary, "Bravo", "↓ 后 ⏎ 应粘贴第二行")
    }

    // MARK: - 列表态直接打字即搜索

    /// 锚点态（面板呼出默认态）直接打字：字符应重定向进搜索框触发过滤，
    /// ⏎ 粘贴过滤后的首行（DraggablePanel 打字即搜索重定向）
    func testTypingInListStateRedirectsToSearchAndFilters() {
        let (controller, panel, writer, _) = makeShortcutPanel(seeds: standardSeeds)
        defer { controller.close() }

        typeText("bravo", to: panel)
        sendKey(kVK_Return, "\r", to: panel)

        XCTAssertEqual(writer.pastedItems.count, 1, "打字+⏎ 应恰好触发一次粘贴")
        XCTAssertEqual(writer.pastedItems.first?.item.summary, "Bravo", "列表态打字应聚焦搜索并过滤，⏎ 粘贴过滤后首行")
    }

    /// 首行 ↑ 钳制不越界：仍粘贴首行
    func testArrowUpClampsAtFirstRow() {
        let (controller, panel, writer, _) = makeShortcutPanel(seeds: standardSeeds)
        defer { controller.close() }

        sendArrow(kVK_UpArrow, to: panel)
        sendKey(kVK_Return, "\r", to: panel)

        XCTAssertEqual(writer.pastedItems.first?.item.summary, "Charlie", "首行 ↑ 应钳制，仍粘贴首行")
    }

    /// 当列表位于已加载批次末尾时，按 ↓ 应触发下一页加载，并将选中项推进到新加载出来的条目
    func testArrowDownAtBottomTriggersLoadMoreAndAdvancesSelection() {
        let count = 250
        let seeds = (0..<count).map { i in
            Seed(summary: "Item \(count - 1 - i)", minutesAgo: Double(i + 1))
        }
        let (controller, panel, writer, _) = makeShortcutPanel(seeds: seeds)
        defer { controller.close() }

        // 移至第 100 条（触发加载第二页，使结果达到 200 条）
        panel.keyActions?.arrow(99, false)
        runLoop(0.3)

        // 移至第 200 条（下标 199，第二页末尾）
        panel.keyActions?.arrow(100, false)
        runLoop(0.3)

        // 此时已在已加载的末尾 (下标 199, "Item 50")，按 ↓ 方向键应触发加载下一页并将选中项推进到 "Item 49"
        sendArrow(kVK_DownArrow, to: panel)
        runLoop(0.3)

        sendKey(kVK_Return, "\r", to: panel)
        XCTAssertEqual(writer.pastedItems.first?.item.summary, "Item 49", "在末行按 ↓ 应加载更多并推进选中项到下一页首条 (Item 49)")
    }

    // MARK: - ⇧ 范围勾选与批量合并粘贴

    /// ⇧↓ 范围勾选首两行 → ⏎ 批量合并粘贴（按列表顺序 \n 连接）
    func testShiftDownExtendsSelectionAndReturnPastesBatch() {
        let (controller, panel, writer, _) = makeShortcutPanel(seeds: standardSeeds)
        defer { controller.close() }

        sendArrow(kVK_DownArrow, modifiers: [.shift], to: panel)
        sendKey(kVK_Return, "\r", to: panel)

        XCTAssertEqual(writer.pastedTexts.count, 1, "批量模式 ⏎ 应触发一次合并粘贴")
        XCTAssertEqual(writer.pastedTexts.first?.text, "Charlie\nBravo", "合并文本应按列表显示顺序以 \\n 连接")
        XCTAssertEqual(writer.pastedTexts.first?.containsSensitive, false)
        XCTAssertTrue(writer.pastedItems.isEmpty, "批量模式不应走单条粘贴")
        XCTAssertFalse(panel.isVisible, "批量粘贴成功后应收起面板")
    }
    /// ⇧↓ 范围勾选首两行 → ⌘⏎ 批量合并粘贴但保持面板打开
    func testShiftDownExtendsSelectionAndCommandReturnPastesBatchAndKeepsPanelOpen() {
        let (controller, panel, writer, _) = makeShortcutPanel(seeds: standardSeeds)
        defer { controller.close() }

        sendArrow(kVK_DownArrow, modifiers: [.shift], to: panel)
        sendKey(kVK_Return, "\r", modifiers: [.command], to: panel)

        XCTAssertEqual(writer.pastedTexts.count, 1, "批量模式 ⌘⏎ 应触发一次合并粘贴")
        XCTAssertEqual(writer.pastedTexts.first?.text, "Charlie\nBravo", "合并文本应按列表显示顺序以 \\n 连接")
        XCTAssertTrue(panel.isVisible, "批量模式 ⌘⏎ 保持面板打开")

        // 外部应用激活模拟（如真实粘贴场景）
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            NSWorkspace.shared.notificationCenter.post(
                name: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                userInfo: [NSWorkspace.applicationUserInfoKey: finder]
            )
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            XCTAssertTrue(panel.isVisible, "外部目标应用激活时，批量 ⌘⏎ 仍应保护面板不被关闭")
        }
    }

    /// 批量模式下 ⌘C 合并拷贝（不粘贴）
    func testCommandCInBatchModeCopiesJoinedText() {
        let (controller, panel, writer, _) = makeShortcutPanel(seeds: standardSeeds)
        defer { controller.close() }

        sendArrow(kVK_DownArrow, modifiers: [.shift], to: panel)
        sendKey(kVK_ANSI_C, "c", modifiers: [.command], to: panel)

        XCTAssertEqual(writer.copiedTexts, ["Charlie\nBravo"], "批量 ⌘C 应合并拷贝勾选集")
        XCTAssertTrue(writer.pastedTexts.isEmpty, "⌘C 不应触发前台粘贴")
        XCTAssertFalse(panel.isVisible, "拷贝后应收起面板")
    }

    // MARK: - ⏎ 修饰变体

    /// ⌘⏎ 粘贴但保持面板打开
    func testCommandReturnKeepsPanelOpen() {
        let (controller, panel, writer, _) = makeShortcutPanel(seeds: standardSeeds)
        defer { controller.close() }

        sendKey(kVK_Return, "\r", modifiers: [.command], to: panel)

        XCTAssertEqual(writer.pastedItems.first?.item.summary, "Charlie", "⌘⏎ 应粘贴选中行")
        XCTAssertTrue(panel.isVisible, "⌘⏎ 保持面板打开")

        // 模拟目标应用在前台激活（如真实 PasteService.activateAndPostKeyEvent 行为）
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            NSWorkspace.shared.notificationCenter.post(
                name: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                userInfo: [NSWorkspace.applicationUserInfoKey: finder]
            )
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            XCTAssertTrue(panel.isVisible, "外部目标应用激活时，⌘⏎ 应保护面板不被关闭")
        }
    }

    /// ⌥⏎ 纯文本模式粘贴（富文本内容降级为纯文本）
    func testOptionReturnPastesPlainTextOnly() {
        let (controller, panel, writer, _) = makeShortcutPanel(seeds: standardSeeds)
        defer { controller.close() }

        sendKey(kVK_Return, "\r", modifiers: [.option], to: panel)

        XCTAssertEqual(writer.pastedItems.first?.item.summary, "Charlie")
        XCTAssertEqual(writer.pastedItems.first?.plainTextOnly, true, "⌥⏎ 应以纯文本模式粘贴")
    }

    // MARK: - ⌘C 仅拷贝

    /// ⌘C 写入剪贴板并收起面板，不向前台发送粘贴
    func testCommandCCopiesSelectionAndClosesPanel() {
        let (controller, panel, writer, _) = makeShortcutPanel(seeds: standardSeeds)
        defer { controller.close() }

        sendKey(kVK_ANSI_C, "c", modifiers: [.command], to: panel)

        XCTAssertEqual(writer.copiedItems.count, 1, "⌘C 应恰好拷贝一次")
        XCTAssertEqual(writer.copiedItems.first?.item.summary, "Charlie", "⌘C 应拷贝选中行")
        XCTAssertTrue(writer.pastedItems.isEmpty, "⌘C 不应触发前台粘贴")
        XCTAssertFalse(panel.isVisible, "拷贝后应收起面板")
    }

    // MARK: - ⌘S 收藏

    /// ⌘S 切换选中行收藏态
    func testCommandSTogglesFavoriteOnSelectedRow() {
        let (controller, panel, writer, store) = makeShortcutPanel(seeds: standardSeeds)
        defer { controller.close() }

        sendKey(kVK_ANSI_S, "s", modifiers: [.command], to: panel)

        XCTAssertEqual(store.items.first(where: { $0.summary == "Charlie" })?.isFavorite, true,
                       "⌘S 应收藏选中行")
        XCTAssertTrue(writer.pastedItems.isEmpty && writer.copiedItems.isEmpty, "⌘S 不应触发粘贴/拷贝")
        XCTAssertTrue(panel.isVisible, "⌘S 不应收起面板")
    }

    // MARK: - ⌘⌫ 删除与 ⌘Z 撤销

    /// ⌘⌫ 软删除选中行（进入撤销窗口，不关面板），选中补位到下一条
    func testCommandDeleteSoftDeletesSelectedRowAndMovesSelectionToSuccessor() {
        let (controller, panel, writer, store) = makeShortcutPanel(seeds: standardSeeds)
        defer { controller.close() }

        sendKey(kVK_Delete, "\u{8}", modifiers: [.command], to: panel)

        XCTAssertNil(store.items.first(where: { $0.summary == "Charlie" }), "⌘⌫ 应软删除选中行")
        XCTAssertEqual(store.trashItems.first?.summary, "Charlie", "删除项应进入撤销窗口")
        XCTAssertTrue(panel.isVisible, "删除不应收起面板")

        // 删除后选中补位项 = 原位置下一条（Bravo），⏎ 应粘贴 Bravo
        sendKey(kVK_Return, "\r", to: panel)
        XCTAssertEqual(writer.pastedItems.first?.item.summary, "Bravo", "删除后选中应补位到下一条")
    }

    /// ⌘⌦（前向删除键，外接键盘 Del / 笔记本 Fn+⌫）与 ⌘⌫ 同义软删除
    func testCommandForwardDeleteSoftDeletesSelectedRow() {
        let (controller, panel, _, store) = makeShortcutPanel(seeds: standardSeeds)
        defer { controller.close() }

        sendKey(kVK_ForwardDelete, "\u{7f}", modifiers: [.command], to: panel)

        XCTAssertNil(store.items.first(where: { $0.summary == "Charlie" }), "⌘⌦ 应软删除选中行")
        XCTAssertEqual(store.trashItems.first?.summary, "Charlie", "删除项应进入撤销窗口")
        XCTAssertTrue(panel.isVisible, "删除不应收起面板")
    }

    /// ⌘Z 撤销最近一次删除：条目回到列表
    func testCommandZUndoesLastDelete() {
        let (controller, panel, _, store) = makeShortcutPanel(seeds: standardSeeds)
        defer { controller.close() }

        sendKey(kVK_Delete, "\u{8}", modifiers: [.command], to: panel)
        XCTAssertNil(store.items.first(where: { $0.summary == "Charlie" }), "前置：⌘⌫ 已删除")

        sendKey(kVK_ANSI_Z, "z", modifiers: [.command], to: panel)

        XCTAssertEqual(store.items.first(where: { $0.summary == "Charlie" })?.summary, "Charlie",
                       "⌘Z 应恢复最近删除的条目")
    }

    // MARK: - Esc 分层清空

    /// 无可清空内容时 Esc 收起面板
    func testEscapeClosesPanelWhenNothingToClear() {
        let (controller, panel, _, _) = makeShortcutPanel(seeds: standardSeeds)
        defer { controller.close() }

        sendKey(kVK_Escape, "\u{1b}", to: panel)

        XCTAssertFalse(panel.isVisible, "无搜索词/分类/菜单时 Esc 应收起面板")
    }

    /// Esc 先清搜索词再考虑收起：清空后面板保持打开、列表恢复
    func testEscapeClearsSearchTextBeforeClosing() {
        let (controller, panel, writer, _) = makeShortcutPanel(seeds: standardSeeds)
        defer { controller.close() }

        focusSearchField(to: panel)
        typeText("zzz", to: panel)
        sendKey(kVK_Escape, "\u{1b}", to: panel)

        XCTAssertTrue(panel.isVisible, "Esc 清空搜索词后不应收起面板")

        sendKey(kVK_Return, "\r", to: panel)
        XCTAssertEqual(writer.pastedItems.first?.item.summary, "Charlie", "搜索词清空后列表应恢复")
    }

    /// Esc 清分类筛选回「全部」（分类非全部时 Esc 不收起面板）
    func testEscapeClearsCategoryFilter() {
        let (controller, panel, writer, _) = makeShortcutPanel(seeds: mixedSeeds)
        defer { controller.close() }

        sendKey(kVK_ANSI_RightBracket, "]", modifiers: [.command], to: panel)
        sendKey(kVK_Escape, "\u{1b}", to: panel)

        XCTAssertTrue(panel.isVisible, "Esc 清分类后不应收起面板")

        sendKey(kVK_Return, "\r", to: panel)
        XCTAssertEqual(writer.pastedItems.first?.item.summary, "Charlie", "Esc 后分类应回到「全部」")
    }

    /// Esc 关闭分类下拉但不改筛选（下拉开着时 Esc 不清分类、不收面板）
    func testEscapeClosesCategoryMenuWithoutClearingFilter() {
        let (controller, panel, writer, _) = makeShortcutPanel(seeds: mixedSeeds)
        defer { controller.close() }

        sendKey(kVK_DownArrow, "\u{F701}", modifiers: [.command], to: panel)
        sendKey(kVK_Escape, "\u{1b}", to: panel)

        XCTAssertTrue(panel.isVisible, "Esc 关闭下拉时不应收起面板")

        sendKey(kVK_Return, "\r", to: panel)
        XCTAssertEqual(writer.pastedItems.first?.item.summary, "Charlie", "关闭下拉不应改变分类筛选")
    }

    // MARK: - ⌘F 聚焦搜索框

    /// ⌘F 把焦点切到搜索框：随后输入进入搜索框并过滤列表
    func testCommandFFocusesSearchField() {
        let (controller, panel, writer, _) = makeShortcutPanel(seeds: standardSeeds)
        defer { controller.close() }

        sendKey(kVK_ANSI_F, "f", modifiers: [.command], to: panel)
        waitFor("搜索框编辑器持焦") {
            (panel.firstResponder as? NSView).map { panel.isSearchFieldEditor($0) } ?? false
        }
        typeText("bravo", to: panel)
        sendKey(kVK_Return, "\r", to: panel)

        XCTAssertEqual(writer.pastedItems.first?.item.summary, "Bravo", "⌘F 后输入应过滤列表并 ⏎ 粘贴命中行")
    }
    // MARK: - ⌘[ / ⌘] 分类循环

    /// ⌘] 从「全部」循环到下一分类（收藏），选中回落该分类首行
    func testCommandRightBracketCyclesToNextCategory() {
        let (controller, panel, writer, _) = makeShortcutPanel(seeds: mixedSeeds)
        defer { controller.close() }

        sendKey(kVK_ANSI_RightBracket, "]", modifiers: [.command], to: panel)
        sendKey(kVK_Return, "\r", to: panel)

        XCTAssertEqual(writer.pastedItems.first?.item.summary, "Alpha", "⌘] 应切到收藏分类并选中收藏行")
    }

    /// ⌘[ 从「全部」反向循环到末位分类（链接）
    func testCommandLeftBracketCyclesToPreviousCategory() {
        let (controller, panel, writer, _) = makeShortcutPanel(seeds: mixedSeeds)
        defer { controller.close() }

        sendKey(kVK_ANSI_LeftBracket, "[", modifiers: [.command], to: panel)
        sendKey(kVK_Return, "\r", to: panel)

        XCTAssertEqual(writer.pastedItems.first?.item.summary, "https://example.com/nook",
                       "⌘[ 应反向切到链接分类")
    }

    /// 搜索框持焦时 ⌘] 仍可循环分类（不冲突文本输入与光标）
    func testCommandBracketWhileSearchFocusedStillCyclesCategory() {
        let (controller, panel, writer, _) = makeShortcutPanel(seeds: mixedSeeds)
        defer { controller.close() }

        focusSearchField(to: panel)
        sendKey(kVK_ANSI_RightBracket, "]", modifiers: [.command], to: panel)
        sendKey(kVK_Return, "\r", to: panel)

        XCTAssertEqual(writer.pastedItems.first?.item.summary, "Alpha", "搜索框持焦时 ⌘] 应切到收藏分类")
    }

    /// ⌥→ 不再循环分类（交还系统/光标跳词，保持在「全部」首行）
    func testOptionArrowDoesNotCycleCategory() {
        let (controller, panel, writer, _) = makeShortcutPanel(seeds: mixedSeeds)
        defer { controller.close() }

        sendArrow(kVK_RightArrow, modifiers: [.option], to: panel)
        sendKey(kVK_Return, "\r", to: panel)

        XCTAssertEqual(writer.pastedItems.first?.item.summary, "Charlie", "⌥→ 不应再循环分类，应保持首行选中")
    }

    // MARK: - ⌘↓ 分类下拉

    /// ⌘↓ 打开分类下拉（高亮首项 = 收藏），⏎ 选中该分类
    func testCommandDownOpensCategoryMenuAndReturnSelectsHighlightedCategory() {
        let (controller, panel, writer, _) = makeShortcutPanel(seeds: mixedSeeds)
        defer { controller.close() }

        sendKey(kVK_DownArrow, "\u{F701}", modifiers: [.command], to: panel)
        sendKey(kVK_Return, "\r", to: panel)
        sendKey(kVK_Return, "\r", to: panel)

        XCTAssertEqual(writer.pastedItems.first?.item.summary, "Alpha", "⌘↓ + ⏎ 应选中下拉首项（收藏）")
    }

    /// 下拉内 ↓↓ 移动高亮到链接分类，⏎ 选中
    func testArrowKeysNavigateCategoryMenuHighlight() {
        let (controller, panel, writer, _) = makeShortcutPanel(seeds: mixedSeeds)
        defer { controller.close() }

        sendKey(kVK_DownArrow, "\u{F701}", modifiers: [.command], to: panel)
        sendArrow(kVK_DownArrow, to: panel)
        sendArrow(kVK_DownArrow, to: panel)
        sendKey(kVK_Return, "\r", to: panel)
        sendKey(kVK_Return, "\r", to: panel)

        XCTAssertEqual(writer.pastedItems.first?.item.summary, "https://example.com/nook",
                       "下拉内 ↓↓ 应把高亮移到链接分类")
    }

    // MARK: - ⌘R 重命名与编辑态守卫

    /// ⌘R 进入行内重命名：输入新别名 ⏎ 提交落库
    func testCommandRBeginsRenameAndReturnCommitsTitle() {
        let (controller, panel, _, store) = makeShortcutPanel(seeds: standardSeeds)
        defer { controller.close() }

        sendKey(kVK_ANSI_R, "r", modifiers: [.command], to: panel)
        waitFor("重命名输入框成为第一响应者") { panel.firstResponder is NSTextView }

        typeText("renamed", to: panel)
        sendKey(kVK_Return, "\r", to: panel)

        XCTAssertEqual(store.items.first(where: { $0.summary == "Charlie" })?.title, "renamed",
                       "⌘R + 输入 + ⏎ 应提交别名")
    }

    /// 重命名编辑态守卫：⌘⌫ 不删除、⌘S 不收藏、Esc 放弃修改并退出编辑态
    func testRenameModeGuardsListShortcuts() {
        let (controller, panel, _, store) = makeShortcutPanel(seeds: standardSeeds)
        defer { controller.close() }

        sendKey(kVK_ANSI_R, "r", modifiers: [.command], to: panel)
        waitFor("重命名输入框成为第一响应者") { panel.firstResponder is NSTextView }

        // 编辑态 ⌘⌫ 是文本编辑语义（删除到行首），不得删除选中条目
        sendKey(kVK_Delete, "\u{8}", modifiers: [.command], to: panel)
        XCTAssertNotNil(store.items.first(where: { $0.summary == "Charlie" }), "编辑态 ⌘⌫ 不应删除条目")

        // 编辑态 ⌘S 不触发收藏
        sendKey(kVK_ANSI_S, "s", modifiers: [.command], to: panel)
        XCTAssertEqual(store.items.first(where: { $0.summary == "Charlie" })?.isFavorite, false,
                       "编辑态 ⌘S 不应收藏")

        // Esc 放弃修改：条目保留、未提交输入、面板不关
        sendKey(kVK_Escape, "\u{1b}", to: panel)
        XCTAssertTrue(panel.isVisible, "编辑态 Esc 应交给输入框放弃修改，不收起面板")
        XCTAssertEqual(store.items.first(where: { $0.summary == "Charlie" })?.title, "",
                       "Esc 放弃修改不应提交别名")

        // 退出编辑态后 ⌘⌫ 恢复删除语义
        sendKey(kVK_Delete, "\u{8}", modifiers: [.command], to: panel)
        XCTAssertNil(store.items.first(where: { $0.summary == "Charlie" }), "退出编辑态后 ⌘⌫ 应恢复删除")
    }

    // MARK: - ⌘T 时间分组循环定位

    /// 跨日播种：今天 [Charlie]，昨天 [Bravo, Alpha]（组内按时间降序）
    private let crossDaySeeds: [Seed] = {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date())!
        func at(_ hour: Int, _ minute: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: yesterday)!
        }
        return [
            Seed(summary: "Alpha", minutesAgo: 0, date: at(11, 0)),
            Seed(summary: "Bravo", minutesAgo: 0, date: at(12, 0)),
            Seed(summary: "Charlie", minutesAgo: 0, date: Date()),
        ]
    }()

    /// ⌘T 循环到昨天分组后，选中应落到昨天组首行（而非停留在今天）
    func testCommandTMovesSelectionToAnchoredGroupFirstRow() {
        let (controller, panel, writer, _) = makeShortcutPanel(seeds: crossDaySeeds)
        defer { controller.close() }

        // 全部 → 今天 → 昨天
        sendKey(kVK_ANSI_T, "t", modifiers: [.command], to: panel)
        sendKey(kVK_ANSI_T, "t", modifiers: [.command], to: panel)
        sendKey(kVK_Return, "\r", to: panel)

        XCTAssertEqual(writer.pastedItems.first?.item.summary, "Bravo",
                       "⌘T 定位到昨天后，选中应落在昨天组首行")
    }

    /// ⌘T 定位到昨天后按 ↓：从昨天组首行在组内移动，不得仍从今天的旧选中行起算
    func testArrowAfterCommandTStaysInAnchoredGroup() {
        let (controller, panel, writer, _) = makeShortcutPanel(seeds: crossDaySeeds)
        defer { controller.close() }

        sendKey(kVK_ANSI_T, "t", modifiers: [.command], to: panel)
        sendKey(kVK_ANSI_T, "t", modifiers: [.command], to: panel)
        sendArrow(kVK_DownArrow, to: panel)
        sendKey(kVK_Return, "\r", to: panel)

        XCTAssertEqual(writer.pastedItems.first?.item.summary, "Alpha",
                       "⌘T 定位后 ↓ 应从昨天组首行起算（粘贴昨天组第二行）")
    }

    /// ⌘T 末组后复位回「全部」：选中回落列表首行
    func testCommandTWrapToAllResetsSelectionToFirstRow() {
        let (controller, panel, writer, _) = makeShortcutPanel(seeds: crossDaySeeds)
        defer { controller.close() }

        // 今天 → 昨天 → 复位全部
        sendKey(kVK_ANSI_T, "t", modifiers: [.command], to: panel)
        sendKey(kVK_ANSI_T, "t", modifiers: [.command], to: panel)
        sendKey(kVK_ANSI_T, "t", modifiers: [.command], to: panel)
        sendKey(kVK_Return, "\r", to: panel)

        XCTAssertEqual(writer.pastedItems.first?.item.summary, "Charlie",
                       "⌘T 末组复位后选中应回落列表首行")
    }

    // MARK: - 面板 key 状态与键盘主循环

    /// 面板失去 key window 状态后键盘主循环整体失灵（键盘事件只派发给 key
    /// window；LSUIElement 应用 NSMenu 关闭后 key 状态可能不回归——组头
    /// 时间下拉切换后 ↑/↓/⏎ 全无响应的用户反馈根因）。
    /// restoreKeyboardFocus 夺回 key 后应复活
    func testPanelKeyboardRevivesAfterKeyReclaim() {
        let (controller, panel, writer, _) = makeShortcutPanel(seeds: standardSeeds)
        defer { controller.close() }

        // 抢走 key 状态，模拟菜单关闭后面板非 key 态
        let thief = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        panel.resignKey()
        thief.makeKeyAndOrderFront(nil)
        runLoop(0.3)
        XCTAssertFalse(panel.hasKeyFocus, "抢 key 后面板应处于非 key 态")
        // 非 key 态：⏎ 粘贴失灵（onKeyPress 收不到事件）
        sendKey(kVK_Return, "\r", to: panel)
        runLoop(0.2)
        XCTAssertTrue(writer.pastedItems.isEmpty, "面板非 key 时 ⏎ 不应触发粘贴")

        // 夺回 key + 重立锚点焦点：键盘主循环恢复
        panel.restoreKeyboardFocus()
        runLoop(0.5)
        XCTAssertTrue(panel.hasKeyFocus, "恢复后面板应重新持有 key 状态")
        sendKey(kVK_Return, "\r", to: panel)
        runLoop(0.2)
        XCTAssertEqual(writer.pastedItems.count, 1, "恢复后 ⏎ 应正常粘贴选中行")
        XCTAssertEqual(writer.pastedItems.first?.item.summary, "Charlie")

        thief.orderOut(nil)
    }
    // MARK: - 搜索态快捷键互斥与 CapsLock 验证

    /// 搜索框持焦时，⌘C/⌘⌫/⌘R 放行给文本编辑器，不触发列表条目的复制/删除/重命名
    func testSearchFieldFocusedYieldsCommandShortcutsToTextEditor() {
        let (controller, panel, writer, store) = makeShortcutPanel(seeds: standardSeeds)
        defer { controller.close() }

        focusSearchField(to: panel)

        // 1. 搜索态按 ⌘C：不应触发列表条目粘贴/拷贝
        sendKey(kVK_ANSI_C, "c", modifiers: [.command], to: panel)
        XCTAssertTrue(writer.copiedItems.isEmpty, "搜索框持焦时 ⌘C 不应复制列表条目")

        // 2. 搜索态按 ⌘⌫：不应删除历史记录
        let originalCount = store.totalCount
        sendKey(kVK_Delete, "\u{7f}", modifiers: [.command], to: panel)
        XCTAssertEqual(store.totalCount, originalCount, "搜索框持焦时 ⌘⌫ 不应删除历史条目")
    }

    /// Caps Lock 锁定下，修饰键过滤仍能匹配快捷键（⌘] 循环）
    func testCapsLockDoesNotBreakCommandBracketShortcuts() {
        let (controller, panel, writer, _) = makeShortcutPanel(seeds: mixedSeeds)
        defer { controller.close() }

        // 模拟 Caps Lock 开启状态下的 ⌘]
        sendKey(kVK_ANSI_RightBracket, "]", modifiers: [.command, .capsLock], to: panel)
        sendKey(kVK_Return, "\r", to: panel)
        XCTAssertEqual(writer.pastedItems.first?.item.summary, "Alpha", "CapsLock 开启时 ⌘] 应正常生效")
    }
}
