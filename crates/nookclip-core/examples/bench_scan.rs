use nookclip_core::model::{QueryFilter, RetentionConfig};
use nookclip_core::storage::StorageRepository;

fn main() {
    let dir = std::env::temp_dir().join("nook-bench-scan");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let db = dir.join("bench.db");
    let repo = StorageRepository::new(db.to_str().unwrap(), &[0u8; 32]).unwrap();

    let n: usize = std::env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(20000);
    let t0 = std::time::Instant::now();
    for i in 0..n {
        let item = nookclip_core::model::ClipItemSummary {
            id: format!("id-{i:06}"),
            item_type: "text".into(),
            title: format!("title {i}"),
            summary: format!("const x{i} = {{\"a\": {i}}};\nfunction f{i}() {{ return x{i}; }}"),
            created_at: i as f64,
            last_used_at: i as f64,
            copy_count: 1,
            favorite: false,
            source_app_bundle_id: None,
            source_app_name: None,
            is_sensitive: false,
            deleted_at: None,
            payload_path: None,
            ocr_text: None,
            metadata_json: None,
            ..Default::default()
        };
        repo.save_item(&item, Some(&format!("raw text {i}"))).unwrap();
    }
    println!("insert {n}: {:?}", t0.elapsed());

    // 模拟每次搜索按键：count_categories（无关键词全表扫描）
    let t1 = std::time::Instant::now();
    for _ in 0..5 {
        let _ = repo.count_categories(None, None).unwrap();
    }
    println!("count_categories(empty) avg: {:?}", t1.elapsed() / 5);

    // 模拟带 FTS 关键词的计数
    let t2 = std::time::Instant::now();
    for _ in 0..5 {
        let _ = repo.count_categories(Some("title"), None).unwrap();
    }
    println!("count_categories(fts hit) avg: {:?}", t2.elapsed() / 5);

    // 模拟 text 派生分类分页查询（SQL 无 LIMIT，全量拉回内存过滤）
    let t3 = std::time::Instant::now();
    let f = QueryFilter {
        kind: Some("text".into()),
        limit: 100,
        offset: 0,
        ..Default::default()
    };
    for _ in 0..5 {
        let _ = repo.query_items(&f).unwrap();
    }
    println!("query_items(kind=text, page 1) avg: {:?}", t3.elapsed() / 5);

    // 普通分页查询（有 LIMIT）
    let t4 = std::time::Instant::now();
    let f2 = QueryFilter { limit: 100, ..Default::default() };
    for _ in 0..5 {
        let _ = repo.query_items(&f2).unwrap();
    }
    println!("query_items(no kind, page 1) avg: {:?}", t4.elapsed() / 5);

    let _ = repo.prune_expired(&RetentionConfig::default());
    let _ = std::fs::remove_dir_all(&dir);
}
