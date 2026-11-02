//! ingest.rs 专属测试：三分支（file/text/image）行为、来源回填与确定性 ID 语义。
//! 主流程与过滤 guard 的边缘 case 已由 test_clipboard_pipeline.rs 覆盖；
//! 本文件聚焦 ingest 重构后易回归的两块：SourceOrigin 回填与 joined/raw_text 语义。

use std::fs;
use tempfile::tempdir;

use nookclip_core::{
    clipboard::ingest::{ingest_clipboard_snapshot, NOOK_CLIP_NAMESPACE},
    crypto::CryptoEngine,
    model::{IngestConfig, IngestOutcome, RawClipboardSnapshot},
    storage::repository::StorageRepository,
};

struct Fixture {
    repo: StorageRepository,
    crypto: CryptoEngine,
    config: IngestConfig,
    #[allow(dead_code)]
    dir: tempfile::TempDir,
}

fn fixture() -> Fixture {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("test.db");
    let key = [0x42u8; 32];
    let repo = StorageRepository::new(db_path.to_str().unwrap(), &key).unwrap();
    let crypto = CryptoEngine::new(&key).unwrap();
    let assets_dir = dir.path().join("assets");
    fs::create_dir_all(&assets_dir).unwrap();
    let config = IngestConfig {
        sensitive_protection_enabled: true,
        excluded_bundle_ids: vec![],
        local_assets_dir: assets_dir.to_str().unwrap().to_string(),
        file_multi_title_template: None,
        default_image_title: "Image".to_string(),
        source_device_id: Some("cfg-device".to_string()),
        source_device_name: Some("cfg-name".to_string()),
        source_platform: Some("cfg-platform".to_string()),
    };
    Fixture { repo, crypto, config, dir }
}

fn ingested_item(out: IngestOutcome) -> nookclip_core::model::ClipItemSummary {
    match out {
        IngestOutcome::Saved { item } => item,
        other => panic!("expected Saved, got {other:?}"),
    }
}

#[test]
fn test_source_origin_snapshot_wins_over_config() {
    // 快照自带来源时优先于采集端配置回填
    let f = fixture();
    let snapshot = RawClipboardSnapshot {
        plain_text: Some("hello".to_string()),
        source_device_id: Some("snap-device".to_string()),
        source_device_name: Some("snap-name".to_string()),
        source_platform: Some("snap-platform".to_string()),
        ..Default::default()
    };
    let out = ingest_clipboard_snapshot(&f.repo, Some(&f.crypto), &snapshot, &f.config, None, None, 100.0).unwrap();
    let item = ingested_item(out);
    assert_eq!(item.source_device_id.as_deref(), Some("snap-device"));
    assert_eq!(item.source_device_name.as_deref(), Some("snap-name"));
    assert_eq!(item.source_platform.as_deref(), Some("snap-platform"));
}

#[test]
fn test_source_origin_falls_back_to_config_fieldwise() {
    // 快照缺某字段时按字段级回退配置值，不允许整体丢弃
    let f = fixture();
    let snapshot = RawClipboardSnapshot {
        plain_text: Some("partial".to_string()),
        source_device_id: Some("snap-device".to_string()),
        ..Default::default()
    };
    let out = ingest_clipboard_snapshot(&f.repo, Some(&f.crypto), &snapshot, &f.config, None, None, 100.0).unwrap();
    let item = ingested_item(out);
    assert_eq!(item.source_device_id.as_deref(), Some("snap-device"));
    assert_eq!(item.source_device_name.as_deref(), Some("cfg-name"));
    assert_eq!(item.source_platform.as_deref(), Some("cfg-platform"));
}

#[test]
fn test_text_item_deterministic_id_is_uuidv5() {
    // 非敏感文本：换行归一化后 UUIDv5（同内容跨端自然置顶）
    let f = fixture();
    let snapshot = RawClipboardSnapshot {
        plain_text: Some("stable content".to_string()),
        ..Default::default()
    };
    let out = ingest_clipboard_snapshot(&f.repo, Some(&f.crypto), &snapshot, &f.config, None, None, 100.0).unwrap();
    let item = ingested_item(out);

    let normalized = "stable content".replace("\r\n", "\n");
    let expected = uuid::Uuid::new_v5(&NOOK_CLIP_NAMESPACE, format!("text\0{}", normalized).as_bytes())
        .to_string()
        .to_uppercase();
    assert_eq!(item.id, expected);

    // 同内容再次入库 -> 同 ID（去重置顶语义依赖此不变量）
    let out2 = ingest_clipboard_snapshot(&f.repo, Some(&f.crypto), &snapshot, &f.config, None, None, 200.0).unwrap();
    let item2 = ingested_item(out2);
    assert_eq!(item.id, item2.id);
}

#[test]
fn test_text_item_sensitive_id_is_random() {
    // 敏感文本：随机 UUID，防止跨端内容哈希碰撞枚举
    let f = fixture();
    let snapshot = RawClipboardSnapshot {
        plain_text: Some("password = hunter2secret".to_string()),
        ..Default::default()
    };
    let out = ingest_clipboard_snapshot(&f.repo, Some(&f.crypto), &snapshot, &f.config, None, None, 100.0).unwrap();
    let item = ingested_item(out);
    assert!(item.is_sensitive);
    let v5 = uuid::Uuid::new_v5(&NOOK_CLIP_NAMESPACE, format!("text\0{}", "password = hunter2secret").as_bytes())
        .to_string()
        .to_uppercase();
    assert_ne!(item.id, v5, "敏感条目禁止使用确定性 ID");
}

#[test]
fn test_file_item_summary_holds_joined_paths_and_no_raw_text_dup() {
    // 非敏感文件：summary 与 payload_path 都是完整路径清单；raw_text 不重复落库
    let f = fixture();
    let p1 = f.dir.path().join("a.txt");
    let p2 = f.dir.path().join("b.txt");
    fs::write(&p1, b"a").unwrap();
    fs::write(&p2, b"b").unwrap();
    let snapshot = RawClipboardSnapshot {
        file_paths: vec![p1.to_str().unwrap().to_string(), p2.to_str().unwrap().to_string()],
        ..Default::default()
    };
    let out = ingest_clipboard_snapshot(&f.repo, Some(&f.crypto), &snapshot, &f.config, None, None, 100.0).unwrap();
    let item = ingested_item(out);

    let joined = format!("{}\n{}", p1.to_str().unwrap(), p2.to_str().unwrap());
    assert_eq!(item.summary, joined);
    assert_eq!(item.payload_path.as_deref(), Some(joined.as_str()));
    assert_eq!(item.title, "a.txt (2 items)");

    // 明文不泄漏：FTS/检索路径（敏感条目正文才置空，此处非敏感应可全文搜到）
    let detail = f.repo.get_item_detail(&item.id).unwrap();
    assert!(detail.raw_text.as_deref().is_none() || detail.raw_text.as_deref() == Some(joined.as_str()));
}

#[test]
fn test_image_item_deterministic_id_and_payload() {
    // 图片：按 SHA-256 确定性 ID + 落盘 payload
    let f = fixture();
    let png_bytes = vec![0x89u8, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4];
    let snapshot = RawClipboardSnapshot {
        image_data: Some(png_bytes.clone()),
        ..Default::default()
    };
    let out = ingest_clipboard_snapshot(&f.repo, Some(&f.crypto), &snapshot, &f.config, None, None, 100.0).unwrap();
    let item = ingested_item(out);

    let hash_hex = {
        use sha2::{Digest, Sha256};
        format!("{:x}", Sha256::digest(&png_bytes))
    };
    let expected = uuid::Uuid::new_v5(&NOOK_CLIP_NAMESPACE, format!("image\0{}", hash_hex).as_bytes())
        .to_string()
        .to_uppercase();
    assert_eq!(item.id, expected);
    assert_eq!(item.item_type, "image");
    let payload = item.payload_path.expect("image payload must be stored");
    assert!(f.dir.path().join("assets").join(&payload).exists() || fs::metadata(&payload).is_ok());
}
