import AppKit
import XCTest
import SwiftUI
@testable import NookClip

final class PreviewCopyShortcutFocusTests: XCTestCase {
    @MainActor
    private func makeControllerWithItems() -> (QuickPopoverController, DraggablePanel) {
        // 预览态是 @AppStorage 全局持久值：其他测试（或被中断的进程）残留的
        // showsPreview=false 会折叠预览列，令本组焦点测试找不到文本视图。
        // 显式快照并强制展开，teardown 恢复原值。
        let snapshot = UserDefaults.standard.object(forKey: "showsPreview")
        UserDefaults.standard.set(true, forKey: "showsPreview")
        addTeardownBlock {
            if let snapshot {
                UserDefaults.standard.set(snapshot, forKey: "showsPreview")
            } else {
                UserDefaults.standard.removeObject(forKey: "showsPreview")
            }
        }
        let store = makeIsolatedStore()
        // 存储多条内容
        store.save(ClipboardItem(type: .text, title: "Item 1", summary: "First summary text in preview"))
        store.save(ClipboardItem(type: .text, title: "Item 2", summary: "Second summary text in preview"))

        let controller = QuickPopoverController(
            historyStore: store,
            targetApplicationProvider: { nil },
            clipboardWriter: PasteService.shared
        )
        controller.toggle()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        guard let panel = controller.panel as? DraggablePanel else {
            fatalError("DraggablePanel not created")
        }
        return (controller, panel)
    }

    /// 切面 2：PreviewDataProvider.copyText 执行后须触发 restoreKeyboardFocus 通知
    @MainActor
    func testPreviewDataProviderCopyTextPostsRestoreFocusNotification() {
        withPasteboardLock {
            let systemBefore = NSPasteboard.general.string(forType: .string)
            let provider = PreviewDataProvider(fileStore: .shared, clipboardWriter: PasteService.shared)
            var received = false
            let observer = NotificationCenter.default.addObserver(
                forName: .restoreKeyboardFocus,
                object: nil,
                queue: nil
            ) { _ in
                received = true
            }
            defer { NotificationCenter.default.removeObserver(observer) }

            let success = provider.copyText("sample path or color")
            XCTAssertTrue(success, "copyText 应当成功")
            XCTAssertTrue(received, "copyText 成功后应当发出 restoreKeyboardFocus 通知归还焦点")
            XCTAssertEqual(PasteboardAccess.general.string(forType: .string), "sample path or color")
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), systemBefore, "预览复制不得污染系统剪贴板")
        }
    }
    /// 切面 3：JSONPreviewCard 的内容分段与复制行为验证
    @MainActor
    func testJSONPreviewCardContentSegments() {
        let rawJSON = "{\"name\":\"NookClip\",\"active\":true}"
        let detection = LanguageClassifier.detect(text: rawJSON)
        XCTAssertTrue(detection.isJSON)
        XCTAssertNotNil(detection.formattedJSON)
        XCTAssertNotNil(detection.minifiedJSON)

        withPasteboardLock {
            let systemBefore = NSPasteboard.general.string(forType: .string)
            let provider = PreviewDataProvider.live

            // 验证格式化复制
            XCTAssertTrue(provider.copyText(detection.formattedJSON!))
            XCTAssertEqual(PasteboardAccess.general.string(forType: .string), detection.formattedJSON)

            // 验证压缩复制
            XCTAssertTrue(provider.copyText(detection.minifiedJSON!))
            XCTAssertEqual(PasteboardAccess.general.string(forType: .string), detection.minifiedJSON)

            // 验证原文复制
            XCTAssertTrue(provider.copyText(rawJSON))
            XCTAssertEqual(PasteboardAccess.general.string(forType: .string), rawJSON)

            XCTAssertEqual(NSPasteboard.general.string(forType: .string), systemBefore)
        }
    }


    /// 切面 1：在预览区选中文字并执行 ⌘C 后，第一响应者不应停留在预览文本视图，且 ↓ 方向键应能正常导航列表
    @MainActor
    private func findTextInteractionView(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if String(describing: type(of: view)).contains("TextInteraction") { return view }
        for subview in view.subviews {
            if let found = findTextInteractionView(in: subview) { return found }
        }
        return nil
    }

    @MainActor
    private func simulateSelection(on view: NSView, in panel: NSPanel) {
        let midPoint = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let mouseDown = NSEvent.mouseEvent(
            with: .leftMouseDown, location: midPoint, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1.0
        )!
        panel.sendEvent(mouseDown)
        let mouseUp = NSEvent.mouseEvent(
            with: .leftMouseUp, location: NSPoint(x: midPoint.x + 20, y: midPoint.y), modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0.0
        )!
        panel.sendEvent(mouseUp)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }

    @MainActor
    private func sendKey(keyCode: UInt16, chars: String, modifiers: NSEvent.ModifierFlags = [], to panel: NSPanel) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: chars,
            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode
        )!
        panel.sendEvent(event)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    @MainActor
    func testPlainTextPreviewCopyRestoresKeyAnchorFocus() {
        withPasteboardLock {
            let (controller, panel) = makeControllerWithItems()
            defer { controller.close() }
            guard let textInteractionView = findTextInteractionView(in: panel.contentView) else {
                return XCTFail("未在预览区域找到文本选择交互视图")
            }

            panel.makeFirstResponder(textInteractionView)
            simulateSelection(on: textInteractionView, in: panel)
            XCTAssertTrue(panel.firstResponder === textInteractionView, "划选后交互视图应为第一响应者")

            // ⌘C 复制
            sendKey(keyCode: 8, chars: "c", modifiers: [.command], to: panel)
            XCTAssertFalse(panel.firstResponder === textInteractionView, "⌘C 复制后第一响应者应当脱离预览文本视图")

            // 按下 ↓ 方向键
            let downArrowChars = String(utf16CodeUnits: [unichar(NSDownArrowFunctionKey)], count: 1)
            sendKey(keyCode: 125, chars: downArrowChars, to: panel)
            XCTAssertFalse(panel.firstResponder === textInteractionView, "按下 ↓ 方向键后焦点不应被预览文本视图截留")
        }
    }

    /// 切面 3：预览区只读文本（isEditable == false）与可编辑编辑器（isEditable == true）判定分离，
    /// 保证未来笔记/待办编辑器持焦时不会被 restoreKeyboardFocus 强行夺走焦点
    @MainActor
    func testPreviewEditableTextResponderIsDistinguishedFromReadOnlySelectableText() {
        let (controller, panel) = makeControllerWithItems()
        defer { controller.close() }
        guard let contentView = panel.contentView else {
            return XCTFail("panel.contentView 不存在")
        }

        // 放入独立容器视图后再挂入窗口 contentView，避免 NSHostingView addSubview 警告
        let container = NSView(frame: contentView.bounds)
        let editorFrame = NSRect(x: NookClip.widthListCol + 40, y: 200, width: 200, height: 100)
        let textView = NSTextView(frame: editorFrame)
        container.addSubview(textView)
        panel.contentView = container
        defer { panel.contentView = contentView }

        // 1. 只读态（当前剪贴板预览语义）：属于 previewSelectable，不属于 previewEditable
        textView.isEditable = false
        textView.isSelectable = true
        XCTAssertTrue(panel.isPreviewSelectableTextResponder(textView))
        XCTAssertFalse(panel.isPreviewEditableTextResponder(textView))

        // 2. 可编辑态（未来笔记/待办编辑器语义）：属于 previewEditable，不属于只读 previewSelectable，
        // 且 restoreKeyboardFocus 不会剥夺其第一响应者地位
        textView.isEditable = true
        panel.makeFirstResponder(textView)
        XCTAssertTrue(panel.isPreviewEditableTextResponder(textView))
        XCTAssertFalse(panel.isPreviewSelectableTextResponder(textView))

        panel.restoreKeyboardFocus()
        XCTAssertTrue(panel.firstResponder === textView, "右栏可编辑编辑器持焦时 restoreKeyboardFocus 不得夺走焦点")
    }

    @MainActor
    func testCodePreviewCopyRestoresKeyAnchorFocus() {
        withPasteboardLock {
            let systemBefore = NSPasteboard.general.string(forType: .string)
            let store = makeIsolatedStore()
            store.clearHistory(keepFavorites: false)
            var meta = ClipboardMetadata()
            meta.language = "swift"
            store.save(ClipboardItem(type: .text, title: "Code 1", summary: "let firstCode = 1", metadata: meta))
            store.save(ClipboardItem(type: .text, title: "Code 2", summary: "let secondCode = 2", metadata: meta))

            let controller = QuickPopoverController(
                historyStore: store,
                targetApplicationProvider: { nil },
                clipboardWriter: PasteService.shared
            )
            controller.toggle()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            defer { controller.close() }

            guard let panel = controller.panel as? DraggablePanel else {
                return XCTFail("DraggablePanel not created")
            }

            @MainActor func findTextViews(in view: NSView) -> [NSTextView] {
                var result: [NSTextView] = []
                if let match = view as? NSTextView { result.append(match) }
                for sub in view.subviews { result.append(contentsOf: findTextViews(in: sub)) }
                return result
            }

            let textViews = findTextViews(in: panel.contentView!)
            guard let textView = textViews.first else {
                return XCTFail("未在代码预览区域找到 NSTextView")
            }

            panel.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: 0, length: 3))
            XCTAssertTrue(panel.firstResponder === textView, "代码文本视图应已获取焦点")

            // 模拟 ⌘C 复制
            sendKey(keyCode: 8, chars: "c", modifiers: [.command], to: panel)
            XCTAssertFalse(panel.firstResponder === textView, "代码预览 ⌘C 复制后第一响应者应当脱离代码文本视图")

            // 模拟右键菜单复制 copy(_:)
            panel.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: 0, length: 3))
            XCTAssertTrue(panel.firstResponder === textView)
            textView.copy(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))

            // 验证复制内容写入隔离剪贴板，且绝不污染系统全局剪贴板
            XCTAssertEqual(PasteboardAccess.general.string(forType: .string), "let")
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), systemBefore, "代码预览复制不得污染系统剪贴板")

            // 模拟再次按下 ↓ 方向键，确认焦点脱离文本视图
            let downArrowChars = String(utf16CodeUnits: [unichar(NSDownArrowFunctionKey)], count: 1)
            sendKey(keyCode: 125, chars: downArrowChars, to: panel)
            XCTAssertFalse(panel.firstResponder === textView, "按下 ↓ 方向键后焦点不应停留在代码文本视图")
        }
    }
}
