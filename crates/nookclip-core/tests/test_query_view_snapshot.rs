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
            source_device_id: None,
            source_device_name: None,
            source_platform: None,
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

/// SQL 内聚合的锚点计数必须与逐条 chrono 分组（group_timestamps）结果一致：
/// 分页外更早分组 / 多时区 / 跨月 / 跨年都要落在同一个桶且有相同条数。
#[test]
fn test_anchor_counts_match_timestamp_grouping() {
    for tz_offset in [0i32, 8 * 3600, -5 * 3600] {
        let dir = tempdir().unwrap();
        let db_path = dir.path().join("test_anchor_match.db");
        let key = [0x11u8; 32];
        let repo = StorageRepository::new(db_path.to_str().unwrap(), &key).unwrap();

        let now_ts = 1792152000.0;
        let calendar = CalendarContext {
            now_ts,
            tz_offset_secs: tz_offset,
            first_weekday: 1,
        };

        // 覆盖：今天 / 昨天 / 本周更早 / 上周 / 本月初 / 上月 / 去年同月 / 超过 20 年前（2001 年）
        let offsets = [
            0.0,
            -3600.0,
            -86400.0,
            -86400.0 * 3.0,
            -86400.0 * 10.0,
            -86400.0 * 45.0,
            -86400.0 * 400.0,
            -86400.0 * 365.0 * 25.0,
        ];
        for (i, off) in offsets.iter().enumerate() {
            let ts = now_ts + off;
            let summary = ClipItemSummary {
                id: format!("id-{i}"),
                item_type: "text".to_string(),
                title: format!("t{i}"),
                summary: format!("s{i}"),
                created_at: ts,
                last_used_at: ts,
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
            repo.save_item(&summary, Some(&format!("s{i}"))).unwrap();
        }

        let filter = QueryFilter::default();
        let snap = query_view_snapshot(&repo, &filter, &calendar).unwrap();

        // 参照：旧的逐条 grouping 路径
        let all_ts = repo.time_group_timestamps(&filter).unwrap();
        let expected = nookclip_core::pipeline::timeline::group_timestamps(&all_ts, &calendar);

        let key_of = |s: &nookclip_core::model::TimeGroupSummary| (s.id.clone(), s.count);
        let actual: Vec<(String, u32)> = snap.timeline_anchors.iter().map(key_of).collect();
        let want: Vec<(String, u32)> = expected.iter().map(key_of).collect();
        assert_eq!(
            actual, want,
            "tz={tz_offset}: SQL 聚合与逐条分组不一致"
        );
        assert_eq!(
            actual.iter().map(|(_, c)| *c as u64).sum::<u64>(),
            offsets.len() as u64,
            "tz={tz_offset}: 锚点总数必须覆盖全部条目"
        );
    }
}

/// 周一边界回归：周日条目属于「昨天」，不得同时计入「上周」。
/// now = 2026-10-12（周一）12:00 UTC，插入上周日与更早的条目。
#[test]
fn test_anchor_counts_do_not_double_count_sunday_on_monday() {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("test_monday.db");
    let key = [0x33u8; 32];
    let repo = StorageRepository::new(db_path.to_str().unwrap(), &key).unwrap();

    let monday_noon = 1_791_806_400.0; // 2026-10-12 12:00 UTC (Monday)
    let calendar = CalendarContext {
        now_ts: monday_noon,
        tz_offset_secs: 0,
        first_weekday: 1,
    };

    // 周日 10:00（昨天）、上周三、上周二
    let offsets = [
        ("sunday", monday_noon - 26.0 * 3600.0),
        ("last-wed", monday_noon - 5.0 * 86400.0),
        ("last-tue", monday_noon - 6.0 * 86400.0),
    ];
    for (id, ts) in offsets {
        let summary = ClipItemSummary {
            id: id.to_string(),
            item_type: "text".to_string(),
            title: id.to_string(),
            summary: id.to_string(),
            created_at: ts,
            last_used_at: ts,
            copy_count: 1,
            favorite: false,
            ..Default::default()
        };
        repo.save_item(&summary, Some(id)).unwrap();
    }

    let filter = QueryFilter::default();
    let snap = query_view_snapshot(&repo, &filter, &calendar).unwrap();
    let counts: std::collections::HashMap<String, u32> = snap
        .timeline_anchors
        .iter()
        .map(|a| (a.id.clone(), a.count))
        .collect();

    assert_eq!(counts.get("yesterday"), Some(&1), "周日应只计入昨天");
    assert_eq!(counts.get("last-week"), Some(&2), "上周只应有周二/周三两条");
    assert_eq!(
        counts.values().sum::<u32>(),
        3,
        "锚点总数必须等于条目数（不得重复计数）"
    );

    // 与逐条分组算法一致
    let all_ts = repo.time_group_timestamps(&filter).unwrap();
    let expected = nookclip_core::pipeline::timeline::group_timestamps(&all_ts, &calendar);
    let want: Vec<(String, u32)> = expected.iter().map(|s| (s.id.clone(), s.count)).collect();
    let got: Vec<(String, u32)> = snap
        .timeline_anchors
        .iter()
        .map(|s| (s.id.clone(), s.count))
        .collect();
    assert_eq!(got, want, "周一 SQL 聚合必须与逐条分组一致");
}
