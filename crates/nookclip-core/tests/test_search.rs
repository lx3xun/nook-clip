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

fn dummy_item(id: &str, title: &str, summary: &str, app_name: &str) -> ClipItemSummary {
    ClipItemSummary {
        id: id.to_string(),
        item_type: "text".to_string(),
        title: title.to_string(),
        summary: summary.to_string(),
        created_at: 100.0,
        last_used_at: 100.0,
        copy_count: 1,
        favorite: false,
        source_app_bundle_id: Some("com.apple.Safari".to_string()),
        source_app_name: Some(app_name.to_string()),
        is_sensitive: false,
        deleted_at: None,
        ..Default::default()
    }
}

#[test]
fn test_search_chinese_substring() {
    let (_f, repo) = create_test_repo();

    let item1 = dummy_item(
        "id-1",
        "Rust核心接口层重构",
        "将剪切板存储和搜索下沉到Rust高性能内核",
        "Xcode",
    );
    let item2 = dummy_item(
        "id-2",
        "今日待办事项列表",
        "买牛奶，写代码，提交PR并合并到主分支",
        "Notes",
    );
    let item3 = dummy_item(
        "id-3",
        "NookClip发布日志",
        "新版本已提升性能并支持全局快捷键唤出",
        "Safari",
    );

    repo.save_item(&item1, Some("Rust核心接口层重构详细说明"))
        .unwrap();
    repo.save_item(&item2, Some("买牛奶，写代码"))
        .unwrap();
    repo.save_item(&item3, Some("新版本发布"))
        .unwrap();

    // Query 1: "高性能"
    let res1 = repo
        .query_items(&QueryFilter {
            search_query: Some("高性能".to_string()),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(res1.len(), 1);
    assert_eq!(res1[0].id, "id-1");

    // Query 2: "代码"
    let res2 = repo
        .query_items(&QueryFilter {
            search_query: Some("代码".to_string()),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(res2.len(), 1);
    assert_eq!(res2[0].id, "id-2");

    // Query 3: "版本"
    let res3 = repo
        .query_items(&QueryFilter {
            search_query: Some("版本".to_string()),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(res3.len(), 1);
    assert_eq!(res3[0].id, "id-3");
}

#[test]
fn test_search_english_substring() {
    let (_f, repo) = create_test_repo();

    let item1 = dummy_item(
        "id-1",
        "fn calculate_hash",
        "SHA-256 computation over arbitrary byte stream",
        "VSCode",
    );
    let item2 = dummy_item(
        "id-2",
        "docker run command",
        "docker run -d -p 8080:80 nginx:latest",
        "Terminal",
    );

    repo.save_item(&item1, None).unwrap();
    repo.save_item(&item2, None).unwrap();

    let res = repo
        .query_items(&QueryFilter {
            search_query: Some("calculate".to_string()),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(res.len(), 1);
    assert_eq!(res[0].id, "id-1");

    let res_app = repo
        .query_items(&QueryFilter {
            search_query: Some("Terminal".to_string()),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(res_app.len(), 1);
    assert_eq!(res_app[0].id, "id-2");
}

#[test]
fn test_search_kind_filter_image_and_file() {
    let (_f, repo) = create_test_repo();

    let mut image_file = dummy_item("id-img-file", "nookclip.png", "/path/to/nookclip.png", "Finder");
    image_file.item_type = "file".to_string();
    image_file.payload_path = Some("/path/to/nookclip.png".to_string());

    let mut doc_file = dummy_item("id-doc-file", "document.pdf", "/path/to/document.pdf", "Finder");
    doc_file.item_type = "file".to_string();
    doc_file.payload_path = Some("/path/to/document.pdf".to_string());

    repo.save_item(&image_file, None).unwrap();
    repo.save_item(&doc_file, None).unwrap();

    // Filter kind = "image"
    let res_image = repo
        .query_items(&QueryFilter {
            kind: Some("image".to_string()),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(res_image.len(), 1);
    assert_eq!(res_image[0].id, "id-img-file");

    // Filter kind = "file"
    let res_file = repo
        .query_items(&QueryFilter {
            kind: Some("file".to_string()),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(res_file.len(), 1);
    assert_eq!(res_file[0].id, "id-doc-file");
}

#[test]
fn test_search_alias_short_and_long_tokens() {
    let (_f, repo) = create_test_repo();

    // 1. 普通条目设置别名 "123"
    let item_normal = dummy_item("id-normal", "", "normal summary text", "Safari");
    repo.save_item(&item_normal, Some("normal summary text")).unwrap();
    repo.update_title("id-normal", "123").unwrap();

    // 2. 敏感条目设置别名 "123"
    let mut item_sensitive = dummy_item("id-sensitive", "", "secret-token-xyz999", "Terminal");
    item_sensitive.is_sensitive = true;
    repo.save_item(&item_sensitive, Some("secret-token-xyz999")).unwrap();
    repo.update_title("id-sensitive", "123").unwrap();

    // 3. 搜索短词 "12"（<3 标量）：两条别名均应命中
    let res_12 = repo
        .query_items(&QueryFilter {
            search_query: Some("12".to_string()),
            ..Default::default()
        })
        .unwrap();
    let ids_12: Vec<String> = res_12.iter().map(|it| it.id.clone()).collect();
    assert!(ids_12.contains(&"id-normal".to_string()), "短词 12 应搜出普通条目别名 123");
    assert!(ids_12.contains(&"id-sensitive".to_string()), "短词 12 应搜出敏感条目别名 123");

    // 4. 搜索长词 "123"（>=3 标量）：两条别名也必须均能命中
    let res_123 = repo
        .query_items(&QueryFilter {
            search_query: Some("123".to_string()),
            ..Default::default()
        })
        .unwrap();
    let ids_123: Vec<String> = res_123.iter().map(|it| it.id.clone()).collect();
    assert!(ids_123.contains(&"id-normal".to_string()), "长词 123 必须搜出普通条目别名 123");
    assert!(ids_123.contains(&"id-sensitive".to_string()), "长词 123 必须搜出敏感条目别名 123（当前 BUG）");

    // 5. 安全断言：敏感条目的原始密文绝不可被检索
    let res_secret = repo
        .query_items(&QueryFilter {
            search_query: Some("xyz999".to_string()),
            ..Default::default()
        })
        .unwrap();
    assert!(res_secret.is_empty(), "敏感条目密文绝对不可被检索命中");
}
