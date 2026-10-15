use nookclip_core::model::{ClipItemSummary, QueryFilter};
use nookclip_core::storage::StorageRepository;
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

/// save_item 的返回值契约：必须是合并后的真实行状态。
/// 内容去重合并（upsert 冲突时保留旧 title）后，返回值回显输入条目会让
/// 「增量更新内存镜像」的调用方（Swift save 路径）拿到与库不一致的
/// 标题/摘要/OCR/元数据——旧实现靠整页重查掩盖，增量路径下必现错位。
#[test]
fn test_recopy_returns_merged_row_state() {
    let (_f, repo) = create_test_repo();
    repo.save_item(&dummy_item("id-ct", "捕获标题", "text", 100.0), Some("full text ct"))
        .unwrap();
    repo.update_title("id-ct", "★ 我的专属秘钥").unwrap();

    // 重复捕获：同内容、新 id（捕获层每次生成新 UUID，去重由存储层合并）
    let persisted = repo
        .save_item(&dummy_item("id-ct-new", "捕获标题", "text", 200.0), Some("full text ct"))
        .unwrap();

    assert_eq!(persisted.id, "id-ct", "内容去重合并回原 id");
    assert_eq!(persisted.title, "★ 我的专属秘钥", "返回值必须携带合并后的行状态（自定义标题保留）");
    assert_eq!(persisted.copy_count, 2, "返回值携带合并后的累计次数");

    // FTS 行必须同样使用合并后的标题：重捕获后按自定义标题搜索不得丢失
    let hits = repo
        .query_items(&QueryFilter {
            search_query: Some("专属秘钥".to_string()),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(hits.len(), 1, "重捕获后按自定义标题仍可命中（FTS 用合并后标题重建）");
    assert_eq!(hits[0].id, "id-ct");
}
