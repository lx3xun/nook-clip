use nookclip_core::storage::PayloadAssetStore;
use std::fs;
use tempfile::tempdir;

#[test]
fn test_payload_asset_store_deduplication_and_orphan_sweeping() {
    let dir = tempdir().unwrap();
    let store = PayloadAssetStore::new(dir.path()).unwrap();

    let data = b"identical PNG binary image data";
    let path1 = store.save_payload_asset(data, "png").unwrap();
    let path2 = store.save_payload_asset(data, "png").unwrap();

    // Idempotent & deduplicated: paths must be identical
    assert_eq!(path1, path2);

    // Only one file on disk
    let entries: Vec<_> = fs::read_dir(dir.path())
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().to_string())
        .collect();
    assert_eq!(entries.len(), 1);

    let saved_filename = &entries[0];
    assert!(saved_filename.ends_with(".png"));

    // Orphan sweep test: referenced file (using absolute path returned by save) is preserved
    let swept_none = store.sweep_orphans(std::slice::from_ref(&path1), 0.0).unwrap();
    assert_eq!(swept_none, 0, "Active file passed as absolute path must not be swept");
    // Unreferenced file swept if older than threshold
    let swept_one = store.sweep_orphans(&[], 0.0).unwrap();
    assert_eq!(swept_one, 1);

    let entries_after: Vec<_> = fs::read_dir(dir.path()).unwrap().collect();
    assert!(entries_after.is_empty());
}
