pub mod auto_burn;
pub mod color;
pub mod diff;
pub mod form_burst;
pub mod highlight;
pub mod kind;
pub mod language;
pub mod ocr_layout;
pub mod retention;
pub mod scrub;
pub mod sensitive;
pub mod source_resolver;
pub mod terminal_guard;
use crate::model::DetectionResult;
use std::sync::LazyLock;

static EMAIL_REGEX: LazyLock<regex::Regex> = LazyLock::new(|| {
    regex::Regex::new(r"(?i)[A-Z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,64}").unwrap()
});

pub fn analyze_content(text: &str) -> DetectionResult {
    analyze_content_with_sensitivity(text, None)
}

/// 与 analyze_content 相同，但允许复用调用方已算出的敏感检测结果。
/// 剪贴板摄取路径会先跑一次 detect_sensitive，非敏感分支再调本函数，
/// 传 Some(false) 可避免同一套 PATTERNS 正则重复扫描整段文本。
pub fn analyze_content_with_sensitivity(
    text: &str,
    known_sensitive: Option<bool>,
) -> DetectionResult {
    let trimmed = text.trim();
    let sensitive_type = match known_sensitive {
        Some(false) => None,
        _ => sensitive::detect_sensitive_data(trimmed),
    };
    let code_classification = language::classify_code(trimmed);
    let detected_color_hex = color::parse_color_hex(trimmed);

    // Email regex check（静态编译，避免每次分析重复构建）
    let has_email = EMAIL_REGEX.is_match(trimmed);

    // URL check
    let is_url = trimmed.starts_with("http://") || trimmed.starts_with("https://");

    DetectionResult {
        is_sensitive: sensitive_type.is_some(),
        sensitive_type: sensitive_type.map(|s| s.to_string()),
        detected_language: code_classification.language,
        is_code: code_classification.is_code,
        detected_color_hex,
        has_email,
        is_url,
    }
}
