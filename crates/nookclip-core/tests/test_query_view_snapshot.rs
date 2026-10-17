use tempfile::tempdir;

use nookclip_core::{
    model::{CalendarContext, ClipItemSummary, QueryFilter},
    pipeline::query_snapshot::query_view_snapshot,
    storage::repository::StorageRepository,
};

#[test]
fn test_query_view_snapshot_integration() {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("test_snapshot.db");
    let key = [0x42u8; 32];
    let repo = StorageRepository::new(db_path.to_str().unwrap(), &key).unwrap();

    let now_ts = 1792152000.0;
    let calendar = CalendarContext {
        now_ts,
        tz_offset_secs: 0,
        first_weekday: 1,
    };

    // 插入 5 条不同时间、不同类型的记录
    let items = vec![
        ("1", "Hello Rust", "text", now_ts - 50.0, false),
        ("2", "Hello World", "text", now_ts - 100.0, true),
        ("3", "https://example.com", "url", now_ts - 86400.0, false),
        ("4", "image.png", "image", now_ts - 86400.0 * 2.0, false),
        ("5", "Hello Swift", "text", now_ts - 86400.0 * 40.0, false),
    ];

    for (id, content, item_type, ts, fav) in items {
        let summary = ClipItemSummary {
            id: id.to_string(),
            item_type: item_type.to_string(),
            title: content.to_string(),
            summary: content.to_string(),
            created_at: ts,
            last_used_at: ts,
            copy_count: 1,
            favorite: fav,
            source_app_bundle_id: None,
            source_app_name: None,
            is_sensitive: false,
            deleted_at: None,
            payload_path: None,
            ocr_text: None,
            metadata_json: None,
            kind: item_type.to_string(),
        };
        repo.save_item(&summary, Some(content)).unwrap();
    }

    // 1. 无搜索词、limit = 2 (测试 has_more 和 timeline_anchors 全量性)
    let filter = QueryFilter {
        limit: 2,
        offset: 0,
        ..Default::default()
    };
    let snap = query_view_snapshot(&repo, &filter, &calendar).unwrap();
    assert_eq!(snap.items.len(), 2);
    assert!(snap.has_more, "总共 5 条，limit 2，必须 has_more == true");
    assert_eq!(snap.category_counts.total, 5);
    assert_eq!(snap.category_counts.favorite, 1);
    // timeline_anchors 必须统计全部 5 条，不受 limit 2 截断
    let total_anchors_count: u32 = snap.timeline_anchors.iter().map(|a| a.count).sum();
    assert_eq!(total_anchors_count, 5);

    // 2. 带搜索词 "Hello"
    let search_filter = QueryFilter {
        search_query: Some("Hello".to_string()),
        limit: 10,
        ..Default::default()
    };
    let snap_search = query_view_snapshot(&repo, &search_filter, &calendar).unwrap();
    assert_eq!(snap_search.items.len(), 3); // "Hello Rust", "Hello World", "Hello Swift"
    assert_eq!(snap_search.search_keywords, vec!["Hello"]);
}
