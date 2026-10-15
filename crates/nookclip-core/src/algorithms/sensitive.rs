use regex::Regex;
use std::sync::LazyLock;

static PATTERNS: LazyLock<Vec<(&'static str, Regex)>> = LazyLock::new(|| {
    vec![
        (
            "private_key",
            Regex::new(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----").unwrap(),
        ),
        (
            "anthropic_key",
            Regex::new(r"\bsk-ant-(?:api03-)?[a-zA-Z0-9_-]{20,}\b").unwrap(),
        ),
        (
            "openai_key",
            Regex::new(r"\bsk-(?:proj-)?[a-zA-Z0-9_-]{20,}\b").unwrap(),
        ),
        (
            "aws_access_key",
            Regex::new(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b").unwrap(),
        ),
        (
            "github_token",
            Regex::new(r"\b(?:(?:ghp|gho|ghu|ghs|ghr)_[a-zA-Z0-9_]{36,}|github_pat_[a-zA-Z0-9_]{50,})\b").unwrap(),
        ),
        (
            "gitlab_token",
            Regex::new(r"\bglpat-[a-zA-Z0-9_-]{20,}\b").unwrap(),
        ),
        (
            "slack_token",
            Regex::new(r"\bxox[baprs]-[0-9a-zA-Z-]{10,}\b").unwrap(),
        ),
        (
            "connection_string_with_password",
            Regex::new(r"(?i)(?:postgres|postgresql|mysql|mongodb|redis|amqp|mssql|[a-zA-Z0-9+.-]+)://[^\s:@/]*:[^\s@/]+@[^\s/]+").unwrap(),
        ),
        (
            "jwt_token",
            Regex::new(r"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b").unwrap(),
        ),
        (
            "bearer_token",
            Regex::new(r"(?i)(?:Authorization\s*:\s*)?\bBearer\s+[A-Za-z0-9._~+/=-]{20,}").unwrap(),
        ),
        (
            "password_assignment",
            Regex::new(r#"(?i)\b(?:password|passwd|pwd|db_password|api_secret|client_secret)\b\s*[:=]\s*["']?([^\s"'`,;]{8,})["']?"#).unwrap(),
        ),
    ]
});
pub fn detect_sensitive_data(text: &str) -> Option<&'static str> {
    for (name, re) in PATTERNS.iter() {
        if re.is_match(text) {
            return Some(name);
        }
    }
    None
}

pub fn mask_sensitive_text(text: &str) -> String {
    let first_line = text.lines().find(|l| !l.trim().is_empty()).unwrap_or(text).trim();
    let char_count = first_line.chars().count();

    if char_count <= 4 {
        return "••••••••".to_string();
    }

    if first_line.starts_with("sk-proj-") && char_count > 14 {
        let prefix: String = first_line.chars().take(8).collect();
        let suffix: String = first_line.chars().skip(char_count - 4).collect();
        return format!("{}••••••••{}", prefix, suffix);
    }

    if first_line.starts_with("sk-ant-") && char_count > 13 {
        let prefix: String = first_line.chars().take(7).collect();
        let suffix: String = first_line.chars().skip(char_count - 4).collect();
        return format!("{}••••••••{}", prefix, suffix);
    }

    if char_count <= 8 {
        let prefix: String = first_line.chars().take(1).collect();
        let suffix: String = first_line.chars().skip(char_count - 1).collect();
        format!("{}••••{}", prefix, suffix)
    } else {
        let prefix: String = first_line.chars().take(4).collect();
        let suffix: String = first_line.chars().skip(char_count - 4).collect();
        format!("{}••••••••{}", prefix, suffix)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_detect_openai() {
        assert_eq!(
            detect_sensitive_data("Bearer sk-proj-1234567890abcdef1234567890"),
            Some("openai_key")
        );
    }

    #[test]
    fn test_detect_aws() {
        assert_eq!(
            detect_sensitive_data("export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE"),
            Some("aws_access_key")
        );
    }

    #[test]
    fn test_detect_private_key() {
        assert_eq!(
            detect_sensitive_data("-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQ..."),
            Some("private_key")
        );
    }

    #[test]
    fn test_normal_text() {
        assert_eq!(
            detect_sensitive_data("Hello world, this is normal text!"),
            None
        );
    }

    #[test]
    fn test_detect_bearer_and_password_assignment() {
        assert_eq!(
            detect_sensitive_data("Authorization: Bearer ya29.a0AfH6SMBx1234567890abcdef"),
            Some("bearer_token")
        );
        assert_eq!(
            detect_sensitive_data("db_password = \"SuperSecretPass123!\""),
            Some("password_assignment")
        );
    }

    #[test]
    fn test_mask_sensitive_text_partial() {
        assert_eq!(mask_sensitive_text("df94e2db9bd390a1dc28792f6cee9434"), "df94••••••••9434");
        assert_eq!(mask_sensitive_text("sk-proj-abcdef1234567890"), "sk-proj-••••••••7890");
        assert_eq!(mask_sensitive_text("short"), "s••••t");
        assert_eq!(mask_sensitive_text("123"), "••••••••");
    }
}
