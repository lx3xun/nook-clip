use nookclip_core::{
    model::{ClipItemSummary, QueryFilter},
    storage::StorageRepository,
};
use tempfile::NamedTempFile;

fn create_test_repo() -> (NamedTempFile, StorageRepository) {
    let temp_file = NamedTempFile::new().expect("temp file");
    let key = [42u8; 32];
    let repo = StorageRepository::new(temp_file.path().to_str().unwrap(), &key).expect("repo");
    (temp_file, repo)
}

#[test]
fn test_manual_ocr_text_update_and_search() {
    let (_f, repo) = create_test_repo();

    let image_item = ClipItemSummary {
        id: "img-001".to_string(),
        item_type: "image".to_string(),
        title: "Screenshot 2026-10-10".to_string(),
        summary: "320x240 image".to_string(),
        created_at: 100.0,
        last_used_at: 100.0,
        copy_count: 1,
        favorite: false,
        source_app_bundle_id: Some("com.apple.screencapture".to_string()),
        source_app_name: Some("ScreenCapture".to_string()),
        is_sensitive: false,
        deleted_at: None,
        ..Default::default()
    };

    repo.save_item(&image_item, None).unwrap();

    // Prior to OCR: searching for OCR keyword returns 0
    let pre_search = repo
        .query_items(&QueryFilter {
            search_query: Some("DatabaseConnectionException".to_string()),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(pre_search.len(), 0);

    // User triggers OCR: Swift extracts text and calls update_ocr_text
    let recognized_text = "ERROR: DatabaseConnectionException failed to connect to host 127.0.0.1:5432 after 3 retries";
    repo.update_ocr_text("img-001", recognized_text).unwrap();

    // After OCR: searching for keyword matches the image!
    let post_search = repo
        .query_items(&QueryFilter {
            search_query: Some("DatabaseConnectionException".to_string()),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(post_search.len(), 1);
    assert_eq!(post_search[0].id, "img-001");

    // Detail includes the OCR text
    let detail = repo.get_item_detail("img-001").unwrap();
    assert_eq!(detail.ocr_text, Some(recognized_text.to_string()));
}

/// US5：短 token（<3 字符）不走 FTS，LIKE 回退必须覆盖 OCR 文本
#[test]
fn test_short_token_search_matches_ocr_text() {
    let (_f, repo) = create_test_repo();

    let image_item = ClipItemSummary {
        id: "img-short-token".to_string(),
        item_type: "image".to_string(),
        title: "Screenshot".to_string(),
        summary: "640x480 image".to_string(),
        created_at: 100.0,
        last_used_at: 100.0,
        copy_count: 1,
        favorite: false,
        source_app_bundle_id: None,
        source_app_name: Some("ScreenCapture".to_string()),
        is_sensitive: false,
        deleted_at: None,
        ..Default::default()
    };
    repo.save_item(&image_item, None).unwrap();
    repo.update_ocr_text("img-short-token", "invoice #42 paid").unwrap();

    let hits = repo
        .query_items(&QueryFilter {
            search_query: Some("42".to_string()),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(hits.len(), 1, "2 字符 token 必须能命中 OCR 文本");
    assert_eq!(hits[0].id, "img-short-token");
}
