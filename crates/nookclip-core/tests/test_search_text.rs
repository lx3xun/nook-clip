use nookclip_core::{
    model::{ClipItemSummary, QueryFilter},
    storage::StorageRepository,
};
use tempfile::NamedTempFile;

#[test]
fn test_search_text_pure_keywords_and_phrases() {
    let file = NamedTempFile::new().unwrap();
    let key = [5u8; 32];
    let repo = StorageRepository::new(file.path().to_str().unwrap(), &key).unwrap();

    let item1 = ClipItemSummary {
        id: "id-search-1".to_string(),
        item_type: "text".to_string(),
        title: "Exact Phrase Target".to_string(),
        summary: "This contains an exact phrase here".to_string(),
        created_at: 100.0,
        last_used_at: 100.0,
        copy_count: 1,
        favorite: false,
        source_app_bundle_id: None,
        source_app_name: None,
        is_sensitive: false,
        deleted_at: None,
        ..Default::default()
    };
    repo.save_item(&item1, Some("This contains an exact phrase here"))
    .unwrap();

    let item2 = ClipItemSummary {
        id: "id-search-2".to_string(),
        item_type: "text".to_string(),
        title: "Disjoint Words".to_string(),
        summary: "Exact something phrase words".to_string(),
        created_at: 110.0,
        last_used_at: 110.0,
        copy_count: 1,
        favorite: false,
        source_app_bundle_id: None,
        source_app_name: None,
        is_sensitive: false,
        deleted_at: None,
        ..Default::default()
    };
    repo.save_item(&item2, Some("Exact something phrase words"))
        .unwrap();

    // Query with exact quoted phrase: only item1 should match
    let filter = QueryFilter {
        search_query: Some("\"exact phrase\"".to_string()),
        ..Default::default()
    };
    let res = repo.query_items(&filter).unwrap();
    assert_eq!(res.len(), 1);
    assert_eq!(res[0].id, "id-search-1");
}
