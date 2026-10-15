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

fn item_at(id: &str, title: &str, summary: &str, last_used_at: f64) -> ClipItemSummary {
    ClipItemSummary {
        id: id.to_string(),
        item_type: "text".to_string(),
        title: title.to_string(),
        summary: summary.to_string(),
        created_at: last_used_at,
        last_used_at,
        copy_count: 1,
        favorite: false,
        source_app_bundle_id: Some("com.apple.Safari".to_string()),
        source_app_name: Some("Safari".to_string()),
        is_sensitive: false,
        deleted_at: None,
        ..Default::default()
    }
}

/// 时间导航锚点条的全量时间戳聚合：
/// 分页列表只加载前 N 条时，锚点条仍须拿到全部命中条目的 last_used_at，
/// 否则更早的时间分组（上周/月份/年份）在导航中缺失（pageSize 100 回归）。
#[test]
fn test_time_group_timestamps_returns_all_matches_beyond_page_limit() {
    let (_f, repo) = create_test_repo();

    for i in 0..5 {
        let item = item_at(
            &format!("id-{i}"),
            &format!("条目{i}"),
            &format!("内容{i}"),
            1_000.0 + i as f64,
        );
        repo.save_item(&item, Some(&format!("内容{i}"))).unwrap();
    }

    let filter = QueryFilter {
        limit: 2, // 分页只取前 2 条
        ..Default::default()
    };
    let paged = repo.query_items(&filter).unwrap();
    assert_eq!(paged.len(), 2);

    let timestamps = repo.time_group_timestamps(&filter).unwrap();
    assert_eq!(timestamps.len(), 5, "全量时间戳不受分页 limit 约束");
    // last_used_at 降序（与列表排序一致，Swift 直接顺序分组）
    let sorted: Vec<f64> = {
        let mut v = timestamps.clone();
        v.sort_by(|a, b| b.partial_cmp(a).unwrap());
        v
    };
    assert_eq!(timestamps, sorted);
    assert_eq!(timestamps[0], 1_004.0);
}

/// 关键词筛选须同步作用于时间戳聚合：锚点条与列表看到同一批命中条目
#[test]
fn test_time_group_timestamps_respects_search_query() {
    let (_f, repo) = create_test_repo();

    let a = item_at("id-a", "Swift 任务", "完成重构", 2_000.0);
    let b = item_at("id-b", "Rust 任务", "修复存储", 1_500.0);
    repo.save_item(&a, Some("完成重构")).unwrap();
    repo.save_item(&b, Some("修复存储")).unwrap();

    let filter = QueryFilter {
        search_query: Some("Rust".to_string()),
        ..Default::default()
    };
    let timestamps = repo.time_group_timestamps(&filter).unwrap();
    assert_eq!(timestamps, vec![1_500.0]);
}

/// 派生分类（code/text/color 在模型层归类）须同步作用于时间戳聚合：
/// 分类筛选下锚点条分组与列表内容一致
#[test]
fn test_time_group_timestamps_respects_derived_kind_filter() {
    let (_f, repo) = create_test_repo();

    let code_summary = "import SwiftUI\nfunc render() -> some View { let x = 1 }";
    let code = ClipItemSummary {
        id: "id-code".to_string(),
        summary: code_summary.to_string(),
        ..item_at("id-code", "main.swift", code_summary, 3_000.0)
    };
    let plain = item_at("id-plain", "笔记", "普通文本内容", 2_900.0);
    repo.save_item(&code, Some(code_summary)).unwrap();
    repo.save_item(&plain, Some("普通文本内容")).unwrap();

    let filter = QueryFilter {
        kind: Some("code".to_string()),
        ..Default::default()
    };
    // 前置确认：列表在 code 筛选下只有 1 条
    let paged = repo.query_items(&filter).unwrap();
    assert_eq!(paged.len(), 1);
    assert_eq!(paged[0].id, "id-code");

    let timestamps = repo.time_group_timestamps(&filter).unwrap();
    assert_eq!(timestamps, vec![3_000.0]);
}
