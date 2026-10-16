import XCTest
@testable import NookClip

/// 代码高亮衔接层（CodeHighlightService → NSTextView 管线）的行为不变量：
/// 字体/行高契约（行号列对齐依据）、语言检测、缓存命中、空文本回退
@MainActor
final class CodeHighlightServiceTests: XCTestCase {
    private let swiftCode = """
        import Foundation

        func greet(_ name: String) -> String {
            // 问好
            return "Hello, \\(name)!"
        }
        """

    func testSwiftDetectionAndFontContract() async {
        let outcome = await CodeHighlightService.outcome(for: swiftCode, forcedLanguage: nil, dark: false)

        XCTAssertNotNil(outcome, "合法 Swift 代码应产出高亮结果")
        XCTAssertEqual(outcome?.languageName, "Swift")

        // 字体/行高契约：全区间等宽 12pt (Design System 2.0 Code-12) + 固定行高 19（行号列逐像素对齐依据）
        let attributed = outcome!.attributed
        let full = NSRange(location: 0, length: attributed.length)
        XCTAssertGreaterThan(attributed.length, 0)
        attributed.enumerateAttribute(.font, in: full) { value, _, stop in
            guard let font = value as? NSFont else {
                XCTFail("存在未设置字体的区间"); stop.pointee = true; return
            }
            XCTAssertEqual(font.fontName, CodeTypography.codeFont.fontName)
            XCTAssertEqual(font.pointSize, CodeTypography.codeFont.pointSize)
        }
        attributed.enumerateAttribute(.paragraphStyle, in: full) { value, _, stop in
            guard let style = value as? NSParagraphStyle else {
                XCTFail("存在未设置段落样式的区间"); stop.pointee = true; return
            }
            XCTAssertEqual(style.minimumLineHeight, 19)
        }
        // HTML 导入不应残留默认前景色（暗色下不可见）；至少存在一个着色 token
        var hasColor = false
        attributed.enumerateAttribute(.foregroundColor, in: full) { value, _, _ in
            if value as? NSColor != nil { hasColor = true }
        }
        XCTAssertTrue(hasColor, "高亮结果应带前景色")
    }

    func testCacheReturnsIdenticalInstance() async {
        let first = await CodeHighlightService.outcome(for: swiftCode, forcedLanguage: nil, dark: true)
        let second = await CodeHighlightService.outcome(for: swiftCode, forcedLanguage: nil, dark: true)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertTrue(
            first?.attributed === second?.attributed,
            "同 key 二次调用应命中 LRU 缓存返回同一 NSAttributedString 实例"
        )
        // 明暗是不同 key：各自缓存，互不串色
        let light = await CodeHighlightService.outcome(for: swiftCode, forcedLanguage: nil, dark: false)
        XCTAssertNotNil(light)
        XCTAssertTrue(light?.attributed !== first?.attributed)
    }

    func testForcedJSONLanguage() async {
        let outcome = await CodeHighlightService.outcome(
            for: "{\"name\": \"NookClip\", \"count\": 3}", forcedLanguage: "json", dark: false
        )
        XCTAssertNotNil(outcome)
        XCTAssertEqual(outcome?.languageName, "JSON")
    }

    func testBlankTextFallsBackToPlaceholder() async {
        let outcome = await CodeHighlightService.outcome(for: "  \n\t\n", forcedLanguage: nil, dark: false)
        XCTAssertNil(outcome, "纯空白文本不应产出高亮结果（走占位渲染）")
    }

    func testPreservesOriginalWhitespaceAndNewlineStructure() async {
        let code = "package com.example.demo;\n\npublic class OrderService {\n    let a = 1\n}\n"
        let outcome = await CodeHighlightService.outcome(for: code, forcedLanguage: nil, dark: false)
        XCTAssertNotNil(outcome)
        XCTAssertEqual(outcome?.attributed.string, code, "高亮产物应严格保持原文换行与首尾空白结构，避免与真实行号及行数统计脱节")
        XCTAssertEqual(outcome?.attributed.string.components(separatedBy: "\n").count, code.components(separatedBy: "\n").count)
    }

    func testPreservesLeadingIndentationWhenFirstTokenIsSpan() async {
        // 回归：首行含前导缩进且首个字符即进入 <span>（如 Markdown 缩进代码块或带前导缩进的注释/代码），
        // 原生 Span 解析器不应发生首行缩进丢失或双倍缩进
        let markdownIndented = "    code block line 1\n    code block line 2\n"
        let mdOutcome = await CodeHighlightService.outcome(for: markdownIndented, forcedLanguage: "markdown", dark: false)
        XCTAssertNotNil(mdOutcome)
        XCTAssertEqual(mdOutcome?.attributed.string, markdownIndented)

        let indentedSwift = "    // 缩进注释\n    let value = \"<tag> & 'quote'\"\n"
        let swiftOutcome = await CodeHighlightService.outcome(for: indentedSwift, forcedLanguage: "swift", dark: true)
        XCTAssertNotNil(swiftOutcome)
        XCTAssertEqual(swiftOutcome?.attributed.string, indentedSwift)
    }

    func testLanguageAliasesAndCodeSentinelFallback() async {
        // 1. "code" 哨兵值应走自动检测而非当作字面语言名失败退出
        let autoFromCodeSentinel = await CodeHighlightService.outcome(for: swiftCode, forcedLanguage: "code", dark: false)
        XCTAssertNotNil(autoFromCodeSentinel, "forcedLanguage == \"code\" 应回退自动检测并成功高亮")
        XCTAssertEqual(autoFromCodeSentinel?.languageName, "Swift")

        // 2. "shell" 应映射至 "bash" 语法，使得无 $ 提示符的普通脚本正常着色
        let shellScript = "set -e\nfor f in *.txt; do\n  echo \"Processing $f\"\ndone"
        let shellOutcome = await CodeHighlightService.outcome(for: shellScript, forcedLanguage: "shell", dark: true)
        XCTAssertNotNil(shellOutcome)
        XCTAssertEqual(shellOutcome?.languageName, "Shell")

        // 3. "vue" / "groovy" 等扩展语言应正常映射并保留准确胶囊展示名
        let vueSFC = "<template>\n  <div>{{ msg }}</div>\n</template>\n<script>\nexport default {}\n</script>"
        let vueOutcome = await CodeHighlightService.outcome(for: vueSFC, forcedLanguage: "vue", dark: false)
        XCTAssertNotNil(vueOutcome)
        XCTAssertEqual(vueOutcome?.languageName, "Vue")

        let groovyCode = "def list = ['a', 'b']\nprintln list.join(',')"
        let groovyOutcome = await CodeHighlightService.outcome(for: groovyCode, forcedLanguage: "groovy", dark: false)
        XCTAssertNotNil(groovyOutcome)
        XCTAssertEqual(groovyOutcome?.languageName, "Groovy")
    }

    func testSynchronousCachedOutcomeAndNormalizedLines() async {
        let sample = "let x = 42\nprint(x)"
        _ = await CodeHighlightService.outcome(for: sample, forcedLanguage: "swift", dark: false)
        let syncHit = CodeHighlightService.cachedOutcome(for: sample, forcedLanguage: "swift", dark: false)
        XCTAssertNotNil(syncHit, "高亮完成后同步缓存查询应直接命中，供视图首帧零闪烁渲染")
        XCTAssertEqual(syncHit?.languageName, "Swift")

        // CRLF 换行规范化：防止行尾残留 \r 破坏行号统计
        let crlf = "line1\r\nline2\rline3\n"
        XCTAssertEqual(CodePreviewCard.normalizedLines(crlf), ["line1", "line2", "line3", ""])
    }
}
