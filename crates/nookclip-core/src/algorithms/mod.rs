pub mod color;
pub mod highlight;
pub mod kind;
pub mod language;
pub mod ocr_layout;
pub mod retention;
pub mod sensitive;
pub mod source_resolver;
use crate::model::DetectionResult;
use std::sync::LazyLock;

static EMAIL_REGEX: LazyLock<regex::Regex> = LazyLock::new(|| {
    regex::Regex::new(r"(?i)[A-Z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,64}").unwrap()
});

pub fn analyze_content(text: &str) -> DetectionResult {
    let trimmed = text.trim();
    let sensitive_type = sensitive::detect_sensitive_data(trimmed);
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
