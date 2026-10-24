use nookclip_core::{
    exchange::{export_json, import_json, SensitiveExportMode},
    model::{ClipItemSummary, QueryFilter},
    storage::StorageRepository,
};
use tempfile::NamedTempFile;

#[test]
fn test_import_json_deduplication_and_encryption() {
    let file_src = NamedTempFile::new().unwrap();
    let file_dst = NamedTempFile::new().unwrap();
    let key = [4u8; 32];

    let repo_src = StorageRepository::new(file_src.path().to_str().unwrap(), &key).unwrap();
    let repo_dst = StorageRepository::new(file_dst.path().to_str().unwrap(), &key).unwrap();

    let item1 = ClipItemSummary {
        id: "id-import-1".to_string(),
        item_type: "text".to_string(),
        title: "Exported Note".to_string(),
        summary: "Important Text".to_string(),
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
    repo_src.save_item(&item1, Some("Important Text"))
        .unwrap();
    repo_src
        .set_tags("id-import-1", &["api".to_string(), "work".to_string()])
        .unwrap();

    let json = export_json(&repo_src, SensitiveExportMode::Plaintext).unwrap();

    // First import into fresh database
    let report1 = import_json(&repo_dst, &json).unwrap();
    assert_eq!(report1.imported_count, 1);
    assert_eq!(report1.skipped_duplicates, 0);

    let items = repo_dst.query_items(&QueryFilter::default()).unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].title, "Exported Note");
    // 导入后标签迁移落地（升序）
    assert_eq!(items[0].tags, vec!["api".to_string(), "work".to_string()]);

    // Second import of same JSON: must skip duplicate
    let report2 = import_json(&repo_dst, &json).unwrap();
    assert_eq!(report2.imported_count, 0);
    assert_eq!(report2.skipped_duplicates, 1);
}
#[test]
fn test_import_json_sensitive_items_with_same_mask_not_dropped() {
    let file_src = NamedTempFile::new().unwrap();
    let file_dst = NamedTempFile::new().unwrap();
    let key = [9u8; 32];

    let repo_src = StorageRepository::new(file_src.path().to_str().unwrap(), &key).unwrap();
    let repo_dst = StorageRepository::new(file_dst.path().to_str().unwrap(), &key).unwrap();

    // Two distinct sensitive credentials with same masked summary
    let item_secret1 = ClipItemSummary {
        id: "id-secret-1".to_string(),
        item_type: "text".to_string(),
        title: "AWS Secret".to_string(),
        summary: "••••••••".to_string(),
        created_at: 100.0,
        last_used_at: 100.0,
        copy_count: 1,
        favorite: false,
        source_app_bundle_id: None,
        source_app_name: None,
        is_sensitive: true,
        deleted_at: None,
        ..Default::default()
    };
    let item_secret2 = ClipItemSummary {
        id: "id-secret-2".to_string(),
        item_type: "text".to_string(),
        title: "DB Password".to_string(),
        summary: "••••••••".to_string(),
        created_at: 105.0,
        last_used_at: 105.0,
        copy_count: 1,
        favorite: false,
        source_app_bundle_id: None,
        source_app_name: None,
        is_sensitive: true,
        deleted_at: None,
        ..Default::default()
    };

    repo_src.save_item(&item_secret1, Some("AKIAIOSFODNN7EXAMPLE")).unwrap();
    repo_src.save_item(&item_secret2, Some("SuperSecretPassword123!")).unwrap();

    let json = export_json(&repo_src, SensitiveExportMode::Plaintext).unwrap();

    let report = import_json(&repo_dst, &json).unwrap();
    assert_eq!(report.imported_count, 2, "Both sensitive items must be imported despite identical summary");
    assert_eq!(report.skipped_duplicates, 0);

    let items = repo_dst.query_items(&QueryFilter::default()).unwrap();
    assert_eq!(items.len(), 2);
}
