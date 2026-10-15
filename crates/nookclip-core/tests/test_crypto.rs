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
fn test_sensitive_item_encryption_at_rest_and_fts_exclusion() {
    let (_f, repo) = create_test_repo();

    let token = "sk-live-secret-openai-token-99887766";
    let item = ClipItemSummary {
        id: "id-secret".to_string(),
        item_type: "text".to_string(),
        title: "API Key".to_string(),
        summary: "••••••••".to_string(),
        created_at: 100.0,
        last_used_at: 100.0,
        copy_count: 1,
        favorite: false,
        source_app_bundle_id: Some("com.apple.Terminal".to_string()),
        source_app_name: Some("Terminal".to_string()),
        is_sensitive: true,
        deleted_at: None,
        ..Default::default()
    };

    repo.save_item(&item, Some(token)).unwrap();

    // 1. In list, summary is masked
    let list = repo.query_items(&QueryFilter::default()).unwrap();
    assert_eq!(list.len(), 1);
    assert_eq!(list[0].summary, "••••••••");
    assert!(list[0].is_sensitive);

    // 2. Fetching detail decrypts plaintext
    let detail = repo.get_item_detail("id-secret").unwrap();
    assert_eq!(detail.raw_text, Some(token.to_string()));
    assert!(detail.is_sensitive);

    // 3. FTS search must NOT match the raw token
    let search_res = repo
        .query_items(&QueryFilter {
            search_query: Some("openai".to_string()),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(search_res.len(), 0);
}

#[test]
fn test_toggle_sensitive_cycles_encryption_fts_and_masking() {
    let (_f, repo) = create_test_repo();

    let secret_token = "df94e2db9bd390a1dc28792f6cee9434";
    let item = ClipItemSummary {
        id: "id-toggle-secret".to_string(),
        item_type: "text".to_string(),
        title: "".to_string(),
        summary: secret_token.to_string(),
        created_at: 100.0,
        last_used_at: 100.0,
        copy_count: 1,
        favorite: false,
        is_sensitive: false,
        ..Default::default()
    };

    repo.save_item(&item, Some(secret_token)).unwrap();

    // Initially non-sensitive and matches FTS search
    let initial_hits = repo
        .query_items(&QueryFilter {
            search_query: Some("df94e2db".to_string()),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(initial_hits.len(), 1);
    assert_eq!(initial_hits[0].is_sensitive, false);

    // 1. Toggle: Non-sensitive -> Sensitive
    let toggled = repo.toggle_sensitive("id-toggle-secret").unwrap();
    assert!(toggled.is_sensitive);
    assert_eq!(toggled.summary, "df94••••••••9434");

    // Detail can be decrypted back to the original secret
    let detail = repo.get_item_detail("id-toggle-secret").unwrap();
    assert!(detail.is_sensitive);
    assert_eq!(detail.raw_text.as_deref(), Some(secret_token));

    // FTS index must exclude the sensitive secret
    let search_sensitive = repo
        .query_items(&QueryFilter {
            search_query: Some("df94e2db".to_string()),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(search_sensitive.len(), 0);

    // 2. Toggle: Sensitive -> Non-sensitive (Unmask/revert)
    let reverted = repo.toggle_sensitive("id-toggle-secret").unwrap();
    assert!(!reverted.is_sensitive);
    assert_eq!(reverted.summary, secret_token);

    let reverted_detail = repo.get_item_detail("id-toggle-secret").unwrap();
    assert!(!reverted_detail.is_sensitive);
    assert_eq!(reverted_detail.raw_text.as_deref(), Some(secret_token));

    // FTS index restored and matches again
    let search_restored = repo
        .query_items(&QueryFilter {
            search_query: Some("df94e2db".to_string()),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(search_restored.len(), 1);
    assert_eq!(search_restored[0].id, "id-toggle-secret");
}

#[test]
fn test_toggle_sensitive_handles_non_text_and_missing_ciphertext_safely() {
    let (_f, repo) = create_test_repo();

    // 1. Image item: unmasking must NOT populate raw_text
    let img_item = ClipItemSummary {
        id: "id-img-toggle".to_string(),
        item_type: "image".to_string(),
        title: "".to_string(),
        summary: "Image 800×600".to_string(),
        created_at: 100.0,
        last_used_at: 100.0,
        copy_count: 1,
        favorite: false,
        is_sensitive: false,
        payload_path: Some("blobs/img.png".to_string()),
        ..Default::default()
    };
    repo.save_item(&img_item, None).unwrap();

    let toggled_img = repo.toggle_sensitive("id-img-toggle").unwrap();
    assert!(toggled_img.is_sensitive);

    let reverted_img = repo.toggle_sensitive("id-img-toggle").unwrap();
    assert!(!reverted_img.is_sensitive);
    assert_eq!(reverted_img.summary, "Image 800×600");
    let img_detail = repo.get_item_detail("id-img-toggle").unwrap();
    assert_eq!(img_detail.raw_text, None);

    // 2. Sensitive item saved without raw_text (missing ciphertext): unmasking must return Err and preserve summary
    let broken_sensitive = ClipItemSummary {
        id: "id-missing-cipher".to_string(),
        item_type: "text".to_string(),
        title: "".to_string(),
        summary: "df94••••••••9434".to_string(),
        created_at: 100.0,
        last_used_at: 100.0,
        copy_count: 1,
        favorite: false,
        is_sensitive: true,
        ..Default::default()
    };
    repo.save_item(&broken_sensitive, None).unwrap();
    assert!(repo.toggle_sensitive("id-missing-cipher").is_err());
    let after_err = repo
        .query_items(&QueryFilter {
            id: Some("id-missing-cipher".to_string()),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(after_err.len(), 1);
    assert!(after_err[0].is_sensitive);
    assert_eq!(after_err[0].summary, "df94••••••••9434");
}
