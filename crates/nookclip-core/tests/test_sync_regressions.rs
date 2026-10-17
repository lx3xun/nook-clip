use nookclip_core::{
    exchange::{export_json, import_json, SensitiveExportMode},
    model::{ClipItemSummary, QueryFilter},
    storage::StorageRepository,
    sync::SyncItemRecord,
};
use tempfile::{tempdir, NamedTempFile};

fn text_item(id: &str, title: &str, summary: &str) -> ClipItemSummary {
    ClipItemSummary {
        id: id.to_string(),
        item_type: "text".to_string(),
        title: title.to_string(),
        summary: summary.to_string(),
        created_at: 100.0,
        last_used_at: 150.0,
        copy_count: 1,
        favorite: false,
        source_app_bundle_id: None,
        source_app_name: None,
        is_sensitive: false,
        deleted_at: None,
        ..Default::default()
    }
}

fn sync_record(id: &str, title: &str, updated_at: f64, deleted_at: Option<f64>) -> SyncItemRecord {
    SyncItemRecord {
        id: id.to_string(),
        item_type: "text".to_string(),
        title: title.to_string(),
        summary: format!("summary of {}", title),
        raw_text: Some(format!("body of {}", title)),
        is_sensitive: false,
        is_favorite: false,
        created_at: 100.0,
        last_used_at: 150.0,
        updated_at,
        copy_count: 1,
        asset_file_name: None,
        deleted_at,
        source_app_bundle_id: None,
        source_app_name: None,
        source_device_id: None,
        source_device_name: None,
        source_platform: None,
    }
}

fn item_ids(repo: &StorageRepository) -> Vec<String> {
    repo.query_items(&QueryFilter {
        include_deleted: true,
        ..Default::default()
    })
    .unwrap()
    .into_iter()
    .map(|i| i.id)
    .collect()
}

/// 墓碑复活：设备 A 硬删除条目 X 后，陈旧 pack 中仍活跃的 X 不得经 reconcile 复活；
/// remote_time 晚于墓碑时间的记录仍可插入（LWW：更新者胜）。
#[test]
fn tombstone_blocks_stale_pack_revival() {
    let dir = tempdir().unwrap();
    let repo = StorageRepository::new(
        dir.path().join("a.db").to_str().unwrap(),
        &[9u8; 32],
    )
    .unwrap();

    repo.save_item(&text_item("id-x", "Title X", "sum x"), Some("body x"))
        .unwrap();
    repo.purge_item("id-x").unwrap();
    assert!(!item_ids(&repo).contains(&"id-x".to_string()));

    // 陈旧 pack：活跃 X，remote_time（updated_at=200）早于墓碑时间（purge 时刻 now）
    repo.reconcile_sync_items(&[sync_record("id-x", "Title X", 200.0, None)], &Default::default())
        .unwrap();
    assert!(
        !item_ids(&repo).contains(&"id-x".to_string()),
        "stale pack must not revive a purged item"
    );

    // remote_time 晚于墓碑时间：允许重新插入
    let later_than_tombstone = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs_f64()
        + 1000.0;
    repo.reconcile_sync_items(
        &[sync_record("id-x", "Title X revived", later_than_tombstone, None)],
        &Default::default(),
    )
    .unwrap();
    assert!(item_ids(&repo).contains(&"id-x".to_string()));
}

/// FTS 错位：LWW 更新改标题后按新标题搜索命中、旧标题不命中；
/// 同步软删后不可搜索，恢复（deleted_at 置 NULL）后重建 FTS 可再搜索。
#[test]
fn fts_rebuilt_after_lww_update_delete_and_restore() {
    let dir = tempdir().unwrap();
    let repo = StorageRepository::new(
        dir.path().join("b.db").to_str().unwrap(),
        &[9u8; 32],
    )
    .unwrap();

    repo.save_item(&text_item("id-f", "Alpha Title", "Alpha summary"), Some("alpha body"))
        .unwrap();

    let search = |q: &str| -> Vec<String> {
        repo.query_items(&QueryFilter {
            search_query: Some(q.to_string()),
            ..Default::default()
        })
        .unwrap()
        .into_iter()
        .map(|i| i.id)
        .collect()
    };

    // LWW 更新：换标题
    repo.reconcile_sync_items(&[sync_record("id-f", "Beta Title", 5_000_000_000.0, None)], &Default::default())
        .unwrap();
    assert_eq!(search("Beta Title"), vec!["id-f".to_string()]);
    assert!(search("Alpha").is_empty(), "old title must not match after update");

    // 同步软删：FTS 行应删除
    repo.reconcile_sync_items(&[sync_record("id-f", "Beta Title", 5_000_000_100.0, Some(5_000_000_100.0))], &Default::default())
        .unwrap();
    assert!(search("Beta").is_empty(), "soft-deleted item must not be searchable");

    // 恢复（deleted_at 置 NULL）：FTS 行应重建
    repo.reconcile_sync_items(&[sync_record("id-f", "Beta Title", 5_000_000_200.0, None)], &Default::default())
        .unwrap();
    assert_eq!(search("Beta Title"), vec!["id-f".to_string()]);
}

/// 导入 updated_at 非零：导入后拉取旧远端记录（updated_at 更小）不覆盖本地标题。
#[test]
fn imported_item_updated_at_prevents_stale_remote_overwrite() {
    let file_src = NamedTempFile::new().unwrap();
    let file_dst = NamedTempFile::new().unwrap();
    let key = [4u8; 32];
    let repo_src = StorageRepository::new(file_src.path().to_str().unwrap(), &key).unwrap();
    let repo_dst = StorageRepository::new(file_dst.path().to_str().unwrap(), &key).unwrap();

    repo_src
        .save_item(&text_item("id-imp", "Imported Note", "imported summary"), Some("imported body"))
        .unwrap();
    let json = export_json(&repo_src, SensitiveExportMode::Plaintext).unwrap();
    let report = import_json(&repo_dst, &json).unwrap();
    assert_eq!(report.imported_count, 1);

    // 旧远端记录（updated_at 很小）不得覆盖刚导入的条目
    repo_dst
        .reconcile_sync_items(&[sync_record("id-imp", "Stale Remote", 200.0, None)], &Default::default())
        .unwrap();
    let items = repo_dst.query_items(&QueryFilter::default()).unwrap();
    assert_eq!(items[0].title, "Imported Note");
}

/// Masked 备份导入：敏感条目正文为掩码字面量，导入时跳过并计入 skipped_masked。
#[test]
fn masked_sensitive_export_skipped_on_import() {
    let file_src = NamedTempFile::new().unwrap();
    let file_dst = NamedTempFile::new().unwrap();
    let key = [7u8; 32];
    let repo_src = StorageRepository::new(file_src.path().to_str().unwrap(), &key).unwrap();
    let repo_dst = StorageRepository::new(file_dst.path().to_str().unwrap(), &key).unwrap();

    let mut secret = text_item("id-sec", "Secret Title", "••••••••");
    secret.is_sensitive = true;
    repo_src
        .save_item(&secret, Some("sk-abcdefghijklmnopqrstuvwxyz123456"))
        .unwrap();

    let json = export_json(&repo_src, SensitiveExportMode::Masked).unwrap();
    let report = import_json(&repo_dst, &json).unwrap();
    assert_eq!(report.skipped_masked, 1);
    assert_eq!(report.imported_count, 0);
    assert!(repo_dst.query_items(&QueryFilter::default()).unwrap().is_empty());
}

/// pull 遇到损坏 pack：记录到 failed_packs 且不影响其余设备合并。
#[test]
fn pull_collects_failed_packs_without_breaking_others() {
    use nookclip_core::sync::SyncEngine;

    let sync_dir = tempdir().unwrap();
    let local_dir = tempdir().unwrap();
    let key = [9u8; 32];

    let repo_b = StorageRepository::new(
        local_dir.path().join("b.db").to_str().unwrap(),
        &key,
    )
    .unwrap();

    // 设备 A push 一个合法 pack
    let repo_a = StorageRepository::new(
        local_dir.path().join("a.db").to_str().unwrap(),
        &key,
    )
    .unwrap();
    repo_a
        .save_item(&text_item("id-ok", "Healthy Item", "healthy summary"), Some("healthy body"))
        .unwrap();
    let sync_a = SyncEngine::new(sync_dir.path(), "device-a".to_string(), None).unwrap();
    sync_a.push(&repo_a).unwrap();

    // 设备 C 的损坏 pack
    let devices = sync_dir.path().join("devices");
    std::fs::write(devices.join("device-c.pack"), b"not-a-valid-pack").unwrap();

    let sync_b = SyncEngine::new(sync_dir.path(), "device-b".to_string(), None).unwrap();
    let report = sync_b.pull(&repo_b).unwrap();
    assert_eq!(report.pulled_count, 1, "healthy pack must still merge");
    assert_eq!(report.failed_packs.len(), 1);
    assert!(report.failed_packs[0].starts_with("device-c:"));
}

/// 回归 P1-4：收藏切换、取消收藏与标题修改必须刷新 updated_at，确保 LWW 同步到对端
#[test]
fn favorite_toggle_unfavorite_and_title_update_propagate_via_sync() {
    use nookclip_core::sync::SyncEngine;

    let sync_dir = tempdir().unwrap();
    let local_dir = tempdir().unwrap();
    let key = [5u8; 32];

    let repo_a = StorageRepository::new(local_dir.path().join("a.db").to_str().unwrap(), &key).unwrap();
    let repo_b = StorageRepository::new(local_dir.path().join("b.db").to_str().unwrap(), &key).unwrap();
    let sync_a = SyncEngine::new(sync_dir.path(), "device-a".to_string(), None).unwrap();
    let sync_b = SyncEngine::new(sync_dir.path(), "device-b".to_string(), None).unwrap();

    repo_a
        .save_item(&text_item("id-fav-sync", "Original Title", "body text"), Some("body text"))
        .unwrap();
    sync_a.push(&repo_a).unwrap();
    sync_b.pull(&repo_b).unwrap();

    // 1. 设备 A 收藏并重命名，推送后设备 B 拉取应同步生效
    std::thread::sleep(std::time::Duration::from_millis(5));
    repo_a.toggle_favorite("id-fav-sync").unwrap();
    repo_a.update_title("id-fav-sync", "Renamed On A").unwrap();
    sync_a.push(&repo_a).unwrap();
    sync_b.pull(&repo_b).unwrap();

    let b_items = repo_b.query_items(&QueryFilter::default()).unwrap();
    assert_eq!(b_items[0].title, "Renamed On A");
    assert!(b_items[0].favorite, "收藏状态必须经 LWW 同步到设备 B");

    // 2. 设备 A 取消收藏，推送后设备 B 拉取应同步取消收藏
    std::thread::sleep(std::time::Duration::from_millis(5));
    repo_a.toggle_favorite("id-fav-sync").unwrap();
    sync_a.push(&repo_a).unwrap();
    sync_b.pull(&repo_b).unwrap();

    let b_items_after = repo_b.query_items(&QueryFilter::default()).unwrap();
    assert!(!b_items_after[0].favorite, "取消收藏必须经 LWW 同步到设备 B");
}

/// 回归 P1-2：LWW 合并更新远端记录时，不得抹除本机已有的图片 OCR 与来源应用 FTS 索引
#[test]
fn reconcile_sync_items_preserves_local_ocr_and_source_app_in_fts() {
    let f = NamedTempFile::new().unwrap();
    let repo = StorageRepository::new(f.path().to_str().unwrap(), &[7u8; 32]).unwrap();

    let mut img = text_item("id-img-ocr", "Screenshot", "800x600");
    img.item_type = "image".to_string();
    img.source_app_name = Some("PreviewApp".to_string());
    img.ocr_text = Some("UniqueOCRKeyword2026".to_string());
    repo.save_item(&img, None).unwrap();

    // 远端仅更新了标题和收藏，LWW 胜出
    let mut remote = sync_record("id-img-ocr", "Updated Screenshot", 9_000_000_000.0, None);
    remote.item_type = "image".to_string();
    remote.summary = "800x600".to_string();
    remote.is_favorite = true;
    repo.reconcile_sync_items(&[remote], &Default::default()).unwrap();

    // 搜索本机原有的 OCR 关键词与来源应用仍必须命中
    let ocr_hits = repo
        .query_items(&QueryFilter {
            search_query: Some("UniqueOCRKeyword2026".to_string()),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(ocr_hits.len(), 1, "LWW 合并后本地 OCR 文本仍必须可被 FTS 搜索命中");

    let app_hits = repo
        .query_items(&QueryFilter {
            search_query: Some("PreviewApp".to_string()),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(app_hits.len(), 1, "LWW 合并后本地来源应用名仍必须可被 FTS 搜索命中");
}

/// 回归 P1-2：超过 2MB 的本地图片资产不上传至 iCloud 附件池
#[test]
fn sync_push_skips_assets_exceeding_two_megabytes() {
    use nookclip_core::storage::PayloadAssetStore;
    use nookclip_core::sync::SyncEngine;

    let sync_dir = tempdir().unwrap();
    let local_dir = tempdir().unwrap();
    let assets_dir = tempdir().unwrap();
    let repo = StorageRepository::new(local_dir.path().join("a.db").to_str().unwrap(), &[1u8; 32]).unwrap();
    let asset_store = PayloadAssetStore::new(assets_dir.path()).unwrap();

    let oversized = vec![0xABu8; (SyncEngine::MAX_SYNC_ASSET_BYTES as usize) + 1024];
    let path = asset_store.save_payload_asset(&oversized, "png").unwrap();

    let mut item = text_item("id-oversized", "Huge Image", "4000x3000");
    item.item_type = "image".to_string();
    item.payload_path = Some(path);
    repo.save_item(&item, None).unwrap();

    let sync = SyncEngine::new(
        sync_dir.path(),
        "device-a".to_string(),
        Some(assets_dir.path().to_path_buf()),
    )
    .unwrap();
    let report = sync.push(&repo).unwrap();
    assert_eq!(report.pushed_count, 1);
    assert_eq!(report.assets_transferred, 0, "超过 2MB 的资产不得上传到云端附件池");
}

/// 回归 P0-1：单条 ID 查询返回完整 raw_text，且 mark_used 不覆盖全文或加密密文
#[test]
fn single_id_query_and_mark_used_preserve_full_raw_text_and_ciphertext() {
    let f = NamedTempFile::new().unwrap();
    let repo = StorageRepository::new(f.path().to_str().unwrap(), &[3u8; 32]).unwrap();

    // 1. 同步/导入进入的长文本（summary 为 10 字摘要，raw_text 为 500 字全文）
    let full_body = "LongFullTextBody_".repeat(35);
    let mut rec = sync_record("id-long-sync", "Doc", 1_000.0, None);
    rec.summary = "ShortPrefx".to_string();
    rec.raw_text = Some(full_body.clone());
    repo.reconcile_sync_items(&[rec], &Default::default()).unwrap();

    // 单条 ID 查询必须返回完整 raw_text
    let single = repo
        .query_items(&QueryFilter {
            id: Some("id-long-sync".to_string()),
            limit: 1,
            ..Default::default()
        })
        .unwrap();
    assert_eq!(single[0].summary, full_body);

    // mark_used 后 copy_count +1，且全文仍完整保留
    let marked = repo.mark_used("id-long-sync", 2_000.0).unwrap();
    assert_eq!(marked.copy_count, 2);
    let detail = repo.get_item_detail("id-long-sync").unwrap();
    assert_eq!(detail.raw_text.as_deref(), Some(full_body.as_str()));

    // 2. 敏感条目 mark_used 不得破坏加密明文
    let mut sens = text_item("id-sens-mark", "", "sk-••••5678");
    sens.is_sensitive = true;
    repo.save_item(&sens, Some("sk-real-secret-plaintext-12345678")).unwrap();
    repo.mark_used("id-sens-mark", 3_000.0).unwrap();
    let sens_detail = repo.get_item_detail("id-sens-mark").unwrap();
    assert_eq!(sens_detail.raw_text.as_deref(), Some("sk-real-secret-plaintext-12345678"));
}
