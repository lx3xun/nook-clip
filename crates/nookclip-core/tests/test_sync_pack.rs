use nookclip_core::sync::{DeviceSyncPack, SyncItemRecord};

#[test]
fn test_sync_pack_serialization_and_compression_roundtrip() {
    let item1 = SyncItemRecord {
        id: "id-sync-1".to_string(),
        item_type: "text".to_string(),
        title: "Pack Item 1".to_string(),
        summary: "Summary 1".to_string(),
        raw_text: Some("Full content 1".to_string()),
        is_sensitive: false,
        is_favorite: true,
        created_at: 100.0,
        last_used_at: 200.0,
        updated_at: 200.0,
        favorite_updated_at: 0.0,
        copy_count: 3,
        asset_file_name: None,
        deleted_at: None,
        source_app_bundle_id: Some("com.apple.Safari".to_string()),
        source_app_name: Some("Safari".to_string()),
        source_device_id: Some("mac-1".to_string()),
        source_device_name: Some("MacBook Pro".to_string()),
        source_platform: Some("macos".to_string()),
        tags: vec!["api".to_string(), "work".to_string()],
        tags_updated_at: 123.0,
    };

    let item2 = SyncItemRecord {
        id: "id-sync-2".to_string(),
        item_type: "code".to_string(),
        title: "fn main()".to_string(),
        summary: "fn main() { println!(\"hello\"); }".to_string(),
        raw_text: Some("fn main() { println!(\"hello\"); }".to_string()),
        is_sensitive: false,
        is_favorite: false,
        created_at: 300.0,
        last_used_at: 400.0,
        updated_at: 400.0,
        favorite_updated_at: 0.0,
        copy_count: 1,
        asset_file_name: Some("abc123.png".to_string()),
        deleted_at: Some(500.0), // tombstone
        source_app_bundle_id: None,
        source_app_name: None,
        source_device_id: None,
        source_device_name: None,
        source_platform: None,
        tags: Vec::new(),
        tags_updated_at: 0.0,
    };

    let pack = DeviceSyncPack::new(
        "device-macbook-pro".to_string(),
        vec![item1.clone(), item2.clone()],
    );
    assert_eq!(pack.schema_version, nookclip_core::sync::pack::SYNC_PACK_SCHEMA_VERSION);
    assert_eq!(pack.device_id, "device-macbook-pro");
    assert_eq!(pack.items.len(), 2);

    let compressed = pack
        .serialize_compressed()
        .expect("serialization should succeed");
    assert!(!compressed.is_empty());

    let restored =
        DeviceSyncPack::deserialize_compressed(&compressed).expect("decompression should succeed");
    assert_eq!(restored.schema_version, pack.schema_version);
    assert_eq!(restored.device_id, pack.device_id);
    assert_eq!(restored.items, pack.items);
}
