use nookclip_core::{
    model::{ClipItemSummary, QueryFilter, RetentionConfig},
    storage::StorageRepository,
    sync::SyncItemRecord,
};
use std::collections::HashMap;
use tempfile::NamedTempFile;

fn repo() -> (NamedTempFile, StorageRepository) {
    let f = NamedTempFile::new().unwrap();
    let repo = StorageRepository::new(f.path().to_str().unwrap(), &[3u8; 32]).unwrap();
    (f, repo)
}

fn text_item(id: &str, summary: &str, ts: f64) -> ClipItemSummary {
    ClipItemSummary {
        id: id.to_string(),
        item_type: "text".to_string(),
        title: format!("title of {summary}"),
        summary: summary.to_string(),
        created_at: ts,
        last_used_at: ts,
        copy_count: 1,
        ..Default::default()
    }
}

fn record(id: &str, summary: &str, updated_at: f64, deleted_at: Option<f64>) -> SyncItemRecord {
    SyncItemRecord {
        id: id.to_string(),
        item_type: "text".to_string(),
        title: format!("title of {summary}"),
        summary: summary.to_string(),
        raw_text: Some(summary.to_string()),
        is_sensitive: false,
        is_favorite: false,
        created_at: 100.0,
        last_used_at: 100.0,
        updated_at,
        favorite_updated_at: 0.0,
        copy_count: 1,
        asset_file_name: None,
        deleted_at,
        source_app_bundle_id: None,
        source_app_name: None,
        source_device_id: None,
        source_device_name: None,
        source_platform: None,
        tags: Vec::new(),
        tags_updated_at: 0.0,
    }
}

fn search(repo: &StorageRepository, q: &str) -> Vec<String> {
    repo.query_items(&QueryFilter {
        search_query: Some(q.to_string()),
        ..Default::default()
    })
    .unwrap()
    .into_iter()
    .map(|i| i.id)
    .collect()
}

fn favorite_of(f: &NamedTempFile, id: &str) -> bool {
    let conn = rusqlite::Connection::open(f.path()).unwrap();
    conn.query_row("SELECT favorite FROM clip_items WHERE id = ?1", [id], |r| {
        r.get::<_, i64>(0)
    })
    .unwrap()
        == 1
}

fn updated_at_of(f: &NamedTempFile, id: &str) -> f64 {
    let conn = rusqlite::Connection::open(f.path()).unwrap();
    conn.query_row("SELECT updated_at FROM clip_items WHERE id = ?1", [id], |r| {
        r.get::<_, f64>(0)
    })
    .unwrap()
}

fn deleted_at_of(f: &NamedTempFile, id: &str) -> Option<f64> {
    let conn = rusqlite::Connection::open(f.path()).unwrap();
    conn.query_row("SELECT deleted_at FROM clip_items WHERE id = ?1", [id], |r| {
        r.get::<_, Option<f64>>(0)
    })
    .unwrap()
}

/// P1 回归：一次「粘贴」不得回滚另一台设备上的收藏。
///
/// 旧实现 mark_used 会推进 updated_at，对账再以 updated_at 做整行 LWW，
/// 于是「B 收藏 → A 粘贴 → B 拉取」会把 B 的收藏静默改回 false。
#[test]
fn paste_on_peer_does_not_revert_favorite() {
    let (f, repo) = repo();
    repo.save_item(&text_item("fav-1", "fav content", 100.0), Some("fav content"))
        .unwrap();
    repo.toggle_favorite("fav-1").unwrap();
    assert!(favorite_of(&f, "fav-1"));

    // A 设备粘贴过这条：mark_used 只动 last_used_at / copy_count
    let before = updated_at_of(&f, "fav-1");
    repo.mark_used("fav-1", 9_000.0).unwrap();
    assert_eq!(
        updated_at_of(&f, "fav-1"),
        before,
        "粘贴不得推进元数据判新时间戳"
    );

    // 对端记录：从未收藏，但 updated_at 比本地更新（它刚粘贴过）
    let mut remote = record("fav-1", "fav content", 9_100.0, None);
    remote.last_used_at = 9_100.0;
    remote.copy_count = 2;
    let merged = repo
        .reconcile_sync_items(&[remote], &HashMap::new())
        .unwrap();
    assert_eq!(merged, 1, "单调字段（last_used_at/copy_count）仍应合并");
    assert!(
        favorite_of(&f, "fav-1"),
        "对端粘贴不得回滚本地收藏"
    );
    let item = repo
        .query_items(&QueryFilter {
            id: Some("fav-1".to_string()),
            ..Default::default()
        })
        .unwrap()
        .remove(0);
    assert_eq!(item.last_used_at, 9_100.0, "跨端置顶仍须生效");
}

/// 反向：对端显式取消收藏必须能同步过来（收藏时钟独立后仍要传播）。
#[test]
fn remote_unfavorite_still_propagates() {
    let (f, repo) = repo();
    repo.save_item(&text_item("fav-2", "body two", 100.0), Some("body two"))
        .unwrap();
    repo.toggle_favorite("fav-2").unwrap();
    assert!(favorite_of(&f, "fav-2"));

    let mut remote = record("fav-2", "body two", 200.0, None);
    remote.is_favorite = false;
    remote.favorite_updated_at = 5_000_000_000.0; // 远端取消收藏时间更新
    repo.reconcile_sync_items(&[remote], &HashMap::new())
        .unwrap();
    assert!(!favorite_of(&f, "fav-2"), "远端更新的取消收藏必须生效");
}

/// P1 回归：远端删除后本地又粘贴过 → 保留本地（data-model §3 冲突矩阵）。
#[test]
fn local_use_after_remote_delete_keeps_item() {
    let (f, repo) = repo();
    repo.save_item(&text_item("del-1", "keep me", 1_000.0), Some("keep me"))
        .unwrap();
    // 本地在 t=2000 用过；远端在 t=1500 删除
    repo.mark_used("del-1", 2_000.0).unwrap();
    let remote = record("del-1", "keep me", 1_500.0, Some(1_500.0));
    repo.reconcile_sync_items(&[remote], &HashMap::new())
        .unwrap();
    assert!(
        deleted_at_of(&f, "del-1").is_none(),
        "远端删除早于本地使用时间时必须保留本地条目"
    );

    // 反过来：远端删除晚于本地使用 → 采纳删除
    let remote_later = record("del-1", "keep me", 5_000.0, Some(5_000.0));
    repo.reconcile_sync_items(&[remote_later], &HashMap::new())
        .unwrap();
    assert!(deleted_at_of(&f, "del-1").is_some(), "更新的远端删除必须被采纳");
}

/// P2 回归：同步删除后从回收站恢复，条目必须重新可搜索。
///
/// 旧实现 restore_deleted 只把 deleted_at 置 NULL，不同步重建 FTS 行，
/// 于是「远端删除 → 恢复」的条目回到列表却永远搜不到。
#[test]
fn restore_after_sync_delete_restores_searchability() {
    let (_f, repo) = repo();
    repo.save_item(&text_item("del-2", "unique keyword zebra", 1_000.0), Some("unique keyword zebra"))
        .unwrap();
    assert_eq!(search(&repo, "zebra"), vec!["del-2".to_string()]);

    // 远端软删（对账会删掉 FTS 行）
    let remote = record("del-2", "unique keyword zebra", 5_000.0, Some(5_000.0));
    repo.reconcile_sync_items(&[remote], &HashMap::new())
        .unwrap();
    assert!(search(&repo, "zebra").is_empty(), "软删后不得可搜索");

    // 用户从回收站恢复
    repo.restore_deleted("del-2").unwrap();
    assert_eq!(
        search(&repo, "zebra"),
        vec!["del-2".to_string()],
        "从回收站恢复后必须重建 FTS 行"
    );
}

/// P2 回归：对端硬删除产生的纯墓碑不得在对端插入空字段幽灵行。
#[test]
fn tombstone_only_record_does_not_create_ghost_row() {
    let (f, repo) = repo();
    let ghost = SyncItemRecord {
        id: "ghost-1".to_string(),
        item_type: String::new(),
        title: String::new(),
        summary: String::new(),
        raw_text: None,
        is_sensitive: false,
        is_favorite: false,
        created_at: 5_000.0,
        last_used_at: 5_000.0,
        updated_at: 5_000.0,
        favorite_updated_at: 0.0,
        copy_count: 0,
        asset_file_name: None,
        deleted_at: Some(5_000.0),
        source_app_bundle_id: None,
        source_app_name: None,
        source_device_id: None,
        source_device_name: None,
        source_platform: None,
        tags: Vec::new(),
        tags_updated_at: 0.0,
    };
    repo.reconcile_sync_items(&[ghost], &HashMap::new()).unwrap();

    let conn = rusqlite::Connection::open(f.path()).unwrap();
    let rows: i64 = conn
        .query_row("SELECT COUNT(*) FROM clip_items WHERE id = 'ghost-1'", [], |r| r.get(0))
        .unwrap();
    assert_eq!(rows, 0, "纯墓碑不得插入空字段幽灵行");
    let tombstones: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM sync_tombstones WHERE id = 'ghost-1'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(tombstones, 1, "纯墓碑必须落库，防止后续陈旧 pack 复活该 id");
}

/// P2 回归：内容去重命中回收站行时复用该行（清 deleted_at），
/// 不新建第二行——否则「恢复回收站条目」会得到两条同内容记录。
#[test]
fn recopying_trashed_content_reuses_the_trashed_row() {
    let (_f, repo) = repo();
    repo.save_item(&text_item("trash-1", "dup body", 1_000.0), Some("dup body"))
        .unwrap();
    repo.soft_delete("trash-1").unwrap();

    // 再次复制同一内容，捕获层会生成新 id
    let saved = repo
        .save_item(&text_item("trash-1-new", "dup body", 2_000.0), Some("dup body"))
        .unwrap();
    assert_eq!(saved.id, "trash-1", "应复用回收站中的同内容行");

    let active = repo
        .query_items(&QueryFilter::default())
        .unwrap()
        .into_iter()
        .filter(|i| i.summary == "dup body")
        .count();
    assert_eq!(active, 1, "同内容在活跃列表中只能有一行");
    assert_eq!(saved.copy_count, 2, "复用行时累计次数递增");
}

/// P3 回归：磁盘限额驱逐在删除前复核收藏状态，
/// 不物理删除扫描窗口内刚被收藏的条目。
#[test]
fn disk_limit_eviction_rechecks_favorite_before_delete() {
    let dir = tempfile::tempdir().unwrap();
    let db = dir.path().join("evict.db");
    let assets = dir.path().join("assets");
    std::fs::create_dir_all(&assets).unwrap();
    let repo = StorageRepository::new(db.to_str().unwrap(), &[4u8; 32]).unwrap();
    repo.set_assets_dir(Some(&assets));

    let store = nookclip_core::storage::PayloadAssetStore::new(&assets).unwrap();
    for i in 0..3 {
        let payload = store
            .save_payload_asset(format!("blob-{i}").as_bytes(), "png")
            .unwrap();
        let mut item = ClipItemSummary {
            id: format!("img-{i}"),
            item_type: "image".to_string(),
            title: format!("img {i}"),
            summary: format!("img {i}"),
            created_at: 1.0 + i as f64,
            last_used_at: 1.0 + i as f64,
            copy_count: 1,
            payload_path: Some(payload),
            ..Default::default()
        };
        item.kind = "image".to_string();
        repo.save_item(&item, None).unwrap();
    }
    // 最久未用的那条在驱逐前被收藏
    repo.toggle_favorite("img-0").unwrap();

    let evicted = repo
        .enforce_disk_limit(assets.to_str().unwrap(), 1)
        .unwrap();
    let evicted_ids: Vec<&str> = evicted.iter().map(|r| r.id.as_str()).collect();
    assert!(
        !evicted_ids.contains(&"img-0"),
        "扫描后新收藏的条目不得被驱逐，实际 {:?}",
        evicted_ids
    );
    assert!(
        repo.query_items(&QueryFilter {
            id: Some("img-0".to_string()),
            ..Default::default()
        })
        .unwrap()
        .len()
            == 1,
        "收藏条目必须仍在库中"
    );
}

/// P2 回归：user_version 只升不降。
/// 缺列回填分支不得把已是 v6 的库写回 v4。
#[test]
fn migration_never_lowers_user_version() {
    let f = NamedTempFile::new().unwrap();
    let path = f.path().to_str().unwrap().to_string();
    {
        let repo = StorageRepository::new(&path, &[6u8; 32]).unwrap();
        repo.save_item(&text_item("v6-1", "body", 1.0), Some("body")).unwrap();
    }
    let before: i64 = {
        let conn = rusqlite::Connection::open(&path).unwrap();
        conn.query_row("PRAGMA user_version", [], |r| r.get(0)).unwrap()
    };
    assert_eq!(
        before,
        nookclip_core::storage::schema::SCHEMA_VERSION,
        "新库应直接落在当前 schema 版本"
    );

    // 模拟「版本已最新但缺列」的库（部分恢复/外部工具写入）
    {
        let conn = rusqlite::Connection::open(&path).unwrap();
        conn.execute_batch("DROP INDEX IF EXISTS idx_clip_items_kind; ALTER TABLE clip_items DROP COLUMN kind;")
            .unwrap();
    }
    let _repo = StorageRepository::new(&path, &[6u8; 32]).expect("reopen must heal missing column");
    let after: i64 = {
        let conn = rusqlite::Connection::open(&path).unwrap();
        conn.query_row("PRAGMA user_version", [], |r| r.get(0)).unwrap()
    };
    assert_eq!(after, before, "缺列回填不得回退 user_version");
}

/// P2 回归：回收站列表下推到 SQL（only_deleted），按删除时间倒序。
#[test]
fn trash_query_filters_and_orders_by_deleted_at() {
    let (_f, repo) = repo();
    for (i, id) in ["t-a", "t-b", "t-c"].iter().enumerate() {
        repo.save_item(&text_item(id, &format!("body {id}"), 1.0 + i as f64), None)
            .unwrap();
    }
    repo.soft_delete("t-a").unwrap();
    std::thread::sleep(std::time::Duration::from_millis(5));
    repo.soft_delete("t-c").unwrap();

    let trash = repo
        .query_items(&QueryFilter {
            include_deleted: true,
            only_deleted: true,
            limit: 50,
            ..Default::default()
        })
        .unwrap();
    let ids: Vec<&str> = trash.iter().map(|i| i.id.as_str()).collect();
    assert_eq!(ids, vec!["t-c", "t-a"], "回收站按删除时间倒序且只含已删行");

    let active = repo.query_items(&QueryFilter::default()).unwrap();
    assert_eq!(active.len(), 1);
    assert_eq!(active[0].id, "t-b");
}

/// 保留期清理后 WAL 必须被截断（journal_size_limit + 显式 checkpoint）。
#[test]
fn prune_truncates_wal_file() {
    let dir = tempfile::tempdir().unwrap();
    let db = dir.path().join("wal.db");
    let db_path = db.to_str().unwrap().to_string();
    let repo = StorageRepository::new(&db_path, &[8u8; 32]).unwrap();
    for i in 0..500 {
        let mut item = text_item(&format!("w-{i}"), &format!("wal body {i}"), 1.0);
        item.last_used_at = 1.0;
        repo.save_item(&item, Some("x")).unwrap();
    }
    let _ = repo
        .prune_expired(&RetentionConfig {
            max_age_days: Some(1),
            max_item_count: None,
        })
        .unwrap();

    let wal = format!("{db_path}-wal");
    let size = std::fs::metadata(&wal).map(|m| m.len()).unwrap_or(0);
    assert!(
        size <= 8 * 1024 * 1024 + 1024 * 1024,
        "清理后 WAL 应回落到 journal_size_limit 量级，实际 {size} 字节"
    );
}
