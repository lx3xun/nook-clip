use nookclip_core::{
    model::{ClipItemSummary, QueryFilter},
    storage::StorageRepository,
};
use tempfile::NamedTempFile;

fn create_test_repo() -> (NamedTempFile, StorageRepository) {
    let temp_file = NamedTempFile::new().expect("temp file");
    let key = [7u8; 32];
    let repo = StorageRepository::new(temp_file.path().to_str().unwrap(), &key).expect("repo");
    (temp_file, repo)
}

fn dummy_item(id: &str, title: &str, item_type: &str, last_used: f64) -> ClipItemSummary {
    ClipItemSummary {
        id: id.to_string(),
        item_type: item_type.to_string(),
        title: title.to_string(),
        summary: format!("Summary for {title}"),
        created_at: last_used,
        last_used_at: last_used,
        copy_count: 1,
        favorite: false,
        source_app_bundle_id: Some("com.apple.Safari".to_string()),
        source_app_name: Some("Safari".to_string()),
        is_sensitive: false,
        deleted_at: None,
        ..Default::default()
    }
}

#[test]
fn test_save_and_query_items_timeline() {
    let (_f, repo) = create_test_repo();

    let item1 = dummy_item("id-1", "First Item", "text", 100.0);
    let item2 = dummy_item("id-2", "Second Item", "code", 200.0);
    let item3 = dummy_item("id-3", "Third Item", "text", 300.0);

    repo.save_item(&item1, Some("Full text 1"))
        .unwrap();
    repo.save_item(&item2, Some("Full text 2"))
        .unwrap();
    repo.save_item(&item3, Some("Full text 3"))
        .unwrap();

    let results = repo.query_items(&QueryFilter::default()).unwrap();
    assert_eq!(results.len(), 3);
    assert_eq!(results[0].id, "id-3"); // latest last_used_at (300.0)
    assert_eq!(results[1].id, "id-2");
    assert_eq!(results[2].id, "id-1");

    // Detail fetch
    let detail = repo.get_item_detail("id-2").unwrap();
    assert_eq!(detail.raw_text, Some("Full text 2".to_string()));
}

#[test]
fn test_recopy_increments_copy_count() {
    let (_f, repo) = create_test_repo();

    let item = dummy_item("id-recopy", "Re-copied Item", "text", 100.0);
    repo.save_item(&item, Some("Hello")).unwrap();

    let updated = dummy_item("id-recopy", "Re-copied Item", "text", 500.0);
    let saved = repo.save_item(&updated, Some("Hello")).unwrap();
    assert_eq!(saved.copy_count, 2);

    let list = repo.query_items(&QueryFilter::default()).unwrap();
    assert_eq!(list[0].copy_count, 2);
    assert_eq!(list[0].last_used_at, 500.0);
}
#[test]
fn test_content_deduplication_different_id_same_content() {
    let (_f, repo) = create_test_repo();

    let item1 = dummy_item("id-orig", "Original Title", "text", 100.0);
    let saved1 = repo.save_item(&item1, Some("Identical Content"))
        .unwrap();
    assert_eq!(saved1.id, "id-orig");
    assert_eq!(saved1.copy_count, 1);

    // Copy again with new ID and later timestamp
    let mut item2 = dummy_item("id-new-guid", "New Title", "text", 250.0);
    item2.summary = item1.summary.clone();
    let saved2 = repo.save_item(&item2, Some("Identical Content"))
        .unwrap();

    // Should reuse id-orig, bump copy_count, preserve original created_at
    assert_eq!(saved2.id, "id-orig");
    assert_eq!(saved2.copy_count, 2);

    let items = repo.query_items(&QueryFilter::default()).unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].id, "id-orig");
    assert_eq!(items[0].copy_count, 2);
    assert_eq!(items[0].last_used_at, 250.0);
}

#[test]
fn test_toggle_favorite() {
    let (_f, repo) = create_test_repo();

    let item = dummy_item("id-fav", "Fav Item", "text", 100.0);
    repo.save_item(&item, Some("Content")).unwrap();

    let res1 = repo.toggle_favorite("id-fav").unwrap();
    assert!(res1.favorite);

    let fav_filter = QueryFilter {
        favorite_only: true,
        ..Default::default()
    };
    let favs = repo.query_items(&fav_filter).unwrap();
    assert_eq!(favs.len(), 1);

    let res2 = repo.toggle_favorite("id-fav").unwrap();
    assert!(!res2.favorite);
    let favs_after = repo.query_items(&fav_filter).unwrap();
    assert_eq!(favs_after.len(), 0);
}

#[test]
fn test_soft_delete_and_restore() {
    let (_f, repo) = create_test_repo();

    let item = dummy_item("id-del", "Delete Item", "text", 100.0);
    repo.save_item(&item, Some("Content")).unwrap();

    repo.soft_delete("id-del").unwrap();

    // Default query excludes deleted items
    let list = repo.query_items(&QueryFilter::default()).unwrap();
    assert_eq!(list.len(), 0);

    // Query including deleted items sees it
    let with_del = repo
        .query_items(&QueryFilter {
            include_deleted: true,
            ..Default::default()
        })
        .unwrap();
    assert_eq!(with_del.len(), 1);
    assert!(with_del[0].deleted_at.is_some());

    // Restore
    repo.restore_deleted("id-del").unwrap();
    let list_restored = repo.query_items(&QueryFilter::default()).unwrap();
    assert_eq!(list_restored.len(), 1);
    assert!(list_restored[0].deleted_at.is_none());
}

#[test]
fn test_purge_item() {
    let (_f, repo) = create_test_repo();

    let item = dummy_item("id-purge", "Purge Item", "text", 100.0);
    repo.save_item(&item, Some("Content")).unwrap();

    repo.purge_item("id-purge").unwrap();

    assert!(repo.get_item_detail("id-purge").is_err());
    let list = repo
        .query_items(&QueryFilter {
            include_deleted: true,
            ..Default::default()
        })
        .unwrap();
    assert_eq!(list.len(), 0);
}

#[test]
fn test_clear_all_history_exempts_favorites() {
    let (_f, repo) = create_test_repo();

    let mut normal = dummy_item("id-norm", "Normal Item", "text", 100.0);
    normal.favorite = false;
    let mut fav = dummy_item("id-fav", "Fav Item", "text", 200.0);
    fav.favorite = true;

    repo.save_item(&normal, Some("Normal")).unwrap();
    repo.save_item(&fav, Some("Fav")).unwrap();

    let cleared = repo.clear_all_history(true).unwrap();
    assert_eq!(cleared.len(), 1);
    assert_eq!(cleared[0].id, "id-norm");

    let remaining = repo.query_items(&QueryFilter::default()).unwrap();
    assert_eq!(remaining.len(), 1);
    assert_eq!(remaining[0].id, "id-fav");
}
#[test]
fn test_recopy_preserves_existing_ocr_in_fts() {
    let (_f, repo) = create_test_repo();

    let mut item = dummy_item("id-ocr-keep", "Screenshot", "image", 100.0);
    // Initial save with OCR text
    item.ocr_text = Some("OCRDetectedInvoiceNumber12345".to_string());
    repo.save_item(&item, None).unwrap();

    let filter = QueryFilter {
        search_query: Some("InvoiceNumber12345".to_string()),
        ..Default::default()
    };
    let initial_search = repo.query_items(&filter).unwrap();
    assert_eq!(initial_search.len(), 1, "Must find item by OCR keyword initially");

    // Re-copy the same item without OCR text (e.g. from monitor before OCR runs)
    let item_recopy = dummy_item("id-ocr-keep", "Screenshot", "image", 200.0);
    repo.save_item(&item_recopy, None).unwrap();

    // OCR text must be preserved in FTS5
    let search_after_recopy = repo.query_items(&filter).unwrap();
    assert_eq!(search_after_recopy.len(), 1, "FTS5 index must still find item by OCR after deduplication recopy");
}

#[test]
fn test_clear_all_history_keep_favorites_option() {
    let (_f, repo) = create_test_repo();

    let mut item_fav = dummy_item("id-fav-clear", "Fav Note", "text", 100.0);
    item_fav.favorite = true;
    let item_nonfav = dummy_item("id-nonfav-clear", "Normal Note", "text", 100.0);

    repo.save_item(&item_fav, Some("fav content")).unwrap();
    repo.save_item(&item_nonfav, Some("normal content")).unwrap();

    // When keep_favorites is false: all items cleared
    let cleared = repo.clear_all_history(false).unwrap();
    assert_eq!(cleared.len(), 2);

    let remaining = repo.query_items(&QueryFilter::default()).unwrap();
    assert!(remaining.is_empty(), "All items including favorites must be cleared when keep_favorites is false");
}

/// 软删幂等：重复 soft_delete 保留首次删除时间（撤销宽限按首次删除计时）
#[test]
fn test_soft_delete_preserves_original_timestamp() {
    let (_f, repo) = create_test_repo();
    let item = dummy_item("id-del-ts", "Timestamp", "text", 100.0);
    repo.save_item(&item, Some("content")).unwrap();

    repo.soft_delete("id-del-ts").unwrap();
    let first = repo
        .query_items(&QueryFilter {
            include_deleted: true,
            ..Default::default()
        })
        .unwrap()
        .into_iter()
        .find(|i| i.id == "id-del-ts")
        .unwrap()
        .deleted_at
        .unwrap();

    std::thread::sleep(std::time::Duration::from_millis(20));
    repo.soft_delete("id-del-ts").unwrap();
    let second = repo
        .query_items(&QueryFilter {
            include_deleted: true,
            ..Default::default()
        })
        .unwrap()
        .into_iter()
        .find(|i| i.id == "id-del-ts")
        .unwrap()
        .deleted_at
        .unwrap();

    assert_eq!(first, second, "重复软删不得刷新删除时间");
}

#[test]
fn test_rekey_rotates_sensitive_payload_encryption() {
    let temp_file = NamedTempFile::new().expect("temp file");
    let old_key = [42u8; 32];
    let new_key = [0xAB; 32];
    let db_path = temp_file.path().to_str().unwrap().to_string();

    {
        let repo = StorageRepository::new(&db_path, &old_key).unwrap();
        let mut secret = dummy_item("id-rekey", "Secret", "text", 100.0);
        secret.is_sensitive = true;
        repo.save_item(&secret, Some("sk-rekey-token")).unwrap();
    }

    // 旧密钥打开并轮换到新密钥
    {
        let repo = StorageRepository::new(&db_path, &old_key).unwrap();
        let count = repo.rekey(&new_key).unwrap();
        assert_eq!(count, 1, "应重加密 1 条密文载荷");
    }

    // 新密钥可解密
    let repo_new = StorageRepository::new(&db_path, &new_key).unwrap();
    let detail = repo_new.get_item_detail("id-rekey").unwrap();
    assert_eq!(detail.raw_text, Some("sk-rekey-token".to_string()));

    // 旧密钥解密必须失败（载荷确实换钥）
    let repo_old = StorageRepository::new(&db_path, &old_key).unwrap();
    assert!(repo_old.get_item_detail("id-rekey").is_err());
}

#[test]
fn test_migration_from_v2_schema_without_kind_column() {
    let temp_file = NamedTempFile::new().expect("temp file");
    let db_path = temp_file.path().to_str().unwrap().to_string();

    // 模拟存量 user_version = 2 的旧表结构（不含 kind 列）
    {
        let conn = rusqlite::Connection::open(&db_path).unwrap();
        conn.execute_batch(
            r#"
            CREATE TABLE clip_items (
                id TEXT PRIMARY KEY,
                item_type TEXT NOT NULL,
                title TEXT NOT NULL,
                summary TEXT NOT NULL,
                created_at REAL NOT NULL,
                last_used_at REAL NOT NULL,
                copy_count INTEGER NOT NULL DEFAULT 1,
                favorite INTEGER NOT NULL DEFAULT 0,
                source_app_bundle_id TEXT,
                source_app_name TEXT,
                is_sensitive INTEGER NOT NULL DEFAULT 0,
                deleted_at REAL,
                payload_path TEXT,
                updated_at REAL NOT NULL DEFAULT 0
            );
            INSERT INTO clip_items (id, item_type, title, summary, created_at, last_used_at)
            VALUES ('legacy-1', 'text', 'Legacy', '#FF5733', 100.0, 100.0);
            PRAGMA user_version = 2;
            "#,
        )
        .unwrap();
    }

    // 打开仓库必须成功添加 kind 列、建立索引并回填派生分类
    let key = [7u8; 32];
    let repo = StorageRepository::new(&db_path, &key).expect("migration from v2 must succeed");
    let items = repo.query_items(&QueryFilter::default()).unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].id, "legacy-1");
    let counts = repo.count_categories(None, None).unwrap();
    assert_eq!(counts.color, 1);
}

#[test]
fn test_managed_payload_path_stored_as_relative_filename_and_resolved_across_container_moves() {
    let temp_db = NamedTempFile::new().expect("temp db");
    let db_path = temp_db.path().to_str().unwrap().to_string();
    let key = [9u8; 32];

    let container_v1 = tempfile::tempdir().expect("container v1");
    let container_v2 = tempfile::tempdir().expect("container v2");

    let store_v1 = nookclip_core::storage::PayloadAssetStore::new(container_v1.path()).unwrap();
    let abs_path_v1 = store_v1.save_payload_asset(b"png-binary-payload", "png").unwrap();
    let expected_filename = std::path::Path::new(&abs_path_v1)
        .file_name()
        .unwrap()
        .to_str()
        .unwrap()
        .to_string();

    let repo = StorageRepository::new(&db_path, &key).unwrap();
    repo.set_assets_dir(Some(container_v1.path()));

    let mut img_item = dummy_item("img-rel-1", "Screenshot", "image", 100.0);
    img_item.payload_path = Some(abs_path_v1.clone());
    let saved = repo.save_item(&img_item, None).unwrap();

    // 1. 数据库内部仅持久化纯文件名（不含沙盒容器绝对前缀）
    let raw_stored = repo.raw_stored_payload_path("img-rel-1").unwrap();
    assert_eq!(raw_stored.as_deref(), Some(expected_filename.as_str()));
    // 返回给调用方的运行时路径自动拼接 container_v1
    assert_eq!(saved.payload_path.as_deref(), Some(abs_path_v1.as_str()));

    // 2. 模拟 iOS 容器 UUID 变更或目录迁移：将文件移入 container_v2 并切换 assets_dir
    let abs_path_v2 = container_v2.path().join(&expected_filename);
    std::fs::copy(&abs_path_v1, &abs_path_v2).unwrap();
    std::fs::remove_file(&abs_path_v1).unwrap();
    repo.set_assets_dir(Some(container_v2.path()));

    let queried = repo.query_items(&QueryFilter::default()).unwrap();
    assert_eq!(
        queried[0].payload_path.as_deref(),
        Some(abs_path_v2.to_str().unwrap()),
        "容器目录迁移后查询到的 payload_path 必须自动解析到新容器目录"
    );
}

#[test]
fn test_query_items_truncates_summary_in_sql_when_summary_max_chars_set() {
    let (_f, repo) = create_test_repo();
    let long_text = "中".repeat(500);
    let mut item = dummy_item("long-1", "", "text", 100.0);
    item.summary = long_text.clone();
    repo.save_item(&item, Some(&long_text)).unwrap();

    // 列表查询：限制 300 字符
    let list_filter = QueryFilter {
        limit: 10,
        summary_max_chars: Some(300),
        ..Default::default()
    };
    let list_items = repo.query_items(&list_filter).unwrap();
    assert_eq!(list_items[0].summary.chars().count(), 300);

    // 单条按 id 全文查询：忽略截断上限，返回完整 500 字符
    let single_filter = QueryFilter {
        id: Some("long-1".to_string()),
        limit: 1,
        summary_max_chars: Some(300),
        ..Default::default()
    };
    let single_items = repo.query_items(&single_filter).unwrap();
    assert_eq!(single_items[0].summary.chars().count(), 500);
}

/// 内存库（:memory:）单连接读写可见性：写后立即可查。
#[test]
fn test_in_memory_database_read_path_sees_writes() {
    let repo = StorageRepository::new(":memory:", &[7u8; 32]).unwrap();
    let filter = QueryFilter {
        limit: 10,
        ..Default::default()
    };
    assert_eq!(repo.query_items(&filter).unwrap().len(), 0);

    let item = dummy_item("mem-1", "内存条目", "text", 100.0);
    repo.save_item(&item, Some("内存内容")).unwrap();

    assert_eq!(repo.query_items(&filter).unwrap().len(), 1, "内存库查询必须看到写入");
    assert_eq!(repo.count_items().unwrap(), 1);
    assert_eq!(repo.count_categories(None, None).unwrap().total, 1);
    assert_eq!(repo.time_group_timestamps(&filter).unwrap().len(), 1);
}
