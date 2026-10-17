use std::fs;
use tempfile::tempdir;

use nookclip_core::{
    clipboard::{
        egress::{prepare_batch_paste_payload, prepare_paste_payload},
        ingest::ingest_clipboard_snapshot,
    },
    crypto::CryptoEngine,
    error::CoreError,
    model::{IngestConfig, IngestOutcome, RawClipboardSnapshot},
    storage::repository::StorageRepository,
};

#[test]
fn test_clipboard_ingest_priority_and_edge_cases() {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("test.db");
    let key = [0x42u8; 32];
    let repo = StorageRepository::new(db_path.to_str().unwrap(), &key).unwrap();
    let crypto = CryptoEngine::new(&key).unwrap();
    let assets_dir = dir.path().join("assets");
    fs::create_dir_all(&assets_dir).unwrap();

    let config = IngestConfig {
        sensitive_protection_enabled: true,
        excluded_bundle_ids: vec!["com.blacklisted.app".to_string()],
        local_assets_dir: assets_dir.to_str().unwrap().to_string(),
        file_multi_title_template: None,
        default_image_title: "Image".to_string(),
        source_device_id: None,
        source_device_name: None,
        source_platform: None,
    };

    // 1. Concealed marker -> skip
    let concealed_snapshot = RawClipboardSnapshot {
        has_concealed_marker: true,
        plain_text: Some("password123".to_string()),
        ..Default::default()
    };
    let out = ingest_clipboard_snapshot(&repo, Some(&crypto), &concealed_snapshot, &config, None, None, 100.0).unwrap();
    assert_eq!(out, IngestOutcome::SkippedConcealed);

    // 2. Excluded app -> skip
    let excluded_snapshot = RawClipboardSnapshot {
        source_bundle_id: Some("com.blacklisted.app".to_string()),
        plain_text: Some("some copied text".to_string()),
        ..Default::default()
    };
    let out = ingest_clipboard_snapshot(&repo, Some(&crypto), &excluded_snapshot, &config, None, None, 100.0).unwrap();
    assert_eq!(out, IngestOutcome::SkippedExcludedApp);

    // 3. 1.5s internal paste guard -> skip
    let internal_snapshot = RawClipboardSnapshot {
        plain_text: Some("already pasted".to_string()),
        ..Default::default()
    };
    let out = ingest_clipboard_snapshot(&repo, Some(&crypto), &internal_snapshot, &config, Some("already pasted"), Some(99.0), 100.0).unwrap();
    assert_eq!(out, IngestOutcome::SkippedInternalPaste);

    // 4. File priority over text/url/image
    let test_file = dir.path().join("sample.txt");
    fs::write(&test_file, b"sample content").unwrap();
    let file_snapshot = RawClipboardSnapshot {
        file_paths: vec![test_file.to_str().unwrap().to_string()],
        plain_text: Some("sample text".to_string()),
        image_data: Some(vec![1, 2, 3]),
        ..Default::default()
    };
    let out = ingest_clipboard_snapshot(&repo, Some(&crypto), &file_snapshot, &config, None, None, 100.0).unwrap();
    match out {
        IngestOutcome::Saved { item } => {
            assert_eq!(item.item_type, "file");
            assert_eq!(item.title, "sample.txt");
        }
        _ => panic!("Expected Saved file"),
    }
    // 4.1 Windows-style backslash file paths extract file name cleanly across platforms
    let win_file_snapshot = RawClipboardSnapshot {
        file_paths: vec![r"C:\Users\Developer\Documents\report.pdf".to_string()],
        ..Default::default()
    };
    let out = ingest_clipboard_snapshot(&repo, Some(&crypto), &win_file_snapshot, &config, None, None, 100.5).unwrap();
    match out {
        IngestOutcome::Saved { item } => {
            assert_eq!(item.item_type, "file");
            assert_eq!(item.title, "report.pdf");
        }
        _ => panic!("Expected Saved Windows file"),
    }


    // 5. Sensitive URL -> encrypted and masked
    let sensitive_url = "https://example.com/callback?token=sk-proj-123456789012345678";
    let url_snapshot = RawClipboardSnapshot {
        plain_text: Some(sensitive_url.to_string()),
        ..Default::default()
    };
    let out = ingest_clipboard_snapshot(&repo, Some(&crypto), &url_snapshot, &config, None, None, 100.0).unwrap();
    match out {
        IngestOutcome::Saved { item } => {
            assert_eq!(item.item_type, "url");
            assert!(item.is_sensitive);
            assert!(item.summary.contains("••••"));
        }
        _ => panic!("Expected Saved sensitive URL"),
    }
}

#[test]
fn test_prepare_paste_payload_validation_and_batch() {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("test_paste.db");
    let key = [0x42u8; 32];
    let repo = StorageRepository::new(db_path.to_str().unwrap(), &key).unwrap();
    let crypto = CryptoEngine::new(&key).unwrap();
    let assets_dir = dir.path().join("assets");
    fs::create_dir_all(&assets_dir).unwrap();

    let config = IngestConfig {
        sensitive_protection_enabled: true,
        excluded_bundle_ids: Vec::new(),
        local_assets_dir: assets_dir.to_str().unwrap().to_string(),
        file_multi_title_template: None,
        default_image_title: "Image".to_string(),
        source_device_id: None,
        source_device_name: None,
        source_platform: None,
    };

    // Case 1: Plain text item
    let text_snapshot = RawClipboardSnapshot {
        plain_text: Some("Hello World".to_string()),
        ..Default::default()
    };
    let text_item = match ingest_clipboard_snapshot(&repo, Some(&crypto), &text_snapshot, &config, None, None, 10.0).unwrap() {
        IngestOutcome::Saved { item } => item,
        _ => panic!("Failed to save text"),
    };
    let payload = prepare_paste_payload(&repo, Some(&crypto), &text_item.id, false).unwrap();
    assert_eq!(payload.plain_text, Some("Hello World".to_string()));
    assert!(!payload.is_sensitive);

    // Case 2: Stale file -> Err(StaleFiles)
    let non_existent = dir.path().join("deleted_file.txt");
    let file_snapshot = RawClipboardSnapshot {
        file_paths: vec![non_existent.to_str().unwrap().to_string()],
        ..Default::default()
    };
    let file_item = match ingest_clipboard_snapshot(&repo, Some(&crypto), &file_snapshot, &config, None, None, 10.0).unwrap() {
        IngestOutcome::Saved { item } => item,
        _ => panic!("Failed to save file"),
    };
    let res = prepare_paste_payload(&repo, Some(&crypto), &file_item.id, false);
    match res {
        Err(CoreError::StaleFiles { missing_paths }) => {
            assert_eq!(missing_paths.len(), 1);
        }
        _ => panic!("Expected StaleFiles error, got {:?}", res),
    }

    // Case 3: Sensitive item -> revealPlainContent works
    let secret = "sk-live-secret-password-123456789";
    let secret_snapshot = RawClipboardSnapshot {
        plain_text: Some(secret.to_string()),
        ..Default::default()
    };
    let secret_item = match ingest_clipboard_snapshot(&repo, Some(&crypto), &secret_snapshot, &config, None, None, 10.0).unwrap() {
        IngestOutcome::Saved { item } => item,
        _ => panic!("Failed to save secret"),
    };
    let secret_payload = prepare_paste_payload(&repo, Some(&crypto), &secret_item.id, false).unwrap();
    assert_eq!(secret_payload.plain_text, Some(secret.to_string()));
    assert!(secret_payload.is_sensitive);

    // Case 4: Batch paste propagates sensitive flag (BUG-052)
    let batch = prepare_batch_paste_payload(&repo, Some(&crypto), &[text_item.id, secret_item.id], "\n---\n").unwrap();
    assert!(batch.is_sensitive);
    assert_eq!(batch.plain_text, Some(format!("Hello World\n---\n{secret}")));
}

#[test]
fn test_ingest_clipboard_snapshot_persists_now_ts_and_orders_newest_first() {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("test_timestamps.db");
    let key = [0x42u8; 32];
    let repo = StorageRepository::new(db_path.to_str().unwrap(), &key).unwrap();
    let crypto = CryptoEngine::new(&key).unwrap();
    let assets_dir = dir.path().join("assets");
    fs::create_dir_all(&assets_dir).unwrap();

    let config = IngestConfig {
        sensitive_protection_enabled: true,
        excluded_bundle_ids: Vec::new(),
        local_assets_dir: assets_dir.to_str().unwrap().to_string(),
        file_multi_title_template: None,
        default_image_title: "Image".to_string(),
        source_device_id: None,
        source_device_name: None,
        source_platform: None,
    };

    // 1. 先入库一条较早的历史记录 (t = 1_700_000_000.0)
    let older_ts = 1_700_000_000.0;
    let older_snap = RawClipboardSnapshot {
        plain_text: Some("older item".to_string()),
        ..Default::default()
    };
    let older_item = match ingest_clipboard_snapshot(&repo, Some(&crypto), &older_snap, &config, None, None, older_ts).unwrap() {
        IngestOutcome::Saved { item } => item,
        _ => panic!("Expected Saved older item"),
    };
    assert_eq!(older_item.created_at, older_ts);
    assert_eq!(older_item.last_used_at, older_ts);

    // 2. 再入库一条新复制的记录 (t = 1_760_000_000.0)
    let newer_ts = 1_760_000_000.0;
    let newer_snap = RawClipboardSnapshot {
        plain_text: Some("newly copied item".to_string()),
        ..Default::default()
    };
    let newer_item = match ingest_clipboard_snapshot(&repo, Some(&crypto), &newer_snap, &config, None, None, newer_ts).unwrap() {
        IngestOutcome::Saved { item } => item,
        _ => panic!("Expected Saved newer item"),
    };
    assert_eq!(newer_item.created_at, newer_ts);
    assert_eq!(newer_item.last_used_at, newer_ts);

    // 3. 分页查询结果中，新复制条目必须排在第一位（置于旧条目之上）
    let queried = repo.query_items(&nookclip_core::model::QueryFilter {
        limit: 10,
        ..Default::default()
    }).unwrap();
    assert_eq!(queried.len(), 2);
    assert_eq!(queried[0].id, newer_item.id, "新复制条目必须排在列表首位");

    // 4. 重复复制旧条目 (t = 1_760_000_500.0)：保留 created_at，刷新 last_used_at 并置顶
    let recopy_ts = 1_760_000_500.0;
    let recopied = match ingest_clipboard_snapshot(&repo, Some(&crypto), &older_snap, &config, None, None, recopy_ts).unwrap() {
        IngestOutcome::Saved { item } => item,
        _ => panic!("Expected Saved recopied item"),
    };
    assert_eq!(recopied.id, older_item.id);
    assert_eq!(recopied.created_at, older_ts);
    assert_eq!(recopied.last_used_at, recopy_ts);
    assert_eq!(recopied.copy_count, 2);
}
