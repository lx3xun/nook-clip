use super::{color, language};
use std::collections::HashSet;
use std::sync::LazyLock;

/// 行类型枚举（与 Swift RowKind 严格对齐）
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum ItemKind {
    Text,
    Image,
    File,
    Url,
    Code,
    Json,
    Color,
    Sensitive,
}

static IMAGE_EXTENSIONS: LazyLock<HashSet<&'static str>> = LazyLock::new(|| {
    [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "svg",
    ]
    .into_iter()
    .collect()
});

/// 判定 payload_path 是否为单图片文件路径（对应 Swift isSingleImageFilePath）
pub fn is_single_image_file_path(path: Option<&str>) -> bool {
    let Some(p) = path else { return false };
    let trimmed = p.trim();
    if trimmed.is_empty() || trimmed.contains('\n') {
        return false;
    }
    let ext = match trimmed.rsplit('.').next() {
        Some(e) if e.len() < trimmed.len() => e.to_ascii_lowercase(),
        _ => return false,
    };
    IMAGE_EXTENSIONS.contains(ext.as_str())
}

/// 从 metadata_json 提取规范化语言
fn extract_metadata_language(metadata_json: Option<&str>) -> Option<String> {
    let json_str = metadata_json?.trim();
    if json_str.is_empty() {
        return None;
    }
    let v: serde_json::Value = serde_json::from_str(json_str).ok()?;
    let lang = v.get("language")?.as_str()?.trim();
    if lang.is_empty() {
        None
    } else {
        Some(lang.to_ascii_lowercase())
    }
}

/// 快速判断文本是否为 JSON（先首尾括弧，再完整反序列化校验）
fn is_valid_json(text: &str) -> bool {
    let trimmed = text.trim();
    if trimmed.len() < 2 {
        return false;
    }
    let has_braces = trimmed.starts_with('{') && trimmed.ends_with('}');
    let has_brackets = trimmed.starts_with('[') && trimmed.ends_with(']');
    if !has_braces && !has_brackets {
        return false;
    }
    serde_json::from_str::<serde_json::Value>(trimmed).is_ok()
}

/// 行类型派生规则（与 Swift ClipboardRowModel.init(item:) 逐项一致）：
/// sensitive (is_sensitive) > image / file / url (= item_type)
/// > json / code (metadata.language 优先)
/// > json (summary 校验) > color (ColorDetector) > code (classify_language) > text
pub fn classify_kind(
    item_type: &str,
    is_sensitive: bool,
    metadata_json: Option<&str>,
    summary: &str,
    payload_path: Option<&str>,
) -> ItemKind {
    if is_sensitive {
        return ItemKind::Sensitive;
    }

    match item_type {
        "image" => ItemKind::Image,
        "file" => {
            if is_single_image_file_path(payload_path) {
                ItemKind::Image
            } else {
                ItemKind::File
            }
        }
        "url" => ItemKind::Url,
        _ => {
            // 文本类条目：先采信捕获侧写入的 metadata.language
            if let Some(lang) = extract_metadata_language(metadata_json) {
                if lang == "json" {
                    ItemKind::Json
                } else {
                    ItemKind::Code
                }
            } else if is_valid_json(summary) {
                ItemKind::Json
            } else if color::parse_color_hex(summary).is_some() {
                ItemKind::Color
            } else if language::is_code_like(summary) {
                ItemKind::Code
            } else {
                ItemKind::Text
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_sensitive_takes_precedence() {
        assert_eq!(
            classify_kind("text", true, None, "#ffffff", None),
            ItemKind::Sensitive
        );
        assert_eq!(
            classify_kind("image", true, None, "shot.png", None),
            ItemKind::Sensitive
        );
    }

    #[test]
    fn test_single_image_file_reclassified_as_image() {
        assert_eq!(
            classify_kind("file", false, None, "a.png", Some("/tmp/a.png")),
            ItemKind::Image
        );
        assert_eq!(
            classify_kind("file", false, None, "a.txt", Some("/tmp/a.txt")),
            ItemKind::File
        );
        assert_eq!(
            classify_kind(
                "file",
                false,
                None,
                "multi",
                Some("/tmp/a.png\n/tmp/b.png")
            ),
            ItemKind::File
        );
    }

    #[test]
    fn test_metadata_language_takes_precedence_over_body() {
        let meta_json = r#"{"language":"json"}"#;
        assert_eq!(
            classify_kind("text", false, Some(meta_json), "not valid json", None),
            ItemKind::Json
        );
        let meta_swift = r#"{"language":"swift"}"#;
        assert_eq!(
            classify_kind("text", false, Some(meta_swift), "#ffffff", None),
            ItemKind::Code
        );
    }

    #[test]
    fn test_fallback_derivation_order() {
        // Valid JSON without metadata
        assert_eq!(
            classify_kind("text", false, None, r#"{"k":"v"}"#, None),
            ItemKind::Json
        );
        // Color hex
        assert_eq!(
            classify_kind("text", false, None, "#3498db", None),
            ItemKind::Color
        );
        // Code heuristic
        let code = "def foo():\n    return 42\n";
        assert_eq!(
            classify_kind("text", false, None, code, None),
            ItemKind::Code
        );
        // Plain text
        assert_eq!(
            classify_kind("text", false, None, "hello world from nook", None),
            ItemKind::Text
        );
    }
}
