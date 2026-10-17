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
    /// 检测文本是否含有敏感凭据并返回脱敏结果（单轨化委托给 Rust 核心）
    public static func detect(text: String) -> DetectionResult? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let res = classifyTextContent(text: text)
        guard res.isSensitive else { return nil }

        let rawType = res.sensitiveType ?? "sensitive"
        let categoryName = displayCategory(for: rawType)
        let masked = maskSensitiveText(text: text)
        return DetectionResult(isSensitive: true, category: categoryName, maskedText: masked)
    }

    private static func displayCategory(for raw: String) -> String {
        switch raw {
        case "openai_key", "anthropic_key": return "API Key"
        case "aws_access_key": return "AWS"
        case "connection_string_with_password": return "Database"
        case "private_key": return "Private Key"
        case "github_token": return "GitHub"
        case "gitlab_token": return "GitLab"
        case "slack_token": return "Slack"
        case "jwt_token": return "JWT"
        case "bearer_token": return "Bearer"
        case "password_assignment": return "Password"
        default: return "Sensitive"
        }
    }

}
