use nookclip_core::clipboard::ingest::{ingest_clipboard_snapshot, NOOK_CLIP_NAMESPACE};
use nookclip_core::crypto::CryptoEngine;
use nookclip_core::model::{ClipItemSummary, IngestConfig, IngestOutcome, QueryFilter, RawClipboardSnapshot};
use nookclip_core::storage::repository::StorageRepository;
use nookclip_core::sync::{
    create_manifest, is_encrypted_envelope, verify_manifest, SyncEngine,
};
use tempfile::tempdir;

#[test]
fn test_crlf_normalization_produces_identical_deterministic_id() {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("test_deterministic.db");
    let key = [0x42u8; 32];
    let repo = StorageRepository::new(db_path.to_str().unwrap(), &key).unwrap();

    let config = IngestConfig {
        sensitive_protection_enabled: true,
        excluded_bundle_ids: Vec::new(),
        local_assets_dir: String::new(),
        file_multi_title_template: None,
        default_image_title: "Image".to_string(),
        source_device_id: None,
        source_device_name: None,
        source_platform: None,
    };

    // Windows CRLF style text
    let win_snapshot = RawClipboardSnapshot {
        plain_text: Some("line1\r\nline2\r\nline3".to_string()),
        source_app_name: Some("VS Code".to_string()),
        source_platform: Some("windows".to_string()),
        ..Default::default()
    };
    let outcome_win = ingest_clipboard_snapshot(&repo, None, &win_snapshot, &config, None, None, 100.0).unwrap();
    let id_win = match outcome_win {
        IngestOutcome::Saved { item } => item.id,
        _ => panic!("Expected saved"),
    };

    // Expected UUIDv5
    let expected_payload = format!("text\0{}", "line1\nline2\nline3");
    let expected_id = uuid::Uuid::new_v5(&NOOK_CLIP_NAMESPACE, expected_payload.as_bytes())
        .to_string()
        .to_uppercase();
    assert_eq!(id_win, expected_id, "Windows CRLF must normalize to canonical UUIDv5");

    // macOS LF style text
    let mac_snapshot = RawClipboardSnapshot {
        plain_text: Some("line1\nline2\nline3".to_string()),
        source_app_name: Some("Xcode".to_string()),
        source_platform: Some("macos".to_string()),
        ..Default::default()
    };
    let outcome_mac = ingest_clipboard_snapshot(&repo, None, &mac_snapshot, &config, None, None, 200.0).unwrap();
    let id_mac = match outcome_mac {
        IngestOutcome::Saved { item } => item.id,
        _ => panic!("Expected saved"),
    };

    assert_eq!(id_win, id_mac, "CRLF and LF must produce the identical deterministic ID");

    // Must be updated in place (copy count = 2, last_used_at = 200.0)
    let items = repo.query_items(&QueryFilter { id: Some(id_mac), ..Default::default() }).unwrap();
    let item = &items[0];
    assert_eq!(item.copy_count, 2);
    assert_eq!(item.last_used_at, 200.0);
}

#[test]
fn test_sensitive_items_use_random_uuid_v4_never_deterministic() {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("test_sensitive_uuid.db");
    let key = [0x42u8; 32];
    let repo = StorageRepository::new(db_path.to_str().unwrap(), &key).unwrap();
    let crypto = CryptoEngine::new(&key).unwrap();

    let config = IngestConfig {
        sensitive_protection_enabled: true,
        excluded_bundle_ids: Vec::new(),
        local_assets_dir: String::new(),
        file_multi_title_template: None,
        default_image_title: "Image".to_string(),
        source_device_id: None,
        source_device_name: None,
        source_platform: None,
    };

    let secret = "sk-live-secret-openai-token-11223344556677889900";
    let snap1 = RawClipboardSnapshot {
        plain_text: Some(secret.to_string()),
        ..Default::default()
    };
    let outcome1 = ingest_clipboard_snapshot(&repo, Some(&crypto), &snap1, &config, None, None, 100.0).unwrap();
    let id1 = match outcome1 {
        IngestOutcome::Saved { item } => item.id,
        _ => panic!("Expected saved"),
    };

    let snap2 = RawClipboardSnapshot {
        plain_text: Some(secret.to_string()),
        ..Default::default()
    };
    let outcome2 = ingest_clipboard_snapshot(&repo, Some(&crypto), &snap2, &config, None, None, 200.0).unwrap();
    let id2 = match outcome2 {
        IngestOutcome::Saved { item } => item.id,
        _ => panic!("Expected saved"),
    };

    assert_ne!(id1, id2, "Sensitive items MUST use random UUIDs to prevent rainbow table attacks");
}

#[test]
fn test_sliding_window_export_limits_to_500_plus_favorites() {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("test_window.db");
    let key = [0x42u8; 32];
    let repo = StorageRepository::new(db_path.to_str().unwrap(), &key).unwrap();

    // Insert 600 items: items 0..500 are normal, item 550 is favorited
    for i in 0..600 {
        let is_fav = i == 550;
        let item = ClipItemSummary {
            id: format!("item-{i:04}"),
            item_type: "text".to_string(),
            title: format!("Title {i}"),
            summary: format!("Summary {i}"),
            created_at: i as f64,
            last_used_at: i as f64,
            copy_count: 1,
            favorite: is_fav,
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
        repo.save_item(&item, None).unwrap();
    }

    // Default export window is 500 active + favorites
    let exported = repo.export_sync_items(None).unwrap();
    // Top 500 items are i=100..599. Item 550 is in top 500 anyway, so count is 500.
    assert_eq!(exported.len(), 500);

    // If an older item outside the top 500 is favorited (e.g. i=50):
    let old_fav = ClipItemSummary {
        id: "item-0050".to_string(),
        item_type: "text".to_string(),
        title: "Title 50".to_string(),
        summary: "Summary 50".to_string(),
        created_at: 50.0,
        last_used_at: 50.0,
        copy_count: 1,
        favorite: true,
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
    repo.save_item(&old_fav, None).unwrap();

    let exported_with_fav = repo.export_sync_items(None).unwrap();
    // 500 from top + 1 older favorite = 501
    assert_eq!(exported_with_fav.len(), 501);
    assert!(exported_with_fav.iter().any(|item| item.id == "item-0050"));
}

#[test]
fn test_sync_cursors_and_fingerprint_short_circuit() {
    let dir = tempdir().unwrap();
    let sync_dir = dir.path().join("cloud_sync");
    let key = [0x42u8; 32];

    let db_a = dir.path().join("dev_a.db");
    let repo_a = StorageRepository::new(db_a.to_str().unwrap(), &key).unwrap();
    let engine_a = SyncEngine::new(&sync_dir, "device-A".to_string(), None).unwrap();

    let db_b = dir.path().join("dev_b.db");
    let repo_b = StorageRepository::new(db_b.to_str().unwrap(), &key).unwrap();
    let engine_b = SyncEngine::new(&sync_dir, "device-B".to_string(), None).unwrap();

    // 1. Device A pushes item
    let item = ClipItemSummary {
        id: "item-cursor-1".to_string(),
        item_type: "text".to_string(),
        title: "Cursor Test".to_string(),
        summary: "Cursor text".to_string(),
        created_at: 100.0,
        last_used_at: 100.0,
        copy_count: 1,
        favorite: false,
        source_app_bundle_id: None,
        source_app_name: None,
        source_device_id: Some("device-A".to_string()),
        source_device_name: Some("MacBook".to_string()),
        source_platform: Some("macos".to_string()),
        is_sensitive: false,
        deleted_at: None,
        payload_path: None,
        ocr_text: None,
        metadata_json: None,
        kind: "text".to_string(),
    };
    repo_a.save_item(&item, None).unwrap();
    let push_rep = engine_a.push(&repo_a).unwrap();
    assert_eq!(push_rep.pushed_count, 1);

    // 2. Device B pulls for the first time -> pulls 1 item and sets cursor
    let pull_rep1 = engine_b.pull(&repo_b).unwrap();
    assert_eq!(pull_rep1.pulled_count, 1);
    let cursor = repo_b.get_sync_cursor("device-A").unwrap();
    assert!(cursor.is_some(), "Cursor must be saved after pull");

    // 3. Device B pulls again immediately -> remote pack unchanged, pulls 0 items (short-circuited)
    let pull_rep2 = engine_b.pull(&repo_b).unwrap();
    assert_eq!(pull_rep2.pulled_count, 0, "Unchanged pack must be skipped via cursor");
}

#[test]
fn test_e2ee_passphrase_sync_roundtrip_between_devices() {
    let dir = tempdir().unwrap();
    let sync_dir = dir.path().join("cloud_sync");
    let key = [0x42u8; 32];
    let passphrase = "correct-horse-battery-staple-2026";

    // Setup backend and manifest
    let (manifest, sync_key) = create_manifest(passphrase).unwrap();

    let db_a = dir.path().join("dev_a.db");
    let repo_a = StorageRepository::new(db_a.to_str().unwrap(), &key).unwrap();
    let engine_a = SyncEngine::new(&sync_dir, "device-A".to_string(), None)
        .unwrap()
        .with_encryption(Some(sync_key), true);

    let db_b = dir.path().join("dev_b.db");
    let repo_b = StorageRepository::new(db_b.to_str().unwrap(), &key).unwrap();

    // Verify passphrase on device B
    let sync_key_b = verify_manifest(&manifest, passphrase).unwrap();
    assert_eq!(sync_key, sync_key_b);

    let engine_b = SyncEngine::new(&sync_dir, "device-B".to_string(), None)
        .unwrap()
        .with_encryption(Some(sync_key_b), true);

    // Device A pushes item (encrypted with NCENC1)
    let item = ClipItemSummary {
        id: "item-e2ee-1".to_string(),
        item_type: "text".to_string(),
        title: "Confidential Note".to_string(),
        summary: "Super secret note".to_string(),
        created_at: 100.0,
        last_used_at: 100.0,
        copy_count: 1,
        favorite: false,
        source_app_bundle_id: None,
        source_app_name: None,
        source_device_id: Some("device-A".to_string()),
        source_device_name: Some("iPhone".to_string()),
        source_platform: Some("ios".to_string()),
        is_sensitive: false,
        deleted_at: None,
        payload_path: None,
        ocr_text: None,
        metadata_json: None,
        kind: "text".to_string(),
    };
    repo_a.save_item(&item, None).unwrap();
    engine_a.push(&repo_a).unwrap();

    // Inspect the written pack file on disk: MUST start with NCENC1 magic!
    let pack_path = sync_dir.join("devices").join("device-A.pack");
    let raw_bytes = std::fs::read(&pack_path).unwrap();
    assert!(is_encrypted_envelope(&raw_bytes), "Pack on disk MUST be NCENC1 encrypted");

    // Device B with correct key pulls and decrypts cleanly
    let report_b = engine_b.pull(&repo_b).unwrap();
    assert_eq!(report_b.pulled_count, 1);
    let items_b = repo_b.query_items(&QueryFilter::default()).unwrap();
    assert_eq!(items_b[0].title, "Confidential Note");
    assert_eq!(items_b[0].source_device_name, Some("iPhone".to_string()));
    assert_eq!(items_b[0].source_platform, Some("ios".to_string()));

    // An unauthenticated device without passphrase MUST fail to decrypt
    let engine_unauth = SyncEngine::new(&sync_dir, "device-C".to_string(), None).unwrap();
    let db_c = dir.path().join("dev_c.db");
    let repo_c = StorageRepository::new(db_c.to_str().unwrap(), &key).unwrap();
    let report_unauth = engine_unauth.pull(&repo_c).unwrap();
    assert_eq!(report_unauth.pulled_count, 0);
    assert!(!report_unauth.failed_packs.is_empty(), "Unauthenticated pull must report failed pack");
}

#[test]
fn test_sensitive_item_sync_preserves_plaintext_and_respects_allow_sensitive_on_pull() {
    let dir = tempdir().unwrap();
    let sync_dir = dir.path().join("cloud_sync_sens");
    let key_a = [0x11u8; 32];
    let key_b = [0x22u8; 32];
    let key_c = [0x33u8; 32];
    let passphrase = "sensitive-sync-passphrase";
    let (_, sync_key) = create_manifest(passphrase).unwrap();

    let db_a = dir.path().join("dev_a.db");
    let repo_a = StorageRepository::new(db_a.to_str().unwrap(), &key_a).unwrap();
    let mut engine_a = SyncEngine::new(&sync_dir, "device-A".to_string(), None)
        .unwrap()
        .with_encryption(Some(sync_key), true);
    engine_a.set_allow_sensitive(true);

    let secret_item = ClipItemSummary {
        id: "sens-item-1".to_string(),
        item_type: "text".to_string(),
        title: "API Token".to_string(),
        summary: "sk-••••1234".to_string(),
        created_at: 100.0,
        last_used_at: 100.0,
        copy_count: 1,
        favorite: false,
        source_app_bundle_id: None,
        source_app_name: None,
        source_device_id: Some("device-A".to_string()),
        source_device_name: Some("Mac".to_string()),
        source_platform: Some("macos".to_string()),
        is_sensitive: true,
        deleted_at: None,
        payload_path: None,
        ocr_text: None,
        metadata_json: None,
        kind: "text".to_string(),
    };
    repo_a
        .save_item(&secret_item, Some("sk-secret-full-plaintext-1234"))
        .unwrap();
    engine_a.push(&repo_a).unwrap();

    // Device B allows sensitive sync -> receives decrypted plaintext re-encrypted with key_b
    let db_b = dir.path().join("dev_b.db");
    let repo_b = StorageRepository::new(db_b.to_str().unwrap(), &key_b).unwrap();
    let mut engine_b = SyncEngine::new(&sync_dir, "device-B".to_string(), None)
        .unwrap()
        .with_encryption(Some(sync_key), true);
    engine_b.set_allow_sensitive(true);
    let rep_b = engine_b.pull(&repo_b).unwrap();
    assert_eq!(rep_b.pulled_count, 1);
    let detail_b = repo_b.get_item_detail("sens-item-1").unwrap();
    assert_eq!(
        detail_b.raw_text.as_deref(),
        Some("sk-secret-full-plaintext-1234")
    );

    // Device C has allow_sensitive = false -> skips pulling sensitive items
    let db_c = dir.path().join("dev_c.db");
    let repo_c = StorageRepository::new(db_c.to_str().unwrap(), &key_c).unwrap();
    let mut engine_c = SyncEngine::new(&sync_dir, "device-C".to_string(), None)
        .unwrap()
        .with_encryption(Some(sync_key), false);
    engine_c.set_allow_sensitive(false);
    let rep_c = engine_c.pull(&repo_c).unwrap();
    assert_eq!(rep_c.pulled_count, 0);
    assert!(repo_c.query_items(&QueryFilter::default()).unwrap().is_empty());
}
