use regex::Regex;
use std::sync::LazyLock;

static ANCHOR_REGEX: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#"(?is)<a\b[^>]*>(.*?)</a>"#).expect("Valid anchor regex")
});

static TAG_REGEX: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#"<[^>]+>"#).expect("Valid tag regex")
});

/// Extracts the first non-empty `<a>` tag text from HTML, stripping inner tags,
/// decoding common HTML entities, and truncating to at most 48 characters.
pub fn extract_first_anchor_text(html: &str) -> Option<String> {
    for caps in ANCHOR_REGEX.captures_iter(html) {
        if let Some(inner) = caps.get(1) {
            let stripped = TAG_REGEX.replace_all(inner.as_str(), "");
            let decoded = decode_html_entities(&stripped);
            let trimmed = decoded.trim();
            if !trimmed.is_empty() {
                let char_vec: Vec<char> = trimmed.chars().collect();
                let truncated: String = if char_vec.len() > 48 {
                    char_vec[..48].iter().collect()
                } else {
                    trimmed.to_string()
                };
                return Some(truncated);
            }
        }
    }
    None
}

fn decode_html_entities(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'")
        .replace("&nbsp;", " ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_simple_anchor() {
        let html = r#"<p>Visit <a href="https://example.com">Example Domain</a> now</p>"#;
        assert_eq!(extract_first_anchor_text(html), Some("Example Domain".to_string()));
    }

    #[test]
    fn test_strip_nested_tags_and_decode_entities() {
        let html = r#"<a href="/doc"><strong>Tom &amp; Jerry</strong> &quot;Play&quot;</a>"#;
        assert_eq!(extract_first_anchor_text(html), Some("Tom & Jerry \"Play\"".to_string()));
    }

    #[test]
    fn test_truncate_to_48_chars() {
        let long_title = "A".repeat(100);
        let html = format!(r#"<a href="/test">{}</a>"#, long_title);
        let extracted = extract_first_anchor_text(&html).unwrap();
        assert_eq!(extracted.chars().count(), 48);
        assert_eq!(extracted, "A".repeat(48));
    }

    #[test]
    fn test_empty_or_no_anchor() {
        assert_eq!(extract_first_anchor_text(""), None);
        assert_eq!(extract_first_anchor_text("<p>No links</p>"), None);
        assert_eq!(extract_first_anchor_text(r#"<a href="/empty">   </a>"#), None);
    }
}
