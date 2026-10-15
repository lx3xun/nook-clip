import Foundation

public struct ParsedSearchQuery: Equatable, Sendable {
    public var rawQuery: String
    public var keywords: [String]

    public init(rawQuery: String, keywords: [String] = []) {
        self.rawQuery = rawQuery
        self.keywords = keywords
    }
}

public enum SearchQueryParser {
    /// 统一解析入口：纯文本关键词切分（按空白分割，保留双引号短语）
    public static func parse(_ text: String, now: Date = Date()) -> ParsedSearchQuery {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ParsedSearchQuery(rawQuery: "")
        }

        var tokens: [String] = []
        var currentToken = ""
        var inQuotes = false
        for char in trimmed {
            if char == "\"" {
                inQuotes.toggle()
            } else if char.isWhitespace && !inQuotes {
                if !currentToken.isEmpty {
                    tokens.append(currentToken)
                    currentToken = ""
                }
            } else {
                currentToken.append(char)
            }
        }
        if !currentToken.isEmpty {
            tokens.append(currentToken)
        }

        let cleanKeywords = tokens
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return ParsedSearchQuery(rawQuery: trimmed, keywords: cleanKeywords)
    }

}
