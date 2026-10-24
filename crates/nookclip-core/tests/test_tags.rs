//! 轻量标签（Tag）功能集成测试 —— 契约 `.tag-feature/CONTRACT.md` §1–§7。
//!
//! 覆盖：
//! 1. normalize_tag 行为（trim / 剥前导 # / 折叠空白 / 24 字截断 / 空→忽略 / 大小写去重）
//! 2. set_tags / add_tag / remove_tag / list_tags / rename_tag / delete_tag 的返回值与库内状态
//! 3. QueryFilter.tag 过滤；`#api` / `tag:x` 搜索命中；tag 与关键词 AND；关键词命中标签名
//! 4. 敏感条目：tags 可被搜索/过滤命中，正文/OCR 不进 FTS
//! 5. prune_expired / enforce_disk_limit 保护带标签条目
//! 6. sync tags LWW（reconcile_sync_items）；导入导出 round-trip

use nookclip_core::{
    exchange::{export, import},
    model::{ClipItemSummary, QueryFilter, RetentionConfig},
    storage::StorageRepository,
    sync::SyncItemRecord,
};
use std::collections::HashMap;
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

fn tags_of(repo: &StorageRepository, id: &str) -> Vec<String> {
    repo.query_items_by_ids(&[id.to_string()])
        .unwrap()
        .into_iter()
        .next()
        .map(|i| i.tags)
        .unwrap_or_default()
}

fn search_ids(repo: &StorageRepository, q: &str) -> Vec<String> {
    repo.query_items(&QueryFilter {
        search_query: Some(q.to_string()),
        ..Default::default()
    })
    .unwrap()
    .into_iter()
    .map(|i| i.id)
    .collect()
}

// ---------------------------------------------------------------------------
// 1. 规范化（通过 set_tags 观察归一化结果 —— normalize_tag 为 pub(crate)）
// ---------------------------------------------------------------------------

#[test]
fn normalize_trims_and_strips_leading_hashes() {
    let (_f, repo) = create_test_repo();
    repo.save_item(&dummy_item("i1", "Item", "text", 100.0), Some("x"))
        .unwrap();

    // 前后空白 + 单个 #
    let s = repo
        .set_tags("i1", &["  #api  ".to_string()])
        .unwrap();
    assert_eq!(s.tags, vec!["api".to_string()]);

    // 多个前导 #：##Api → Api
    let s = repo.set_tags("i1", &["##Api".to_string()]).unwrap();
    assert_eq!(s.tags, vec!["Api".to_string()]);

    // 折叠内部连续空白
    let s = repo
        .set_tags("i1", &["  foo   bar\tbaz ".to_string()])
        .unwrap();
    assert_eq!(s.tags, vec!["foo bar baz".to_string()]);
}

#[test]
fn normalize_truncates_to_24_scalars() {
    let (_f, repo) = create_test_repo();
    repo.save_item(&dummy_item("i1", "Item", "text", 100.0), Some("x"))
        .unwrap();

    // 30 个 ASCII 字符 → 截断到 24
    let long = "a".repeat(30);
    let s = repo.set_tags("i1", &[long.clone()]).unwrap();
    assert_eq!(s.tags[0].chars().count(), 24);
    assert_eq!(s.tags[0], "a".repeat(24));

    // 多字节不切坏：26 个中文字符 → 24 个
    let cjk = "标".repeat(26);
    let s = repo.set_tags("i1", &[cjk]).unwrap();
    assert_eq!(s.tags[0].chars().count(), 24);
    assert_eq!(s.tags[0], "标".repeat(24));
}

#[test]
fn normalize_empty_is_dropped_and_dedup_case_insensitive() {
    let (_f, repo) = create_test_repo();
    repo.save_item(&dummy_item("i1", "Item", "text", 100.0), Some("x"))
        .unwrap();

    let s = repo
        .set_tags(
            "i1",
            &[
                "".to_string(),
                "   ".to_string(),
                "#".to_string(),
                "Api".to_string(),
                "api".to_string(), // 大小写不敏感判重，保留首个
                "API".to_string(),
                "web".to_string(),
            ],
        )
        .unwrap();
    assert_eq!(s.tags, vec!["Api".to_string(), "web".to_string()]);
}

#[test]
fn normalize_caps_at_10_tags() {
    let (_f, repo) = create_test_repo();
    repo.save_item(&dummy_item("i1", "Item", "text", 100.0), Some("x"))
        .unwrap();

    let many: Vec<String> = (0..15).map(|i| format!("t{i}")).collect();
    let s = repo.set_tags("i1", &many).unwrap();
    assert_eq!(s.tags.len(), 10);
    assert_eq!(s.tags[0], "t0");
    assert_eq!(s.tags[9], "t9");
}

// ---------------------------------------------------------------------------
// 2. set/add/remove/list/rename/delete
// ---------------------------------------------------------------------------

#[test]
fn set_add_remove_reflect_in_store() {
    let (_f, repo) = create_test_repo();
    repo.save_item(&dummy_item("i1", "Item", "text", 100.0), Some("x"))
        .unwrap();

    let s = repo
        .set_tags("i1", &["a".to_string(), "b".to_string()])
        .unwrap();
    assert_eq!(s.tags, vec!["a".to_string(), "b".to_string()]);
    assert_eq!(tags_of(&repo, "i1"), vec!["a".to_string(), "b".to_string()]);

    // add 已存在（大小写不敏感）→ 不重复；add 新的 → 追加
    let s = repo.add_tag("i1", "A").unwrap();
    assert_eq!(s.tags, vec!["a".to_string(), "b".to_string()]);
    let s = repo.add_tag("i1", "#c").unwrap();
    assert_eq!(
        s.tags,
        vec!["a".to_string(), "b".to_string(), "c".to_string()]
    );

    // remove（大小写不敏感）
    let s = repo.remove_tag("i1", "B").unwrap();
    assert_eq!(s.tags, vec!["a".to_string(), "c".to_string()]);
    assert_eq!(tags_of(&repo, "i1"), vec!["a".to_string(), "c".to_string()]);

    // 全量替换为空
    let s = repo.set_tags("i1", &[]).unwrap();
    assert!(s.tags.is_empty());
}

#[test]
fn set_tags_missing_item_is_not_found() {
    let (_f, repo) = create_test_repo();
    assert!(repo.set_tags("nope", &["a".to_string()]).is_err());
    assert!(repo.add_tag("nope", "a").is_err());
    assert!(repo.remove_tag("nope", "a").is_err());
}

#[test]
fn list_tags_counts_undeleted_only_and_sorted() {
    let (_f, repo) = create_test_repo();
    repo.save_item(&dummy_item("i1", "A", "text", 100.0), Some("x"))
        .unwrap();
    repo.save_item(&dummy_item("i2", "B", "text", 200.0), Some("y"))
        .unwrap();
    repo.save_item(&dummy_item("i3", "C", "text", 300.0), Some("z"))
        .unwrap();

    repo.set_tags("i1", &["api".to_string(), "web".to_string()])
        .unwrap();
    repo.set_tags("i2", &["api".to_string()]).unwrap();
    repo.set_tags("i3", &["api".to_string()]).unwrap();

    // 软删除 i3 后，api 应从 3 降到 2
    repo.soft_delete("i3").unwrap();

    let stats = repo.list_tags().unwrap();
    let api = stats.iter().find(|t| t.name.eq_ignore_ascii_case("api")).unwrap();
    assert_eq!(api.count, 2, "已删除条目不应计入统计");
    let web = stats.iter().find(|t| t.name.eq_ignore_ascii_case("web")).unwrap();
    assert_eq!(web.count, 1);

    // count DESC：api(2) 在 web(1) 前面
    let api_pos = stats.iter().position(|t| t.name.eq_ignore_ascii_case("api")).unwrap();
    let web_pos = stats.iter().position(|t| t.name.eq_ignore_ascii_case("web")).unwrap();
    assert!(api_pos < web_pos);
}

#[test]
fn list_tags_groups_case_insensitively() {
    let (_f, repo) = create_test_repo();
    repo.save_item(&dummy_item("i1", "A", "text", 100.0), Some("x"))
        .unwrap();
    repo.save_item(&dummy_item("i2", "B", "text", 200.0), Some("y"))
        .unwrap();
    repo.set_tags("i1", &["Api".to_string()]).unwrap();
    repo.set_tags("i2", &["api".to_string()]).unwrap();

    let stats = repo.list_tags().unwrap();
    let entries: Vec<_> = stats
        .iter()
        .filter(|t| t.name.eq_ignore_ascii_case("api"))
        .collect();
    assert_eq!(entries.len(), 1, "大小写不同的同名标签应合并为一条统计");
    assert_eq!(entries[0].count, 2);
}

#[test]
fn rename_tag_merges_into_existing_and_returns_affected() {
    let (_f, repo) = create_test_repo();
    repo.save_item(&dummy_item("i1", "A", "text", 100.0), Some("x"))
        .unwrap();
    repo.save_item(&dummy_item("i2", "B", "text", 200.0), Some("y"))
        .unwrap();
    repo.set_tags("i1", &["old".to_string(), "keep".to_string()])
        .unwrap();
    repo.set_tags("i2", &["old".to_string(), "new".to_string()])
        .unwrap();

    let affected = repo.rename_tag("old", "new").unwrap();
    assert_eq!(affected, 2);

    // i1: old→new（本来没有 new） → [keep, new]
    assert_eq!(tags_of(&repo, "i1"), vec!["keep".to_string(), "new".to_string()]);
    // i2: 已有 new，old 合并进去，不重复 → [new]
    assert_eq!(tags_of(&repo, "i2"), vec!["new".to_string()]);

    assert!(repo.list_tags().unwrap().iter().all(|t| !t.name.eq_ignore_ascii_case("old")));
}

#[test]
fn rename_tag_noop_when_case_only_or_missing() {
    let (_f, repo) = create_test_repo();
    repo.save_item(&dummy_item("i1", "A", "text", 100.0), Some("x"))
        .unwrap();
    repo.set_tags("i1", &["api".to_string()]).unwrap();

    // 仅大小写差异：判重键相同 → 返回 0，不改动
    assert_eq!(repo.rename_tag("api", "API").unwrap(), 0);
    // 不存在
    assert_eq!(repo.rename_tag("ghost", "x").unwrap(), 0);
}

#[test]
fn delete_tag_detaches_but_keeps_items() {
    let (_f, repo) = create_test_repo();
    repo.save_item(&dummy_item("i1", "A", "text", 100.0), Some("x"))
        .unwrap();
    repo.save_item(&dummy_item("i2", "B", "text", 200.0), Some("y"))
        .unwrap();
    repo.set_tags("i1", &["gone".to_string(), "stay".to_string()])
        .unwrap();
    repo.set_tags("i2", &["gone".to_string()]).unwrap();

    let affected = repo.delete_tag("gone").unwrap();
    assert_eq!(affected, 2);

    // 条目仍在
    let all = repo.query_items(&QueryFilter::default()).unwrap();
    assert_eq!(all.len(), 2);
    // 标签已解除
    assert_eq!(tags_of(&repo, "i1"), vec!["stay".to_string()]);
    assert!(tags_of(&repo, "i2").is_empty());
}

// ---------------------------------------------------------------------------
// 3. 过滤与搜索
// ---------------------------------------------------------------------------

#[test]
fn filter_by_tag_equality_case_insensitive() {
    let (_f, repo) = create_test_repo();
    repo.save_item(&dummy_item("i1", "A", "text", 100.0), Some("x"))
        .unwrap();
    repo.save_item(&dummy_item("i2", "B", "text", 200.0), Some("y"))
        .unwrap();
    repo.set_tags("i1", &["Api".to_string()]).unwrap();
    repo.set_tags("i2", &["web".to_string()]).unwrap();

    let by_tag = repo
        .query_items(&QueryFilter {
            tag: Some("api".to_string()), // 小写也应命中存储的 "Api"
            ..Default::default()
        })
        .unwrap();
    assert_eq!(by_tag.len(), 1);
    assert_eq!(by_tag[0].id, "i1");

    // None / 空 = 不过滤
    let all = repo.query_items(&QueryFilter::default()).unwrap();
    assert_eq!(all.len(), 2);
    let all_empty = repo
        .query_items(&QueryFilter {
            tag: Some("   ".to_string()),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(all_empty.len(), 2);
}

#[test]
fn search_hash_and_tag_colon_tokens() {
    let (_f, repo) = create_test_repo();
    repo.save_item(&dummy_item("i1", "A", "text", 100.0), Some("x"))
        .unwrap();
    repo.save_item(&dummy_item("i2", "B", "text", 200.0), Some("y"))
        .unwrap();
    repo.set_tags("i1", &["api".to_string()]).unwrap();
    repo.set_tags("i2", &["web".to_string()]).unwrap();

    // `#api` 命中 i1
    assert_eq!(search_ids(&repo, "#api"), vec!["i1".to_string()]);
    // `tag:api` 命中 i1
    assert_eq!(search_ids(&repo, "tag:api"), vec!["i1".to_string()]);
}

#[test]
fn search_tag_and_combined_with_keyword() {
    let (_f, repo) = create_test_repo();
    repo.save_item(&dummy_item("i1", "rust notes", "text", 100.0), Some("x"))
        .unwrap();
    repo.save_item(&dummy_item("i2", "python notes", "text", 200.0), Some("y"))
        .unwrap();
    repo.set_tags("i1", &["api".to_string()]).unwrap();
    repo.set_tags("i2", &["api".to_string()]).unwrap();

    // tag + 关键词 AND：只有 i1 同时满足 tag=api 且含 "rust"
    assert_eq!(search_ids(&repo, "#api rust"), vec!["i1".to_string()]);

    // 多个 tag token = AND
    repo.set_tags("i1", &["api".to_string(), "urgent".to_string()])
        .unwrap();
    assert_eq!(
        search_ids(&repo, "#api #urgent"),
        vec!["i1".to_string()]
    );
}

#[test]
fn keyword_search_hits_tag_name() {
    let (_f, repo) = create_test_repo();
    // 标题/正文都不含 "kubernetes"，仅标签名含
    repo.save_item(&dummy_item("i1", "Notes", "text", 100.0), Some("hello"))
        .unwrap();
    repo.save_item(&dummy_item("i2", "Other", "text", 200.0), Some("world"))
        .unwrap();
    repo.set_tags("i1", &["kubernetes".to_string()]).unwrap();

    // FTS 长词（>=3 字符）应能命中 tags 列
    assert_eq!(search_ids(&repo, "kubernetes"), vec!["i1".to_string()]);
}

#[test]
fn tag_filter_combines_with_item_type() {
    let (_f, repo) = create_test_repo();
    repo.save_item(&dummy_item("i1", "A", "text", 100.0), Some("x"))
        .unwrap();
    repo.save_item(&dummy_item("i2", "B", "code", 200.0), Some("y"))
        .unwrap();
    repo.set_tags("i1", &["api".to_string()]).unwrap();
    repo.set_tags("i2", &["api".to_string()]).unwrap();

    let filtered = repo
        .query_items(&QueryFilter {
            tag: Some("api".to_string()),
            item_type: Some("code".to_string()),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(filtered.len(), 1);
    assert_eq!(filtered[0].id, "i2");
}

#[test]
fn count_categories_respects_tag() {
    let (_f, repo) = create_test_repo();
    repo.save_item(&dummy_item("i1", "A", "text", 100.0), Some("x"))
        .unwrap();
    repo.save_item(&dummy_item("i2", "B", "code", 200.0), Some("y"))
        .unwrap();
    repo.set_tags("i1", &["api".to_string()]).unwrap();

    let counts = repo.count_categories(None, Some("api")).unwrap();
    assert_eq!(counts.total, 1);
}

// ---------------------------------------------------------------------------
// 4. 敏感条目：tags 可搜索，正文/OCR 不进 FTS
// ---------------------------------------------------------------------------

#[test]
fn sensitive_item_tags_searchable_but_body_not_indexed() {
    let (_f, repo) = create_test_repo();
    let mut item = dummy_item("s1", "Secret Window", "text", 100.0);
    item.is_sensitive = true;
    // 正文 / OCR 含独特词 SECRETBODY，不应能被普通关键词搜到
    item.summary = "SECRETBODY confidential".to_string();
    repo.save_item(&item, Some("SECRETBODY confidential")).unwrap();
    repo.update_ocr_text("s1", "OCRTOKEN unique").unwrap();

    repo.add_tag("s1", "vault").unwrap();

    // tags 可被搜索/过滤命中
    assert_eq!(search_ids(&repo, "#vault"), vec!["s1".to_string()]);
    assert_eq!(
        repo.query_items(&QueryFilter {
            tag: Some("vault".to_string()),
            ..Default::default()
        })
        .unwrap()
        .len(),
        1
    );

    // 敏感正文 / OCR 不得经 FTS 被关键词命中
    assert!(
        search_ids(&repo, "SECRETBODY").is_empty(),
        "敏感条目正文不应进入 FTS"
    );
    assert!(
        search_ids(&repo, "OCRTOKEN").is_empty(),
        "敏感条目 OCR 不应进入 FTS"
    );

    // 直接校验 FTS 行：敏感条目的 summary / ocr_text 列为空，tags 列有值
    let conn = rusqlite::Connection::open(_f.path()).unwrap();
    let (summary, ocr, tags): (String, String, String) = conn
        .query_row(
            "SELECT summary, ocr_text, tags FROM clip_fts WHERE clip_id = 's1'",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .unwrap();
    assert_eq!(summary, "", "敏感条目 summary 不应写入 FTS");
    assert_eq!(ocr, "", "敏感条目 ocr 不应写入 FTS");
    assert!(tags.contains("vault"), "tags 应写入 FTS");
}

// ---------------------------------------------------------------------------
// 5. 生命周期保护：prune / disk_limit 不清带标签条目
// ---------------------------------------------------------------------------

#[test]
fn prune_by_age_protects_tagged_items() {
    let (_f, repo) = create_test_repo();
    // 两条都很老，只有一条带标签
    repo.save_item(&dummy_item("tagged", "Tagged Old", "text", 1.0), Some("x"))
        .unwrap();
    repo.save_item(&dummy_item("plain", "Plain Old", "text", 1.0), Some("y"))
        .unwrap();
    repo.add_tag("tagged", "keep").unwrap();

    let pruned = repo
        .prune_expired(&RetentionConfig {
            max_age_days: Some(1),
            max_item_count: None,
        })
        .unwrap();
    let pruned_ids: Vec<&str> = pruned.iter().map(|r| r.id.as_str()).collect();
    assert!(pruned_ids.contains(&"plain"), "无标签超龄条目应被清理");
    assert!(!pruned_ids.contains(&"tagged"), "带标签条目应受保护");

    let remaining: Vec<String> = repo
        .query_items(&QueryFilter::default())
        .unwrap()
        .into_iter()
        .map(|i| i.id)
        .collect();
    assert_eq!(remaining, vec!["tagged".to_string()]);
}

#[test]
fn prune_by_count_protects_tagged_items() {
    let (_f, repo) = create_test_repo();
    // 三条，最老的带标签
    repo.save_item(&dummy_item("tagged-oldest", "T", "text", 1.0), Some("x"))
        .unwrap();
    repo.save_item(&dummy_item("mid", "M", "text", 2.0), Some("y"))
        .unwrap();
    repo.save_item(&dummy_item("new", "N", "text", 3.0), Some("z"))
        .unwrap();
    repo.add_tag("tagged-oldest", "keep").unwrap();

    // max_item_count=1 → 需要删 2 条（最老的优先），但带标签的不动
    let pruned = repo
        .prune_expired(&RetentionConfig {
            max_age_days: None,
            max_item_count: Some(1),
        })
        .unwrap();
    let pruned_ids: Vec<&str> = pruned.iter().map(|r| r.id.as_str()).collect();
    assert!(!pruned_ids.contains(&"tagged-oldest"), "带标签条目应受保护");
    // 因保护，实际只能删掉 mid（new 需保留到 1 条），tagged-oldest 保留
    assert!(tags_of(&repo, "tagged-oldest").contains(&"keep".to_string()));
}

#[test]
fn disk_limit_protects_tagged_items() {
    let (_f, repo) = create_test_repo();
    let dir = tempfile::tempdir().unwrap();
    let managed = dir.path().to_str().unwrap();
    repo.set_assets_dir(Some(managed));

    // 构造带载荷文件的条目（image 类型，payload_path 指向 managed 目录内文件）
    let mut tagged = dummy_item("tagged", "Tagged", "image", 1.0);
    tagged.payload_path = Some(format!("{managed}/tagged.bin"));
    let mut plain = dummy_item("plain", "Plain", "image", 2.0);
    plain.payload_path = Some(format!("{managed}/plain.bin"));
    repo.save_item(&tagged, None).unwrap();
    repo.save_item(&plain, None).unwrap();

    // 写两文件，共 2000 字节
    std::fs::write(format!("{managed}/tagged.bin"), vec![0u8; 1000]).unwrap();
    std::fs::write(format!("{managed}/plain.bin"), vec![0u8; 1000]).unwrap();

    repo.add_tag("tagged", "keep").unwrap();

    // 限额 1000：需驱逐约 1000 字节。plain 更旧（last_used=2.0）?? 实际 plain last_used 更大。
    // 设计：tagged 更旧但带标签受保护，故只能驱逐 plain。
    let blocked = repo.enforce_disk_limit(managed, 1000).unwrap();
    let evicted: Vec<&str> = blocked.iter().map(|r| r.id.as_str()).collect();
    assert!(!evicted.contains(&"tagged"), "带标签条目不应被磁盘驱逐");
    // 带标签条目仍在
    assert!(tags_of(&repo, "tagged").contains(&"keep".to_string()));
}

// ---------------------------------------------------------------------------
// 6. 同步 tags LWW + 导入导出 round-trip
// ---------------------------------------------------------------------------

fn sync_record(id: &str, summary: &str, tags: &[&str], tags_updated_at: f64) -> SyncItemRecord {
    SyncItemRecord {
        id: id.to_string(),
        item_type: "text".to_string(),
        title: format!("title {id}"),
        summary: summary.to_string(),
        raw_text: Some(summary.to_string()),
        is_sensitive: false,
        is_favorite: false,
        created_at: 100.0,
        last_used_at: 100.0,
        updated_at: 100.0,
        favorite_updated_at: 0.0,
        copy_count: 1,
        asset_file_name: None,
        deleted_at: None,
        source_app_bundle_id: None,
        source_app_name: None,
        source_device_id: None,
        source_device_name: None,
        source_platform: None,
        tags: tags.iter().map(|s| s.to_string()).collect(),
        tags_updated_at,
    }
}

#[test]
fn sync_newer_tags_win_lww() {
    let (_f, repo) = create_test_repo();
    // 先本地存一条并打标签，tags_updated_at 由 set_tags 推进到 now（很大）
    repo.save_item(&dummy_item("i1", "Item", "text", 100.0), Some("x"))
        .unwrap();
    repo.set_tags("i1", &["local".to_string()]).unwrap();
    let local_ts = {
        let conn = rusqlite::Connection::open(_f.path()).unwrap();
        let ts: f64 = conn
            .query_row("SELECT tags_updated_at FROM clip_items WHERE id='i1'", [], |r| r.get(0))
            .unwrap();
        ts
    };

    // 远端更旧 → 不应覆盖
    let older = sync_record("i1", "x", &["remote-old"], local_ts - 100.0);
    repo.reconcile_sync_items(&[older], &HashMap::new()).unwrap();
    assert_eq!(tags_of(&repo, "i1"), vec!["local".to_string()]);

    // 远端更新 → 覆盖
    let newer = sync_record("i1", "x", &["remote-new"], local_ts + 100.0);
    repo.reconcile_sync_items(&[newer], &HashMap::new()).unwrap();
    assert_eq!(tags_of(&repo, "i1"), vec!["remote-new".to_string()]);
}

#[test]
fn sync_legacy_remote_tags_take_effect_when_local_empty() {
    // 旧 pack：双方 tags_updated_at 均为 0，本地无标签，远端有 → 取远端
    let (_f, repo) = create_test_repo();
    repo.save_item(&dummy_item("i9", "Legacy", "text", 100.0), Some("x"))
        .unwrap();
    // 让本地 tags_updated_at 保持 0（不调用 set_tags/add_tag）
    let remote = sync_record("i9", "x", &["legacy-tag"], 0.0);
    repo.reconcile_sync_items(&[remote], &HashMap::new()).unwrap();
    assert_eq!(tags_of(&repo, "i9"), vec!["legacy-tag".to_string()]);
}

#[test]
fn sync_new_item_carries_tags_and_fts() {
    let (_f, repo) = create_test_repo();
    // 全新远端条目（本地没有）→ 应写入标签 + FTS tags
    let remote = sync_record("fresh", "fresh content", &["synctag"], 500.0);
    repo.reconcile_sync_items(&[remote], &HashMap::new()).unwrap();
    assert_eq!(tags_of(&repo, "fresh"), vec!["synctag".to_string()]);
    assert_eq!(search_ids(&repo, "#synctag"), vec!["fresh".to_string()]);
}

#[test]
fn export_import_roundtrip_preserves_tags() {
    let (_f, repo) = create_test_repo();
    repo.save_item(&dummy_item("e1", "Export Me", "text", 100.0), Some("body1"))
        .unwrap();
    repo.set_tags("e1", &["api".to_string(), "web".to_string()])
        .unwrap();

    let json = export::export_json(&repo, export::SensitiveExportMode::Exclude).unwrap();
    assert!(json.contains("api"), "导出 JSON 应包含 tags");

    // 导入到全新库
    let (_f2, repo2) = create_test_repo();
    let report = import::import_json(&repo2, &json).unwrap();
    assert_eq!(report.imported_count, 1);

    let tags = tags_of(&repo2, "e1");
    assert_eq!(tags, vec!["api".to_string(), "web".to_string()]);
    // 导入后 tag 过滤/搜索应生效
    assert_eq!(
        repo2
            .query_items(&QueryFilter {
                tag: Some("api".to_string()),
                ..Default::default()
            })
            .unwrap()
            .len(),
        1
    );
    assert_eq!(search_ids(&repo2, "#web"), vec!["e1".to_string()]);
}

#[test]
fn export_markdown_includes_tags_line() {
    let (_f, repo) = create_test_repo();
    repo.save_item(&dummy_item("m1", "Md Item", "text", 100.0), Some("body"))
        .unwrap();
    repo.set_tags("m1", &["alpha".to_string(), "beta".to_string()])
        .unwrap();

    let md = export::export_markdown(&repo, export::SensitiveExportMode::Exclude).unwrap();
    assert!(md.contains("Tags: alpha, beta"), "Markdown 导出应含 Tags 行: {md}");
}
