use nookclip_core::{
    model::{ClipItemSummary, QueryFilter, RetentionConfig},
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

/// 索引结构 v2 不变量：clip_fts 行 rowid 与 clip_items.rowid 一一对齐。
/// FTS 维护（save/update/delete/prune）全部按 rowid 定位；若任何写路径
/// 重新引入按 clip_id 的全表扫描删除或不对齐插入，此测试变红。
#[test]
fn test_fts_rowids_stay_aligned_with_clip_items() {
    let (_f, repo) = create_test_repo();

    for i in 0..20 {
        let item = dummy_item(&format!("align-{i}"), &format!("Align Title {i}"), "text", i as f64);
        repo.save_item(&item, Some(&format!("full text {i}")))
            .unwrap();
    }

    // 同 id 重新 save（内容合并路径）不得产生第二条 FTS 行；
    // 刷新 last_used 到当前时刻，使其在随后的保留期清理中幸存
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs_f64();
    let again = dummy_item("align-5", "Align Title 5 updated", "text", now);
    repo.save_item(&again, Some("full text 5 v2"))
        .unwrap();

    repo.update_title("align-6", "Renamed Title").unwrap();
    repo.update_ocr_text("align-7", "ocr text").unwrap();
    repo.purge_item("align-8").unwrap();
    repo.soft_delete("align-9").unwrap();

    let _pruned = repo
        .prune_expired(&RetentionConfig {
            max_age_days: Some(1),
            max_item_count: None,
        })
        .unwrap();
    // last_used = 0..19（1970 年）全部过期被清；align-5 已刷新到 500.0 保留
    let conn = rusqlite::Connection::open(_f.path()).expect("open db");

    let misaligned: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM clip_fts f
             LEFT JOIN clip_items c ON c.rowid = f.rowid AND c.id = f.clip_id
             WHERE c.id IS NULL",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(misaligned, 0, "每条 FTS 行必须与 clip_items 行 rowid 一一对齐");

    let missing_index: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM clip_items c
             LEFT JOIN clip_fts f ON f.rowid = c.rowid
             WHERE f.rowid IS NULL AND c.is_sensitive = 0",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(missing_index, 0, "每条非敏感 clip_items 行必须有对应 FTS 行");

    // 对齐后搜索仍然命中：align-5 重存走内容合并路径，标题保留库内原值
    // （自定义标题保留特性），FTS 行与展示标题一致——按持久化标题命中，
    // 被替换的输入标题不得命中（FTS≠展示标题的旧错位已修复）
    let hits = repo
        .query_items(&QueryFilter {
            search_query: Some("Align Title 5".to_string()),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(hits.len(), 1, "重存后的索引行按持久化标题可被搜索命中");
    assert_eq!(hits[0].id, "align-5");

    let stale = repo
        .query_items(&QueryFilter {
            search_query: Some("Align Title 5 updated".to_string()),
            ..Default::default()
        })
        .unwrap();
    assert!(stale.is_empty(), "被合并替换的输入标题不得残留在 FTS 索引中");
}
