use regex::Regex;
use std::sync::LazyLock;

static PATTERNS: LazyLock<Vec<(&'static str, Regex)>> = LazyLock::new(|| {
    vec![
        (
            "private_key",
            Regex::new(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----|-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*").unwrap(),
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
            Regex::new(r"(?i)((?:postgres|postgresql|mysql|mongodb|redis|amqp|mssql|[a-zA-Z0-9+.-]+)://[^\s:@/]*:)([^\s@/]+)(@[^\s/]+)").unwrap(),
        ),
        (
            "jwt_token",
            Regex::new(r"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b").unwrap(),
        ),
        (
            "bearer_token",
            Regex::new(r"(?i)((?:Authorization\s*:\s*)?\bBearer\s+)([A-Za-z0-9._~+/=-]{20,})").unwrap(),
        ),
        (
            "password_assignment",
            Regex::new(r#"(?i)(\b(?:password|passwd|pwd|db_password|api_secret|client_secret)\b\s*[:=]\s*["']?)([^\s"'`,;]{8,})(["']?)"#).unwrap(),
        ),
    ]
});

const MAX_SAMPLE_BYTES: usize = 65_536;
const HALF_SAMPLE_BYTES: usize = 32_768;

fn sample_text_64kb(text: &str) -> std::borrow::Cow<'_, str> {
    if text.len() <= MAX_SAMPLE_BYTES {
        return std::borrow::Cow::Borrowed(text);
    }
    let mut head_end = HALF_SAMPLE_BYTES.min(text.len());
    while head_end > 0 && !text.is_char_boundary(head_end) {
        head_end -= 1;
    }
    let mut tail_start = text.len().saturating_sub(HALF_SAMPLE_BYTES);
    while tail_start < text.len() && !text.is_char_boundary(tail_start) {
        tail_start += 1;
    }
    if head_end >= tail_start {
        return std::borrow::Cow::Borrowed(text);
    }
    let mut combined = String::with_capacity(head_end + 1 + (text.len() - tail_start));
    combined.push_str(&text[..head_end]);
    combined.push('\n');
    combined.push_str(&text[tail_start..]);
    std::borrow::Cow::Owned(combined)
}

pub fn detect_sensitive_data(text: &str) -> Option<&'static str> {
    let sampled = sample_text_64kb(text);
    for (name, re) in PATTERNS.iter() {
        if re.is_match(&sampled) {
            return Some(name);
        }
    }
    None
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SensitiveDetection {
    pub is_sensitive: bool,
    pub sensitive_type: Option<&'static str>,
    pub masked_text: String,
}

pub fn detect_sensitive(text: &str) -> SensitiveDetection {
    let sampled = sample_text_64kb(text);
    if let Some(typ) = detect_sensitive_data(&sampled) {
        SensitiveDetection {
            is_sensitive: true,
            sensitive_type: Some(typ),
            masked_text: mask_sensitive_text(&sampled),
        }
    } else {
        SensitiveDetection {
            is_sensitive: false,
            sensitive_type: None,
            masked_text: text.to_string(),
        }
    }
}

pub fn mask_sensitive_text(text: &str) -> String {
    let mut replacements: Vec<(usize, usize, String)> = Vec::new();

    for (name, re) in PATTERNS.iter() {
        for caps in re.captures_iter(text) {
            let Some(m) = caps.get(0) else { continue };
            let start = m.start();
            let end = m.end();
            // 跳过与更高优先级已命中区间重叠的匹配（BUG-010）
            if replacements
                .iter()
                .any(|(s, e, _)| start < *e && end > *s)
            {
                continue;
            }

            let rep = match *name {
                "private_key" => {
                    let first_line = m.as_str().lines().next().unwrap_or("-----BEGIN PRIVATE KEY-----");
                    format!("{first_line} •••••••• [End]")
                }
                "connection_string_with_password" | "password_assignment" => {
                    let prefix = caps.get(1).map(|c| c.as_str()).unwrap_or("");
                    let suffix = caps.get(3).map(|c| c.as_str()).unwrap_or("");
                    format!("{prefix}••••••••{suffix}")
                }
                "bearer_token" => {
                    let prefix = caps.get(1).map(|c| c.as_str()).unwrap_or("Bearer ");
                    let token = caps.get(2).map(|c| c.as_str()).unwrap_or("");
                    format!("{prefix}{}", mask_single_token(token))
                }
                _ => mask_single_token(m.as_str()),
            };
            replacements.push((start, end, rep));
        }
    }

    if replacements.is_empty() {
        return mask_single_token(text);
    }

    // 从后往前替换，避免字节偏移失效
    replacements.sort_by(|a, b| b.0.cmp(&a.0));
    let mut masked = text.to_string();
    for (start, end, rep) in replacements {
        masked.replace_range(start..end, &rep);
    }
    masked
}
fn mask_single_token(token: &str) -> String {
    let char_count = token.chars().count();
    if char_count <= 4 {
        return "••••••••".to_string();
    }
    if token.starts_with("sk-proj-") && char_count > 14 {
        let prefix: String = token.chars().take(8).collect();
        let suffix: String = token.chars().skip(char_count - 4).collect();
        return format!("{}••••••••{}", prefix, suffix);
    }
    if token.starts_with("sk-ant-") && char_count > 13 {
        let prefix: String = token.chars().take(7).collect();
        let suffix: String = token.chars().skip(char_count - 4).collect();
        return format!("{}••••••••{}", prefix, suffix);
    }
    if char_count <= 8 {
        let prefix: String = token.chars().take(1).collect();
        let suffix: String = token.chars().skip(char_count - 1).collect();
        format!("{}••••{}", prefix, suffix)
    } else {
        let prefix: String = token.chars().take(4).collect();
        let suffix: String = token.chars().skip(char_count - 4).collect();
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

    #[test]
    fn test_mask_private_key_hides_body() {
        let pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA75890secretbody\n-----END RSA PRIVATE KEY-----";
        let det = detect_sensitive(pem);
        assert!(det.is_sensitive);
        assert_eq!(det.sensitive_type, Some("private_key"));
        assert!(!det.masked_text.contains("secretbody"));
        assert_eq!(det.masked_text, "-----BEGIN RSA PRIVATE KEY----- •••••••• [End]");
    }

    #[test]
    fn test_mask_multiple_credentials_and_64kb_sampling() {
        let text = "key1=sk-proj-111122223333444455556666 key2=AKIAIOSFODNN7EXAMPLE";
        let det = detect_sensitive(text);
        assert!(det.is_sensitive);
        assert!(!det.masked_text.contains("222233334444"));
        assert!(!det.masked_text.contains("IOSFODNN"));

        // 超过 64KB 且包含多字节 UTF-8 字符的采样不 panic 且能识别尾部密钥
        let padding = "中".repeat(25_000); // 75,000 bytes > 64KB
        let large = format!("{padding}\nsk-proj-999988887777666655554444");
        let large_det = detect_sensitive(&large);
        assert!(large_det.is_sensitive);
        assert!(!large_det.masked_text.contains("9999888877776666"));
    }
}
