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

fn image_item(id: &str) -> ClipItemSummary {
    ClipItemSummary {
        id: id.to_string(),
        item_type: "image".to_string(),
        title: "Screenshot".to_string(),
        summary: "800x600 image".to_string(),
        created_at: 100.0,
        last_used_at: 100.0,
        copy_count: 1,
        is_sensitive: false,
        ..Default::default()
    }
}

fn search(repo: &StorageRepository, q: &str) -> Vec<String> {
    repo.query_items(&QueryFilter {
        search_query: Some(q.to_string()),
        ..Default::default()
    })
    .unwrap()
    .into_iter()
    .map(|i| i.id)
    .collect()
}

/// P0 回归：敏感条目的 OCR 文本不得以明文落盘。
///
/// 旧实现 `toggle_sensitive` 只加密 raw_text/summary，`ocr_text` 列原样保留明文；
/// 且 `update_ocr_text` 对敏感条目也直接写明文列。
#[test]
fn sensitive_item_ocr_text_is_never_stored_in_plaintext() {
    let (f, repo) = create_test_repo();
    repo.save_item(&image_item("img-ocr-secret"), None).unwrap();
    repo.update_ocr_text("img-ocr-secret", "CONFIDENTIAL acct 9876543210")
        .unwrap();

    // 转为敏感：明文列必须清空，OCR 文本迁入密文列
    repo.toggle_sensitive("img-ocr-secret").unwrap();
    {
        let conn = rusqlite::Connection::open(f.path()).unwrap();
        type Blob = Option<Vec<u8>>;
        let (ocr_text, ocr_enc, raw_text, enc): (Option<String>, Blob, Option<String>, Blob) = conn
            .query_row(
                "SELECT cp.ocr_text, cp.ocr_encrypted, cp.raw_text, cp.encrypted_content \
                 FROM clip_payloads cp WHERE cp.id = 'img-ocr-secret'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .unwrap();
        assert!(ocr_text.is_none(), "敏感条目的 OCR 明文列必须为 NULL，实际 {:?}", ocr_text);
        assert!(ocr_enc.is_some(), "OCR 文本必须以密文保存");
        assert!(raw_text.is_none(), "敏感条目正文明文列必须为 NULL");
        assert!(enc.is_some());
    }

    // 已敏感条目再次 OCR：仍然只能进密文列
    repo.update_ocr_text("img-ocr-secret", "second secret 1122334455")
        .unwrap();
    {
        let conn = rusqlite::Connection::open(f.path()).unwrap();
        let ocr_text: Option<String> = conn
            .query_row(
                "SELECT ocr_text FROM clip_payloads WHERE id = 'img-ocr-secret'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert!(ocr_text.is_none(), "敏感条目二次 OCR 不得写明文列");
    }

    // 详情仍可读回（经解密），保证功能未丢失
    let detail = repo.get_item_detail("img-ocr-secret").unwrap();
    assert_eq!(detail.ocr_text.as_deref(), Some("second secret 1122334455"));
    assert!(detail.is_sensitive);
}

/// P0 回归：短词 LIKE 回退不得成为敏感正文的检索旁路。
///
/// 旧实现的 LIKE 条件里 `cp.ocr_text LIKE ?` 没有 `is_sensitive = 0` 保护：
/// 4 字符以上走 FTS（敏感条目被排除，0 命中），2 字符却走 LIKE 命中敏感正文。
#[test]
fn short_token_search_cannot_probe_sensitive_content() {
    let (_f, repo) = create_test_repo();
    repo.save_item(&image_item("img-probe"), None).unwrap();
    repo.update_ocr_text("img-probe", "CONFIDENTIAL acct 9876543210")
        .unwrap();
    repo.toggle_sensitive("img-probe").unwrap();

    // 长词走 FTS：敏感条目本就不入索引
    assert!(search(&repo, "9876543210").is_empty(), "FTS 路径不得命中敏感正文");
    // 短词走 LIKE：修复前这里会命中
    assert!(search(&repo, "98").is_empty(), "短词 LIKE 回退不得命中敏感 OCR 正文");
    assert!(search(&repo, "CONFIDENTIAL").is_empty(), "短词 LIKE 回退不得命中敏感 OCR 正文");
}

/// 解除敏感后 OCR 文本回到明文列，且可被搜索命中（功能不因加密而丢失）。
#[test]
fn unsensitive_restores_ocr_text_and_searchability() {
    let (f, repo) = create_test_repo();
    repo.save_item(&image_item("img-roundtrip"), None).unwrap();
    repo.update_ocr_text("img-roundtrip", "Invoice Number 55501")
        .unwrap();
    repo.toggle_sensitive("img-roundtrip").unwrap();
    repo.toggle_sensitive("img-roundtrip").unwrap();

    let detail = repo.get_item_detail("img-roundtrip").unwrap();
    assert_eq!(detail.ocr_text.as_deref(), Some("Invoice Number 55501"));
    assert!(!detail.is_sensitive);

    {
        let conn = rusqlite::Connection::open(f.path()).unwrap();
        let (ocr_text, ocr_enc): (Option<String>, Option<Vec<u8>>) = conn
            .query_row(
                "SELECT ocr_text, ocr_encrypted FROM clip_payloads WHERE id = 'img-roundtrip'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(ocr_text.as_deref(), Some("Invoice Number 55501"));
        assert!(ocr_enc.is_none(), "解除敏感后密文列必须清空");
    }
    assert_eq!(search(&repo, "55501"), vec!["img-roundtrip".to_string()]);
}

/// LIKE 通配符必须转义：搜 `_` / `%` 不得退化为「匹配全库」。
#[test]
fn like_fallback_escapes_wildcards() {
    let (_f, repo) = create_test_repo();
    let mut a = image_item("id-underscore");
    a.summary = "abc_def".to_string();
    let mut b = image_item("id-plain");
    b.summary = "abcdef".to_string();
    repo.save_item(&a, None).unwrap();
    repo.save_item(&b, None).unwrap();

    // 1 字符 token 走 LIKE。`_` 若未转义会匹配任意单字符 → 两条都命中；
    // 转义后只命中真正含下划线的那条。
    assert_eq!(
        search(&repo, "_"),
        vec!["id-underscore".to_string()],
        "下划线必须按字面匹配，不得退化为通配符"
    );
    assert!(search(&repo, "%").is_empty(), "百分号必须按字面匹配");
    assert_eq!(search(&repo, "c_d"), vec!["id-underscore".to_string()]);
}
