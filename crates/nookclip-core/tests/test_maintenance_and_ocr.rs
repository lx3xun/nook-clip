use std::fs;
use tempfile::tempdir;

use nookclip_core::{
    maintenance::{commit_ocr_result, run_maintenance},
    model::{ClipItemSummary, MaintenanceConfig, RetentionConfig},
    storage::repository::StorageRepository,
};

#[test]
fn test_commit_ocr_result_masks_sensitive_api_key() {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("test_ocr.db");
    let key = [0x42u8; 32];
    let repo = StorageRepository::new(db_path.to_str().unwrap(), &key).unwrap();

    let item = ClipItemSummary {
        id: "item-ocr-1".to_string(),
        item_type: "image".to_string(),
        title: "Screenshot".to_string(),
        summary: "100x100".to_string(),
        created_at: 10.0,
        last_used_at: 10.0,
        copy_count: 1,
        favorite: false,
        source_app_bundle_id: None,
        source_app_name: None,
        source_device_id: None,
        source_device_name: None,
        source_platform: None,
        is_sensitive: false,
        deleted_at: None,
        payload_path: None,
        ocr_text: None,
        metadata_json: None,
        kind: "image".to_string(),
    };
    repo.save_item(&item, None).unwrap();

    // 1. 普通 OCR 文本 -> 原样落库
    let normal = commit_ocr_result(&repo, "item-ocr-1", "Invoice #12345").unwrap();
    assert_eq!(normal, Some("Invoice #12345".to_string()));
    let detail = repo.get_item_detail("item-ocr-1").unwrap();
    assert_eq!(detail.ocr_text, Some("Invoice #12345".to_string()));

    // 2. 包含敏感 API Key 的 OCR 文本 -> 掩码脱敏落库 (BUG-007)
    let secret_ocr = "My key is sk-live-123456789012345678";
    let masked = commit_ocr_result(&repo, "item-ocr-1", secret_ocr).unwrap();
    assert!(masked.is_some());
    let masked_text = masked.unwrap();
    assert!(!masked_text.contains("1234567890"));
    assert!(masked_text.contains("••••"));

    let detail_after = repo.get_item_detail("item-ocr-1").unwrap();
    assert_eq!(detail_after.ocr_text, Some(masked_text));
}

#[test]
fn test_run_maintenance_prunes_expired_and_sweeps_orphans() {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("test_maint.db");
    let key = [0x42u8; 32];
    let repo = StorageRepository::new(db_path.to_str().unwrap(), &key).unwrap();
    let assets_dir = dir.path().join("assets");
    fs::create_dir_all(&assets_dir).unwrap();

    // 播种旧条目
    let old_item = ClipItemSummary {
        id: "old-1".to_string(),
        item_type: "text".to_string(),
        title: "Old".to_string(),
        summary: "Old text".to_string(),
        created_at: 100.0,
        last_used_at: 100.0,
        copy_count: 1,
        favorite: false,
        source_app_bundle_id: None,
        source_app_name: None,
        source_device_id: None,
        source_device_name: None,
        source_platform: None,
        is_sensitive: false,
        deleted_at: None,
        payload_path: None,
        ocr_text: None,
        metadata_json: None,
        kind: "text".to_string(),
    };
    repo.save_item(&old_item, Some("Old text")).unwrap();

    // 创建孤儿文件
    let orphan_file = assets_dir.join("orphan.png");
    fs::write(&orphan_file, b"orphan").unwrap();

    let config = MaintenanceConfig {
        retention: RetentionConfig {
            max_age_days: Some(1),
            max_item_count: None,
        },
        max_disk_bytes: Some(1024 * 1024),
        orphan_min_age_secs: 0.0, // 立即清理
        local_assets_dir: Some(assets_dir.to_str().unwrap().to_string()),
    };

    let report = run_maintenance(&repo, &config).unwrap();
    assert!(report.pruned_expired_count >= 1);
    assert_eq!(report.swept_orphan_files, 1);
    assert!(!orphan_file.exists(), "孤儿资产必须被清扫");
}
