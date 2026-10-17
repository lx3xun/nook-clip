use nookclip_core::{
    model::ClipItemSummary,
    storage::StorageRepository,
    sync::{SyncEngine, SyncItemRecord},
};
use tempfile::tempdir;

#[test]
fn test_sync_engine_push_and_pull_reconciliation() {
    let sync_dir = tempdir().expect("sync dir");
    let local_dir = tempdir().expect("local dir");

    let repo_a_path = local_dir.path().join("repo_a.db");
    let repo_b_path = local_dir.path().join("repo_b.db");
    let key = [9u8; 32];

    let repo_a = StorageRepository::new(repo_a_path.to_str().unwrap(), &key).unwrap();
    let repo_b = StorageRepository::new(repo_b_path.to_str().unwrap(), &key).unwrap();

    let item_a = ClipItemSummary {
        id: "id-sync-item-a".to_string(),
        item_type: "text".to_string(),
        title: "From Machine A".to_string(),
        summary: "Important notes on A".to_string(),
        created_at: 100.0,
        last_used_at: 150.0,
        copy_count: 1,
        favorite: false,
        source_app_bundle_id: None,
        source_app_name: None,
        is_sensitive: false,
        deleted_at: None,
        ..Default::default()
    };
    repo_a.save_item(&item_a, Some("Important notes on A"))
        .unwrap();

    let sync_a = SyncEngine::new(sync_dir.path(), "device-a".to_string(), None).unwrap();
    let push_report = sync_a.push(&repo_a).unwrap();
    assert_eq!(push_report.pushed_count, 1);

    // Device B pulls Device A's pack
    let sync_b = SyncEngine::new(sync_dir.path(), "device-b".to_string(), None).unwrap();
    let pull_report = sync_b.pull(&repo_b).unwrap();
    assert_eq!(pull_report.pulled_count, 1);

    let detail_b = repo_b.get_item_detail("id-sync-item-a").unwrap();
    let list_b = repo_b
        .query_items(&nookclip_core::model::QueryFilter::default())
        .unwrap();
    assert_eq!(list_b[0].title, "From Machine A");
    assert_eq!(detail_b.raw_text, Some("Important notes on A".to_string()));

    // LWW test: Device B updates last_used_at to 300.0 with new title
    let item_b_update = SyncItemRecord {
        id: "id-sync-item-a".to_string(),
        item_type: "text".to_string(),
        title: "Updated by Machine B".to_string(),
        summary: "Important notes on A".to_string(),
        raw_text: Some("Important notes on A (edited)".to_string()),
        is_sensitive: false,
        is_favorite: true,
        created_at: 100.0,
        last_used_at: 300.0,
        // save_item 写入的本地 updated_at 是真实 now（~1.7e9），
        // 远端记录需更大的 updated_at 才能在 LWW 判新中胜出
        updated_at: 5_000_000_000.0,
        copy_count: 5,
        asset_file_name: None,
        deleted_at: None,
        source_app_bundle_id: None,
        source_app_name: None,
        source_device_id: None,
        source_device_name: None,
        source_platform: None,
    };
    repo_b.reconcile_sync_items(&[item_b_update], &Default::default()).unwrap();
    sync_b.push(&repo_b).unwrap();

    // Device A pulls from Device B
    sync_a.pull(&repo_a).unwrap();
    let detail_a = repo_a.get_item_detail("id-sync-item-a").unwrap();
    assert_eq!(detail_a.raw_text.as_deref(), Some("Important notes on A (edited)"));
    let list_a = repo_a
        .query_items(&nookclip_core::model::QueryFilter::default())
        .unwrap();
    assert_eq!(list_a[0].title, "Updated by Machine B");
    assert!(list_a[0].favorite);
    assert_eq!(list_a[0].last_used_at, 300.0);
}
#[test]
fn test_sync_engine_never_exports_sensitive_items() {
    let sync_dir = tempdir().expect("sync dir");
    let local_dir = tempdir().expect("local dir");

    let repo_a_path = local_dir.path().join("repo_a_sens.db");
    let repo_b_path = local_dir.path().join("repo_b_sens.db");
    let key = [9u8; 32];

    let repo_a = StorageRepository::new(repo_a_path.to_str().unwrap(), &key).unwrap();
    let repo_b = StorageRepository::new(repo_b_path.to_str().unwrap(), &key).unwrap();

    let secret_item = ClipItemSummary {
        id: "id-sync-secret".to_string(),
        item_type: "text".to_string(),
        title: "API Secret Key".to_string(),
        summary: "••••••••".to_string(),
        created_at: 100.0,
        last_used_at: 150.0,
        copy_count: 1,
        favorite: true,
        source_app_bundle_id: None,
        source_app_name: None,
        is_sensitive: true,
        deleted_at: None,
        ..Default::default()
    };
    repo_a.save_item(&secret_item, Some("sk-live-secret-token-12345"))
        .unwrap();

    // 安全不变量：敏感条目绝不进入同步包（pack 仅压缩不加密）
    let sync_a = SyncEngine::new(sync_dir.path(), "device-a".to_string(), None).unwrap();
    let push_rep = sync_a.push(&repo_a).unwrap();
    assert_eq!(push_rep.pushed_count, 0, "敏感条目不得随 pack 推送");

    // 对端拉取后不存在该条目
    let sync_b = SyncEngine::new(sync_dir.path(), "device-b".to_string(), None).unwrap();
    sync_b.pull(&repo_b).unwrap();
    assert!(repo_b.get_item_detail("id-sync-secret").is_err());
}

#[test]
fn test_sync_engine_pull_resilience_to_corrupt_pack() {
    let sync_dir = tempdir().expect("sync dir");
    let local_dir = tempdir().expect("local dir");
    let key = [9u8; 32];

    let repo_path = local_dir.path().join("repo_resilience.db");
    let repo = StorageRepository::new(repo_path.to_str().unwrap(), &key).unwrap();

    let devices_dir = sync_dir.path().join("devices");
    std::fs::create_dir_all(&devices_dir).unwrap();

    // 1. Write a corrupted pack file
    let corrupt_pack_path = devices_dir.join("corrupt_device.pack");
    std::fs::write(&corrupt_pack_path, b"not a valid zstd or msgpack payload").unwrap();

    // 2. Write a valid pack file for another device
    let valid_item = SyncItemRecord {
        id: "id-valid-device-item".to_string(),
        item_type: "text".to_string(),
        title: "Healthy Machine".to_string(),
        summary: "Healthy text".to_string(),
        raw_text: Some("Healthy text".to_string()),
        is_sensitive: false,
        is_favorite: false,
        created_at: 100.0,
        last_used_at: 100.0,
        updated_at: 100.0,
        copy_count: 1,
        asset_file_name: None,
        deleted_at: None,
        source_app_bundle_id: None,
        source_app_name: None,
        source_device_id: None,
        source_device_name: None,
        source_platform: None,
    };
    let valid_pack = nookclip_core::sync::DeviceSyncPack::new("healthy-device".to_string(), vec![valid_item]);
    let compressed = valid_pack.serialize_compressed().unwrap();
    std::fs::write(devices_dir.join("healthy-device.pack"), compressed).unwrap();

    // Pulling must NOT fail completely; it should skip corrupt pack and pull the valid one
    let sync = SyncEngine::new(sync_dir.path(), "my-device".to_string(), None).unwrap();
    let report = sync.pull(&repo).expect("pull must tolerate corrupt file");
    assert_eq!(report.pulled_count, 1);

    let detail = repo.get_item_detail("id-valid-device-item").unwrap();
    assert_eq!(detail.raw_text, Some("Healthy text".to_string()));
}

/// T010：墓碑随 pack 携带 7 天，超期墓碑不再导出推送
#[test]
fn test_sync_engine_tombstone_pruned_after_seven_days() {
    let dir = tempdir().expect("temp dir");
    let repo = StorageRepository::new(
        dir.path().join("repo.db").to_str().unwrap(),
        &[7u8; 32],
    )
    .unwrap();

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs_f64();

    let fresh_tombstone = ClipItemSummary {
        id: "id-fresh-tombstone".to_string(),
        item_type: "text".to_string(),
        title: "fresh".to_string(),
        summary: "fresh".to_string(),
        created_at: now - 100.0,
        last_used_at: now - 50.0,
        deleted_at: Some(now - 100.0),
        ..Default::default()
    };
    let stale_tombstone = ClipItemSummary {
        id: "id-stale-tombstone".to_string(),
        item_type: "text".to_string(),
        title: "stale".to_string(),
        summary: "stale".to_string(),
        created_at: now - 30.0 * 24.0 * 3600.0,
        last_used_at: now - 30.0 * 24.0 * 3600.0,
        deleted_at: Some(now - 8.0 * 24.0 * 3600.0),
        ..Default::default()
    };
    repo.save_item(&fresh_tombstone, Some("fresh")).unwrap();
    repo.save_item(&stale_tombstone, Some("stale")).unwrap();

    let exported = repo.export_sync_items(None).unwrap();
    let ids: Vec<&str> = exported.iter().map(|i| i.id.as_str()).collect();
    assert!(ids.contains(&"id-fresh-tombstone"), "7 天内墓碑必须保留");
    assert!(!ids.contains(&"id-stale-tombstone"), "超期墓碑必须被清理");
}

/// US1 场景3 / FR-002：图片载荷经云端 assets/ 附件池跨设备同步，
/// 设备 B 拉取后能在本地受管目录读回同样内容
#[test]
fn test_sync_engine_transfers_payload_assets() {
    let sync_dir = tempdir().expect("sync dir");
    let local_dir = tempdir().expect("local dir");
    let assets_a = tempdir().expect("assets a");
    let assets_b = tempdir().expect("assets b");
    let key = [9u8; 32];

    let repo_a = StorageRepository::new(
        local_dir.path().join("repo_a_asset.db").to_str().unwrap(),
        &key,
    )
    .unwrap();
    let repo_b = StorageRepository::new(
        local_dir.path().join("repo_b_asset.db").to_str().unwrap(),
        &key,
    )
    .unwrap();

    // 设备 A 存图片：content-addressed 落盘 + 条目引用 payload_path
    let image_data = b"fake-png-bytes".to_vec();
    let store_a = nookclip_core::storage::PayloadAssetStore::new(assets_a.path()).unwrap();
    let payload_path = store_a.save_payload_asset(&image_data, "png").unwrap();

    let item_a = ClipItemSummary {
        id: "id-sync-image".to_string(),
        item_type: "image".to_string(),
        title: "Screenshot".to_string(),
        summary: "Screenshot".to_string(),
        created_at: 100.0,
        last_used_at: 150.0,
        copy_count: 1,
        favorite: false,
        source_app_bundle_id: None,
        source_app_name: None,
        is_sensitive: false,
        deleted_at: None,
        payload_path: Some(payload_path),
        ..Default::default()
    };
    repo_a.save_item(&item_a, None).unwrap();

    let sync_a = SyncEngine::new(
        sync_dir.path(),
        "device-a".to_string(),
        Some(assets_a.path().to_path_buf()),
    )
    .unwrap();
    let push_report = sync_a.push(&repo_a).unwrap();
    assert_eq!(push_report.pushed_count, 1);
    assert_eq!(push_report.assets_transferred, 1, "载荷必须上传云端附件池");

    // 云端附件池出现 content-addressed 文件
    let cloud_assets: Vec<_> = std::fs::read_dir(sync_dir.path().join("assets"))
        .unwrap()
        .collect();
    assert_eq!(cloud_assets.len(), 1);

    // 设备 B 拉取：载荷导入本地受管目录，条目 payload_path 指向本地副本
    let sync_b = SyncEngine::new(
        sync_dir.path(),
        "device-b".to_string(),
        Some(assets_b.path().to_path_buf()),
    )
    .unwrap();
    let pull_report = sync_b.pull(&repo_b).unwrap();
    assert_eq!(pull_report.pulled_count, 1);
    assert_eq!(pull_report.assets_transferred, 1, "载荷必须导入设备 B 本地目录");

    let list_b = repo_b
        .query_items(&nookclip_core::model::QueryFilter::default())
        .unwrap();
    assert_eq!(list_b[0].id, "id-sync-image");
    let payload_b = list_b[0]
        .payload_path
        .clone()
        .expect("payload_path must be set on device B");
    assert!(
        payload_b.starts_with(assets_b.path().to_str().unwrap()),
        "载荷必须落在设备 B 的受管目录"
    );
    assert_eq!(
        std::fs::read(&payload_b).unwrap(),
        image_data,
        "设备 B 必须能读回图片内容"
    );
}

