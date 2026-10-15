import XCTest
@testable import NookClip

/// 代码预览跨行选择（NSTextView 改造）的布局不变量：
/// 行片段数 = 行数、每行高 19（行号列对齐依据）、文本存储可跨行取词
@MainActor
final class SelectableCodeTextTests: XCTestCase {
    @MainActor
    private func makeTextView(_ code: String) -> NSTextView {
        let textView = NSTextView()
        textView.textContainerInset = NSSize(width: 26, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textStorage?.setAttributedString(
            SyntaxHighlighter.attributedText(code.components(separatedBy: "\n"))
        )
        return textView
    }

    @MainActor
    func testLineFragmentCountAndHeightMatchLines() {
        let code = "func a() {\n\n    return 1\n}\nlet x = 2"  // 含空行
        let textView = makeTextView(code)
        let layoutManager = textView.layoutManager!
        let container = textView.textContainer!
        layoutManager.ensureLayout(for: container)

        let lineCount = code.components(separatedBy: "\n").count
        XCTAssertEqual(layoutManager.numberOfGlyphs > 0, true)

        // 每个行起始字符映射到一个行片段，片段高恰为 19（行号对齐不变量）
        var lineStarts: [Int] = [0]
        let storage = code as NSString
        for index in 0..<storage.length where storage.character(at: index) == 0x0A {
            lineStarts.append(index + 1)
        }
        XCTAssertEqual(lineStarts.count, lineCount)
        for start in lineStarts {
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: start)
            let rect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            XCTAssertEqual(rect.height, 19, accuracy: 0.5, "行高应为 19：起始字符 \(start)")
        }
    }

    @MainActor
    func testCrossLineSelectionString() {
        let code = "let a = 1\nlet b = 2\nlet c = 3"
        let textView = makeTextView(code)
        // 全选（⌘A 等价）：复制结果是完整代码，不含行号
        textView.selectAll(nil)
        XCTAssertEqual(textView.string, code)
        // 跨两行的部分选择：从第 1 行中部到第 2 行中部
        textView.selectedRange = NSRange(location: 4, length: 10)
        let selected = (textView.string as NSString).substring(with: textView.selectedRange)
        XCTAssertTrue(selected.contains("\n"), "跨行选择应包含换行")
        XCTAssertEqual(selected, "a = 1\nlet ")
    }

    @MainActor
    func testEmptyLinesKeepRowHeight() {
        let textView = makeTextView("\n\n")
        let layoutManager = textView.layoutManager!
        let container = textView.textContainer!
        layoutManager.ensureLayout(for: container)
        // 3 个空行：前 2 行由换行字形承载，末尾空行由额外行片段承载，
        // 总高度 3×19=57（行号列与文本不错位）
        var fragmentCount = 0
        var glyphIndex = 0
        while glyphIndex < layoutManager.numberOfGlyphs {
            var glyphRange = NSRange(location: glyphIndex, length: 0)
            _ = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &glyphRange)
            fragmentCount += 1
            glyphIndex = NSMaxRange(glyphRange)
        }
        if layoutManager.extraLineFragmentTextContainer != nil {
            fragmentCount += 1
        }
        XCTAssertEqual(fragmentCount, 3)
        XCTAssertEqual(layoutManager.usedRect(for: container).height, 57, accuracy: 0.5)
        // 空行不产生占位字符：复制结果不含多余空格
        XCTAssertEqual(textView.string, "\n\n")
    }

    func testAttributedTextLineCount() {
        let attributed = SyntaxHighlighter.attributedText(["a", "b", "c"])
        XCTAssertEqual(attributed.string, "a\nb\nc")
        XCTAssertEqual(attributed.length, 5)
    }

    @MainActor
    func testGutterOverlayDrawsWithoutCrash() {
        // 覆盖层枚举行片段绘制行号（无窗口离屏上下文，验证不崩溃且逻辑可达）
        let textView = makeTextView("let a = 1\nlet b = 2")
        let gutter = CodeGutterOverlayView(frame: NSRect(x: 0, y: 0, width: 26, height: 100))
        gutter.textView = textView
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 26, pixelsHigh: 100,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        gutter.draw(NSRect(x: 0, y: 0, width: 26, height: 100))
        NSGraphicsContext.restoreGraphicsState()
    }

    @MainActor
    func testCodeScrollContainerHorizontalScrollView() {
        let textView = makeTextView(String(repeating: "let longLine = 123456789; ", count: 20))
        let container = CodeScrollContainer(textView: textView)
        container.frame = NSRect(x: 0, y: 0, width: 300, height: 100)
        container.layout()

        XCTAssertTrue(container.scrollView.hasHorizontalScroller, "超宽代码应启用横向滚动条")
        XCTAssertFalse(container.scrollView.autohidesScrollers, "超宽代码横向滚动条应常驻展示供用户操作")
        XCTAssertFalse(container.scrollView.hasVerticalScroller, "不应占用纵向滚动条")
        XCTAssertEqual(container.gutter.frame.width, 26, "左侧行号宽度应保持 26")
        XCTAssertEqual(container.scrollView.frame.origin.x, 26, "代码滚动视图应位于行号列右侧")
        XCTAssertGreaterThan(container.textView.frame.width, 300, "代码视图宽度应自适应超长单行")
    }

    @MainActor
    func testGutterWidensForThreeDigitLineNumbers() {
        // ≥100 行时三位数行号超出固定 16pt 行号宽，右对齐起笔为负会被裁掉，
        // 行号列应按位数加宽；≤99 行保持 26pt 布局不变
        let wide = CodeScrollContainer(
            textView: makeTextView((1...120).map { "line \($0)" }.joined(separator: "\n"))
        )
        wide.lineCount = 120
        wide.frame = NSRect(x: 0, y: 0, width: 300, height: 100)
        wide.layout()
        XCTAssertGreaterThan(wide.gutter.frame.width, 26, "≥100 行时行号列应加宽容纳三位数行号")
        XCTAssertEqual(wide.scrollView.frame.origin.x, wide.gutter.frame.width, "代码区应紧跟加宽后的行号列")

        // 三位数行号在加宽后的列内起笔非负（不被左缘裁切）
        let attributes = CodeTypography.baseAttributes
        let numberWidth = ("120" as NSString).size(withAttributes: attributes).width
        XCTAssertGreaterThanOrEqual(
            wide.gutter.frame.width - 10, numberWidth,
            "加宽后的行号列应容纳三位数行号完整绘制"
        )

        let narrow = CodeScrollContainer(textView: makeTextView("let a = 1\nlet b = 2"))
        narrow.frame = NSRect(x: 0, y: 0, width: 300, height: 100)
        narrow.layout()
        XCTAssertEqual(narrow.gutter.frame.width, 26, "≤99 行时行号列宽度应保持 26")
        XCTAssertEqual(narrow.scrollView.frame.origin.x, 26)
    }

    @MainActor
    private func makeMouseEvent(_ type: NSEvent.EventType, at location: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        )!
    }

    @MainActor
    func testHoverHighlightsRowAtMousePosition() {
        // 需要真实窗口：事件点为窗口基坐标（左下原点），
        // 容器翻转后视图 y = 高度 - 窗口 y，行号 = 视图 y / 19
        let container = CodeScrollContainer(textView: makeTextView("a\nb\nc\nd"))
        container.lineCount = 4
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 90),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        container.frame = NSRect(x: 0, y: 0, width: 300, height: 90)
        container.layout()
        defer { window.contentView = nil }

        // 窗口 y=45 → 视图 y=45 → 第 3 行（0 起第 2 行）
        container.mouseMoved(with: makeMouseEvent(.mouseMoved, at: NSPoint(x: 100, y: 45)))
        XCTAssertEqual(container.lineHighlight.highlightRow, 2, "视图 y=45 应高亮第 3 行")

        // 指针落在最后一行下方的滚动条留白区（视图 y=80）应清除高亮
        container.mouseMoved(with: makeMouseEvent(.mouseMoved, at: NSPoint(x: 100, y: 10)))
        XCTAssertNil(container.lineHighlight.highlightRow, "超出最后一行的位置不应有高亮")

        // 离开视图应清除高亮（mouseExited 事件类型无法离线构造，借 moved 事件触发处理逻辑）
        container.mouseMoved(with: makeMouseEvent(.mouseMoved, at: NSPoint(x: 100, y: 45)))
        container.mouseExited(with: makeMouseEvent(.mouseMoved, at: NSPoint(x: 100, y: 45)))
        XCTAssertNil(container.lineHighlight.highlightRow, "鼠标离开应清除整行高亮")

        // 文本变化（行数变化）后残留高亮应被清除
        container.mouseMoved(with: makeMouseEvent(.mouseMoved, at: NSPoint(x: 100, y: 45)))
        container.lineCount = 2
        XCTAssertNil(container.lineHighlight.highlightRow, "行数变化后残留高亮应清除")
    }
    @MainActor
    func testCodeLineAndGutterVerticalCentering() {
        let code = "let a = 1\nlet b = 2\nlet c = 3"
        let textView = makeTextView(code)
        let layoutManager = textView.layoutManager!
        let container = textView.textContainer!
        layoutManager.ensureLayout(for: container)

        // 验证每行基线均经过 CodeTypography.baselineOffset 提升
        let loc = layoutManager.location(forGlyphAt: 0)
        XCTAssertEqual(loc.y, 15.0, accuracy: 0.1, "基线经 baselineOffset(1.0) 提升后应为 15.0pt，使文本在 19pt 行高内严格垂直居中")

        // 验证行号绘制基准点 y 与行片段矩形 fragmentRect.minY 严格对齐
        let rect0 = layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        XCTAssertEqual(rect0.minY, 0.0)
    }

    @MainActor
    func testCodeScrollViewVerticalWheelDoesNotDriftHorizontally() {
        let textView = makeTextView(String(repeating: "package com.example.demo.order; ", count: 20))
        let container = CodeScrollContainer(textView: textView)
        container.frame = NSRect(x: 0, y: 0, width: 300, height: 100)
        container.layout()

        let scrollView = container.scrollView
        XCTAssertEqual(scrollView.documentVisibleRect.minX, 0)

        // 模拟普通鼠标滚轮向下滚动（纯纵向滚轮）：代码横向位置应保持 0，绝不向左漂移
        let cgDown = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0)!
        let eventDown = NSEvent(cgEvent: cgDown)!
        scrollView.scrollWheel(with: eventDown)

        XCTAssertEqual(scrollView.documentVisibleRect.minX, 0, "普通鼠标滚轮上下滚动不应导致代码内容横向漂移")

        // 模拟按住 Shift 滚轮（明确的横向滚动意图）：应正常横向平移
        let cgShift = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0)!
        cgShift.flags = .maskShift
        let eventShift = NSEvent(cgEvent: cgShift)!
        scrollView.scrollWheel(with: eventShift)

        XCTAssertGreaterThan(scrollView.documentVisibleRect.minX, 0, "按住 Shift 滚轮应正常横向平移代码")
    }

    @MainActor
    func testSelectableCodeTextViewMouseDraggedAutoScrolls() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let scrollView = CodeScrollView(frame: NSRect(x: 26, y: 0, width: 274, height: 100))
        scrollView.hasHorizontalScroller = true
        let textView = SelectableCodeText.SelectableCodeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 100))
        scrollView.documentView = textView
        container.addSubview(scrollView)

        let win = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = container
        win.makeKeyAndOrderFront(nil)

        XCTAssertEqual(scrollView.documentVisibleRect.minX, 0)

        // 模拟在文本框内拖拽选择并拖出可视区域右侧（x = 295）
        let dragEvent = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: NSPoint(x: 295, y: 50),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: win.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )!
        textView.mouseDragged(with: dragEvent)

        XCTAssertGreaterThan(scrollView.documentVisibleRect.minX, 0, "文本选择向右拖出边界时应自动向右平移滚动")
    }
}
