import AppKit
import SwiftUI
// MARK: - 按行简单语法着色（关键字/字符串/数字/注释 · NookClip.code* 令牌）

/// 代码排版常量（非隔离命名空间，003 警告清理）：NSFont / NSParagraphStyle /
/// CGFloat 均为不可变值，行号列探宽等非隔离上下文可直接读取。
enum CodeTypography {
    /// 固定行高 19pt：与行号列逐像素对齐（同旧 .frame(height: 19)）
    static let lineHeight: CGFloat = 19
    /// 代码字体（Design System 2.0 `Code-12`：12pt SF Mono，消除 11.5pt 半像素字号）
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    /// 基线提升 1.0pt：使 12pt 代码文本与行号在 19pt 固定行高内精确居中（消除顶部留白过大、底边贴底问题）
    static let baselineOffset: CGFloat = 1.0
    /// 固定行高段落样式（minimum + maximum 双锁 19pt，行号列绘制同源，逐像素对齐）
    static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        return style
    }()
    /// 统一文本基础属性：包含字体、固定行高段落样式与垂直居中基线偏移
    static var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: codeFont,
            .paragraphStyle: paragraphStyle,
            .baselineOffset: baselineOffset,
        ]
    }
}

@MainActor
enum SyntaxHighlighter {
    enum Kind {
        case text, keyword, string, number, comment
    }

    private static let keywords: Set<String> = [
        "func", "fn", "fun", "let", "var", "val", "mut", "pub", "impl", "trait",
        "use", "mod", "crate", "match", "where", "type", "interface", "import",
        "package", "return", "if", "elif", "else", "for", "while", "loop",
        "switch", "case", "break", "continue", "class", "struct", "enum",
        "protocol", "extension", "public", "private", "protected", "internal",
        "static", "const", "final", "override", "init", "self", "this", "super",
        "def", "lambda", "pass", "raise", "except", "with", "yield", "None",
        "null", "nil", "nullptr", "true", "false", "True", "False", "try",
        "catch", "throw", "throws", "async", "await", "guard", "defer", "not",
        "and", "or", "in", "new", "delete", "update", "select", "insert",
        "into", "from", "create", "table", "join", "echo", "export", "chmod",
        "print", "println", "local", "then", "end", "do", "done", "fi",
    ]

    /// 单行 → 着色 NSAttributedString（NSTextView 代码文本用）。
    /// 着色结果按行内容 memoize（主线程调用；容量上限防长会话膨胀）：
    /// 预览切换/滚动会反复渲染同一批行，正则分词是代码卡的主要
    /// CPU 开销之一，命中缓存直接返回已构造的结果
    private static var attributedMemo: [String: NSAttributedString] = [:]
    private static let memoCap = 8192

    static func attributedLine(_ line: String) -> NSAttributedString {
        if let cached = attributedMemo[line] { return cached }
        let result = NSMutableAttributedString()
        let base = CodeTypography.baseAttributes
        for (text, kind) in tokens(line) {
            var attributes = base
            attributes[.foregroundColor] = nsColor(kind)
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        // 空行不加占位字符：行高由段落样式 minimumLineHeight 保证，
        // 占位空格会污染选择/复制结果
        if attributedMemo.count < memoCap {
            attributedMemo[line] = result
        }
        return result
    }

    /// 整段代码 → 可跨行选择的 NSAttributedString（行间以 \n 连接，
    /// 行号由文本视图自绘、不入存储，复制结果只有代码本身）
    static func attributedText(_ lines: [String]) -> NSAttributedString {
        let joined = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { joined.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: CodeTypography.paragraphStyle])) }
            joined.append(attributedLine(line))
        }
        return joined
    }

    private static func nsColor(_ kind: Kind) -> NSColor {
        switch kind {
        case .text: NookClip.nsCodeText
        case .keyword: NookClip.nsCodeKeyword
        case .string: NookClip.nsCodeString
        case .number: NookClip.nsCodeNumber
        case .comment: NookClip.nsCodeComment
        }
    }

    private static func tokens(_ line: String) -> [(String, Kind)] {
        var result: [(String, Kind)] = []
        var current = ""
        var index = line.startIndex

        func flush() {
            if !current.isEmpty {
                result.append((current, .text))
                current = ""
            }
        }

        while index < line.endIndex {
            let character = line[index]

            // 行注释（// … 或 SQL -- … 或 Python/Shell/YAML # …，排除 #[ / #include / #import / #define / #if / #pragma 与 6 位色值）
            if character == "/",
               line.index(after: index) < line.endIndex,
               line[line.index(after: index)] == "/" {
                flush()
                result.append((String(line[index...]), .comment))
                return result
            }
            if character == "-",
               line.index(after: index) < line.endIndex,
               line[line.index(after: index)] == "-",
               (index == line.startIndex || line[line.index(before: index)].isWhitespace) {
                let afterDash = line.index(index, offsetBy: 2)
                if afterDash == line.endIndex || line[afterDash].isWhitespace {
                    flush()
                    result.append((String(line[index...]), .comment))
                    return result
                }
            }
            if character == "#",
               (index == line.startIndex || line[line.index(before: index)].isWhitespace) {
                let rest = line[line.index(after: index)...]
                let isPreprocessorOrAttr = rest.hasPrefix("[")
                    || rest.hasPrefix("include")
                    || rest.hasPrefix("import")
                    || rest.hasPrefix("define")
                    || rest.hasPrefix("ifdef")
                    || rest.hasPrefix("ifndef")
                    || rest.hasPrefix("endif")
                    || rest.hasPrefix("pragma")
                if !isPreprocessorOrAttr {
                    flush()
                    result.append((String(line[index...]), .comment))
                    return result
                }
            }

            // 引号字符串（含转义）；后随冒号 → JSON 键（关键字色）
            if character == "\"" || character == "'" {
                flush()
                var end = line.index(after: index)
                while end < line.endIndex {
                    if line[end] == "\\" {
                        end = line.index(end, offsetBy: 2, limitedBy: line.endIndex) ?? line.endIndex
                        continue
                    }
                    if line[end] == character {
                        end = line.index(after: end)
                        break
                    }
                    end = line.index(after: end)
                }
                var peek = end
                while peek < line.endIndex, line[peek] == " " {
                    peek = line.index(after: peek)
                }
                let isKey = peek < line.endIndex && line[peek] == ":"
                result.append((String(line[index..<end]), isKey ? .keyword : .string))
                index = end
                continue
            }

            // 数字
            if character.isNumber {
                flush()
                var end = index
                while end < line.endIndex, line[end].isNumber || line[end] == "." {
                    end = line.index(after: end)
                }
                result.append((String(line[index..<end]), .number))
                index = end
                continue
            }

            // 标识符（关键字判定）
            if character.isLetter || character == "_" {
                var end = index
                while end < line.endIndex,
                      line[end].isLetter || line[end].isNumber || line[end] == "_" {
                    end = line.index(after: end)
                }
                let word = String(line[index..<end])
                if keywords.contains(word) {
                    flush()
                    result.append((word, .keyword))
                } else {
                    current += word
                }
                index = end
                continue
            }

            current.append(character)
            index = line.index(after: index)
        }

        flush()
        return result
    }
}
