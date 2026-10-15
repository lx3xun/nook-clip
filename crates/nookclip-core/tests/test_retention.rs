use nookclip_core::{
    model::{ClipItemSummary, QueryFilter, RetentionConfig},
    storage::StorageRepository,
};
use tempfile::NamedTempFile;

fn create_test_repo() -> (NamedTempFile, StorageRepository) {
    let temp_file = NamedTempFile::new().expect("temp file");
    let key = [42u8; 32];
    let repo = StorageRepository::new(temp_file.path().to_str().unwrap(), &key).expect("repo");
    (temp_file, repo)
}

fn create_item(id: &str, last_used_at: f64, favorite: bool) -> ClipItemSummary {
    ClipItemSummary {
        id: id.to_string(),
        item_type: "text".to_string(),
        title: format!("Title {id}"),
        summary: format!("Summary {id}"),
        created_at: last_used_at,
        last_used_at,
        copy_count: 1,
        favorite,
        source_app_bundle_id: None,
        source_app_name: None,
        is_sensitive: false,
        deleted_at: None,
        ..Default::default()
    }
}

#[test]
fn test_retention_prune_by_age() {
    let (_f, repo) = create_test_repo();

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs_f64();

    let old_timestamp = now - (40.0 * 86400.0); // 40 days ago
    let fresh_timestamp = now - (5.0 * 86400.0); // 5 days ago

    let old_normal = create_item("old-normal", old_timestamp, false);
    let old_fav = create_item("old-fav", old_timestamp, true);
    let fresh_normal = create_item("fresh-normal", fresh_timestamp, false);

    repo.save_item(&old_normal, None).unwrap();
    repo.save_item(&old_fav, None).unwrap();
    repo.save_item(&fresh_normal, None).unwrap();

    let purged = repo
        .prune_expired(&RetentionConfig {
            max_age_days: Some(30),
            max_item_count: None,
        })
        .unwrap();

    assert_eq!(purged.len(), 1);
    assert_eq!(purged[0].id, "old-normal");

    let remaining = repo.query_items(&QueryFilter::default()).unwrap();
    let ids: Vec<&str> = remaining.iter().map(|i| i.id.as_str()).collect();
    assert!(!ids.contains(&"old-normal"));
    assert!(ids.contains(&"old-fav")); // Preserved!
    assert!(ids.contains(&"fresh-normal"));
}

#[test]
fn test_retention_prune_by_max_count() {
    let (_f, repo) = create_test_repo();

    for i in 1..=10 {
        let is_fav = i == 1; // Item 1 is favorited
        let item = create_item(&format!("item-{i}"), 100.0 + i as f64, is_fav);
        repo.save_item(&item, None).unwrap();
    }

    // Currently 10 items (1 fav + 9 normal). Limit normal items to max 5.
    let purged = repo
        .prune_expired(&RetentionConfig {
            max_age_days: None,
            max_item_count: Some(5),
        })
        .unwrap();

    assert_eq!(purged.len(), 4);

    let remaining = repo.query_items(&QueryFilter::default()).unwrap();
    assert_eq!(remaining.len(), 6); // 1 fav + 5 normal = 6
    let ids: Vec<&str> = remaining.iter().map(|i| i.id.as_str()).collect();
    assert!(ids.contains(&"item-1")); // Fav preserved!
}

#[test]
fn test_retention_prune_returns_payload_path() {
    let (_f, repo) = create_test_repo();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs_f64();
    let old_timestamp = now - (40.0 * 86400.0);

    let mut item_with_payload = create_item("img-1", old_timestamp, false);
    item_with_payload.item_type = "image".to_string();
    item_with_payload.payload_path = Some("/tmp/test_image.png".to_string());

    repo.save_item(&item_with_payload, None).unwrap();

    let purged = repo
        .prune_expired(&RetentionConfig {
            max_age_days: Some(30),
            max_item_count: None,
        })
        .unwrap();

    assert_eq!(purged.len(), 1);
    assert_eq!(purged[0].id, "img-1");
    assert_eq!(purged[0].payload_path.as_deref(), Some("/tmp/test_image.png"));
}

#[test]
fn test_retention_prune_spares_soft_deleted_within_grace() {
    let (_f, repo) = create_test_repo();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs_f64();
    let old_timestamp = now - (40.0 * 86400.0);

    // 已软删除（撤销宽限窗口内）的过期条目：保留期清理不得越权硬删
    let soft_deleted = create_item("soft-deleted", old_timestamp, false);
    repo.save_item(&soft_deleted, None).unwrap();
    repo.soft_delete("soft-deleted").unwrap();

    let purged = repo
        .prune_expired(&RetentionConfig {
            max_age_days: Some(30),
            max_item_count: None,
        })
        .unwrap();

    assert!(purged.is_empty(), "软删除条目在宽限期内不得被保留期清理硬删");
    assert!(repo.get_item_detail("soft-deleted").is_ok());
}

#[test]
fn test_hard_delete_records_sync_tombstone() {
    let (_f, repo) = create_test_repo();
    let item = create_item("doomed", 100.0, false);
    repo.save_item(&item, None).unwrap();

    repo.purge_item("doomed").unwrap();

    // 行已物理删除，但 7 天内墓碑仍随 pack 导出，防止对端复活
    let exported = repo.export_sync_items(None).unwrap();
    let ids: Vec<&str> = exported.iter().map(|i| i.id.as_str()).collect();
    assert!(ids.contains(&"doomed"), "硬删除必须留下同步墓碑");
    assert!(exported
        .iter()
        .any(|i| i.id == "doomed" && i.deleted_at.is_some()));
}
