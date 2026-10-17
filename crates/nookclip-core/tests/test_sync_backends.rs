use tempfile::tempdir;

use nookclip_core::{
    model::ClipItemSummary,
    storage::repository::StorageRepository,
    sync::{
        backend::{LocalFsBackend, SyncStorageBackend},
        engine::SyncEngine,
    },
};

#[test]
fn test_local_fs_backend_roundtrip_and_assets() {
    let dir = tempdir().unwrap();
    let sync_dir = dir.path().join("sync");
    let backend = LocalFsBackend::new(&sync_dir);
    backend.ensure_layout().unwrap();

    // 1. Pack read/write atomic
    let pack_data = b"compressed-pack-bytes-12345";
    backend.write_device_pack_atomic("device-a", pack_data).unwrap();

    let list = backend.list_device_packs().unwrap();
    assert_eq!(list, vec!["device-a"]);

    let read_back = backend.read_device_pack("device-a").unwrap();
    assert_eq!(read_back, pack_data);

    // 2. Asset read/write atomic
    let asset_data = b"image-png-binary";
    assert!(!backend.has_asset("img1.png").unwrap());
    backend.write_asset_atomic("img1.png", asset_data).unwrap();
    assert!(backend.has_asset("img1.png").unwrap());
    assert_eq!(backend.read_asset("img1.png").unwrap(), asset_data);
}

#[test]
fn test_sync_engine_two_devices_local_backend() {
    let dir = tempdir().unwrap();
    let sync_dir = dir.path().join("cloud_sync");
    let key = [0x42u8; 32];

    let db_a = dir.path().join("dev_a.db");
    let repo_a = StorageRepository::new(db_a.to_str().unwrap(), &key).unwrap();
    let engine_a = SyncEngine::new(&sync_dir, "device-A".to_string(), None).unwrap();

    let db_b = dir.path().join("dev_b.db");
    let repo_b = StorageRepository::new(db_b.to_str().unwrap(), &key).unwrap();
    let engine_b = SyncEngine::new(&sync_dir, "device-B".to_string(), None).unwrap();

    // Device A saves an item
    let item = ClipItemSummary {
        id: "item-sync-1".to_string(),
        item_type: "text".to_string(),
        title: "Sync Test".to_string(),
        summary: "Sync payload".to_string(),
        created_at: 100.0,
        last_used_at: 100.0,
        copy_count: 1,
        favorite: false,
        source_app_bundle_id: None,
        source_app_name: None,
        is_sensitive: false,
        deleted_at: None,
        payload_path: None,
        ocr_text: None,
        metadata_json: None,
        kind: "text".to_string(),
    };
    repo_a.save_item(&item, Some("Sync payload")).unwrap();

    // Device A pushes
    let push_rep = engine_a.push(&repo_a).unwrap();
    assert_eq!(push_rep.pushed_count, 1);

    // Device B pulls
    let pull_rep = engine_b.pull(&repo_b).unwrap();
    assert_eq!(pull_rep.pulled_count, 1);

    let detail_b = repo_b.get_item_detail("item-sync-1").unwrap();
    assert_eq!(detail_b.raw_text, Some("Sync payload".to_string()));
}
