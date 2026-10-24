use nookclip_core::{
    exchange::{export_json, export_markdown, SensitiveExportMode},
    model::ClipItemSummary,
    storage::StorageRepository,
};
use tempfile::NamedTempFile;

#[test]
fn test_export_json_and_markdown_sensitive_modes() {
    let temp_file = NamedTempFile::new().unwrap();
    let key = [3u8; 32];
    let repo = StorageRepository::new(temp_file.path().to_str().unwrap(), &key).unwrap();

    let normal_item = ClipItemSummary {
        id: "id-normal".to_string(),
        item_type: "text".to_string(),
        title: "Normal Note".to_string(),
        summary: "Normal Summary".to_string(),
        created_at: 100.0,
        last_used_at: 100.0,
        copy_count: 1,
        favorite: false,
        source_app_bundle_id: None,
        source_app_name: None,
        is_sensitive: false,
        deleted_at: None,
        ..Default::default()
    };
    repo.save_item(&normal_item, Some("Normal content"))
        .unwrap();
    // 标签：导出应携带
    repo.set_tags("id-normal", &["api".to_string(), "work".to_string()])
        .unwrap();

    let secret_item = ClipItemSummary {
        id: "id-secret".to_string(),
        item_type: "text".to_string(),
        title: "API Secret".to_string(),
        summary: "sk-proj-secret-12345".to_string(),
        created_at: 110.0,
        last_used_at: 110.0,
        copy_count: 1,
        favorite: true,
        source_app_bundle_id: None,
        source_app_name: None,
        is_sensitive: true,
        deleted_at: None,
        ..Default::default()
    };
    repo.save_item(&secret_item, Some("sk-proj-secret-12345"))
        .unwrap();

    // Mode 1: Exclude
    let json_exclude = export_json(&repo, SensitiveExportMode::Exclude).unwrap();
    assert!(json_exclude.contains("Normal Note"));
    assert!(!json_exclude.contains("API Secret"));
    // 标签随 JSON 导出（#[serde(default)] tags 字段）
    assert!(json_exclude.contains("\"tags\""));
    assert!(json_exclude.contains("\"api\""));
    assert!(json_exclude.contains("\"work\""));

    // Mode 2: Masked
    let json_masked = export_json(&repo, SensitiveExportMode::Masked).unwrap();
    assert!(json_masked.contains("Normal Note"));
    assert!(json_masked.contains("API Secret"));
    assert!(json_masked.contains("••••••••"));
    assert!(!json_masked.contains("sk-proj-secret-12345"));

    // Mode 3: Plaintext
    let json_plain = export_json(&repo, SensitiveExportMode::Plaintext).unwrap();
    assert!(json_plain.contains("sk-proj-secret-12345"));

    // Markdown export
    let md_masked = export_markdown(&repo, SensitiveExportMode::Masked).unwrap();
    assert!(md_masked.contains("# NookClip Clipboard History Export"));
    assert!(md_masked.contains("## Normal Note"));
    assert!(md_masked.contains("## API Secret"));
    assert!(md_masked.contains("••••••••"));
    // Markdown 每行带 `  Tags: a, b`
    assert!(md_masked.contains("  Tags: api, work"));
}
