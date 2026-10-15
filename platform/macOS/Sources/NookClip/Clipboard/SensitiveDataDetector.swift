import Foundation

public struct SensitiveDataDetector {
    public struct DetectionResult: Equatable {
        public let isSensitive: Bool
        public let category: String
        public let maskedText: String

        public init(isSensitive: Bool, category: String, maskedText: String) {
            self.isSensitive = isSensitive
            self.category = category
            self.maskedText = maskedText
        }
    }
    
    private struct Rule {
        let name: String
        let regex: NSRegularExpression
        let isFullReplacement: Bool
        let maskGenerator: (String, NSTextCheckingResult) -> String
    }
    
    private static let rules: [Rule] = [
        // 1. PEM 私钥
        Rule(
            name: "Private Key",
            regex: try! NSRegularExpression(
                pattern: "-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----|-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----",
                options: []
            ),
            isFullReplacement: false,
            maskGenerator: { text, match in
                let matchedStr = (text as NSString).substring(with: match.range)
                if let firstLine = matchedStr.components(separatedBy: .newlines).first {
                    return "\(firstLine) •••••••• [End]"
                }
                return "-----BEGIN PRIVATE KEY----- •••••••• [End]"
            }
        ),
        
        // 2. 通用 API Key (sk- / sk-proj-，广泛用于 OpenAI、DeepSeek、Moonshot 等大模型)
        Rule(
            name: "API Key",
            regex: try! NSRegularExpression(pattern: "\\b(sk-(?:proj-)?[A-Za-z0-9_-]{20,})\\b"),
            isFullReplacement: false,
            maskGenerator: { text, match in
                let token = (text as NSString).substring(with: match.range)
                return maskToken(token, prefixKeep: token.hasPrefix("sk-proj-") ? 8 : 3, suffixKeep: 4)
            }
        ),
        
        // 3. Anthropic API Key
        Rule(
            name: "API Key",
            regex: try! NSRegularExpression(pattern: "\\b(sk-ant-(?:api03-)?[A-Za-z0-9_-]{20,})\\b"),
            isFullReplacement: false,
            maskGenerator: { text, match in
                let token = (text as NSString).substring(with: match.range)
                return maskToken(token, prefixKeep: 7, suffixKeep: 4)
            }
        ),
        
        // 4. AWS Access Key ID
        Rule(
            name: "AWS",
            regex: try! NSRegularExpression(pattern: "\\b((?:AKIA|ASIA)[0-9A-Z]{16})\\b"),
            isFullReplacement: false,
            maskGenerator: { text, match in
                let token = (text as NSString).substring(with: match.range)
                return maskToken(token, prefixKeep: 4, suffixKeep: 4)
            }
        ),
        
        // 5. GitHub Token
        Rule(
            name: "GitHub",
            regex: try! NSRegularExpression(pattern: "\\b((?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{36,})\\b"),
            isFullReplacement: false,
            maskGenerator: { text, match in
                let token = (text as NSString).substring(with: match.range)
                return maskToken(token, prefixKeep: 4, suffixKeep: 4)
            }
        ),
        
        // 6. GitLab Token
        Rule(
            name: "GitLab",
            regex: try! NSRegularExpression(pattern: "\\b(glpat-[A-Za-z0-9_\\-]{20,})\\b"),
            isFullReplacement: false,
            maskGenerator: { text, match in
                let token = (text as NSString).substring(with: match.range)
                return maskToken(token, prefixKeep: 6, suffixKeep: 4)
            }
        ),
        
        // 7. Slack Token
        Rule(
            name: "Slack",
            regex: try! NSRegularExpression(pattern: "\\b(xox[baprs]-[A-Za-z0-9\\-]{10,})\\b"),
            isFullReplacement: false,
            maskGenerator: { text, match in
                let token = (text as NSString).substring(with: match.range)
                return maskToken(token, prefixKeep: 5, suffixKeep: 4)
            }
        ),
        
        // 8. 包含密码的数据库/协议 URI: postgres://user:pass@host:5432、redis://:pass@host（空用户名）
        // 用户名允许为空（`*`）：Redis 等标准 DSN 常为空用户名 + 密码（审计 BUG-050）
        Rule(
            name: "Database",
            regex: try! NSRegularExpression(
                pattern: "((?:postgres|postgresql|mysql|mongodb|redis|amqp|mssql):\\/\\/[^\\s:@\\/]*:)([^\\s@\\/]+)(@[^\\s]+)",
                options: [.caseInsensitive]
            ),
            isFullReplacement: false,
            maskGenerator: { text, match in
                let nsString = text as NSString
                guard match.numberOfRanges >= 4 else { return "••••••••" }
                let prefix = nsString.substring(with: match.range(at: 1))
                let suffix = nsString.substring(with: match.range(at: 3))
                return "\(prefix)••••••••\(suffix)"
            }
        ),
        
        // 9. JWT (三段式 Base64)
        Rule(
            name: "JWT",
            regex: try! NSRegularExpression(pattern: "\\b(eyJ[A-Za-z0-9_-]{10,}\\.eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,})\\b"),
            isFullReplacement: false,
            maskGenerator: { text, match in
                let token = (text as NSString).substring(with: match.range)
                return maskToken(token, prefixKeep: 3, suffixKeep: 4)
            }
        ),

        // 10. HTTP Bearer 鉴权头（PRD §4.4.2 规则 6）
        Rule(
            name: "Bearer",
            regex: try! NSRegularExpression(
                pattern: "((?:Authorization\\s*:\\s*)?\\bBearer\\s+)([A-Za-z0-9._~+/=-]{20,})",
                options: [.caseInsensitive]
            ),
            isFullReplacement: false,
            maskGenerator: { text, match in
                let nsString = text as NSString
                guard match.numberOfRanges >= 3 else { return "Bearer ••••••••" }
                let prefix = nsString.substring(with: match.range(at: 1))
                let token = nsString.substring(with: match.range(at: 2))
                return "\(prefix)\(maskToken(token, prefixKeep: 4, suffixKeep: 4))"
            }
        ),

        // 11. 配置中的密码/密钥赋值（PRD §4.4.2 规则 7）
        Rule(
            name: "Password",
            regex: try! NSRegularExpression(
                pattern: "(\\b(?:password|passwd|pwd|db_password|api_secret|client_secret)\\b\\s*[:=]\\s*[\"']?)([^\\s\"'`,;]{8,})([\"']?)",
                options: [.caseInsensitive]
            ),
            isFullReplacement: false,
            maskGenerator: { text, match in
                let nsString = text as NSString
                guard match.numberOfRanges >= 4 else { return "••••••••" }
                let prefix = nsString.substring(with: match.range(at: 1))
                let suffix = nsString.substring(with: match.range(at: 3))
                return "\(prefix)••••••••\(suffix)"
            }
        )
    ]
    
    /// 检测文本是否含有敏感凭据并返回脱敏结果
    public static func detect(text: String) -> DetectionResult? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 超长文本采样检测：与 LanguageClassifier 的 8KB 采样对齐，凭据最常见于
        // 文件头尾（审查 R6/FR-008）。超过 64KB 仅检测前 32KB + 后 32KB。
        let nsText = text as NSString
        let detectedText: String
        if nsText.length > 64 * 1024 {
            let headRange = NSRange(location: 0, length: 32 * 1024)
            let tailStart = max(0, nsText.length - 32 * 1024)
            let tailRange = NSRange(location: tailStart, length: nsText.length - tailStart)
            detectedText = nsText.substring(with: headRange)
                + "\n"
                + nsText.substring(with: tailRange)
        } else {
            detectedText = text
        }

        var matchedCategories: [String] = []
        var replacements: [(range: NSRange, replacement: String)] = []
        let nsString = detectedText as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)

        for rule in rules {
            let matches = rule.regex.matches(in: detectedText, options: [], range: fullRange)
            if !matches.isEmpty {
                if !matchedCategories.contains(rule.name) {
                    matchedCategories.append(rule.name)
                }
                for match in matches {
                    let masked = rule.maskGenerator(detectedText, match)
                    replacements.append((range: match.range, replacement: masked))
                }
            }
        }

        guard !matchedCategories.isEmpty else { return nil }

        // 从后向前替换，避免 range 偏移。重叠匹配先去重：同一文本区间可能同时
        // 命中多条规则（如 sk-ant- 同时命中规则 2/3），重复应用会让第二次替换
        // 落在已缩短的文本上、连同 Token 之后的正文一起破坏（审计 BUG-010）。
        // 同区间保留首个命中（更长/更具体的规则优先）
        var maskedText = detectedText
        let sortedReplacements = replacements.sorted { $0.range.location > $1.range.location }
        var appliedRanges: [NSRange] = []
        for r in sortedReplacements {
            guard !appliedRanges.contains(where: { NSIntersectionRange($0, r.range).length > 0 }) else {
                continue
            }
            appliedRanges.append(r.range)
            if let swiftRange = Range(r.range, in: maskedText) {
                maskedText.replaceSubrange(swiftRange, with: r.replacement)
            }
        }

        let categorySummary = matchedCategories.joined(separator: ", ")

        return DetectionResult(
            isSensitive: true,
            category: categorySummary,
            maskedText: maskedText
        )
    }
    
    private static func maskToken(_ token: String, prefixKeep: Int, suffixKeep: Int) -> String {
        guard token.count > (prefixKeep + suffixKeep + 2) else {
            return "••••••••"
        }
        let prefix = token.prefix(prefixKeep)
        let suffix = token.suffix(suffixKeep)
        return "\(prefix)...\(suffix)"
    }
}
