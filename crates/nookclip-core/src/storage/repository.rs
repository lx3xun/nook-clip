use parking_lot::Mutex;
use rusqlite::{params, Connection, OptionalExtension};
use std::collections::HashMap;
use std::sync::Arc;

use crate::{
    crypto::CryptoEngine,
    error::{CoreError, Result},
    model::{ClipItemDetail, ClipItemSummary, PrunedItemRecord, QueryFilter, RetentionConfig, TagStat},
    storage::{payload_asset::PayloadAssetStore, schema::initialize_database},
};
use std::path::{Path, PathBuf};

/// 单条目最多保留的标签数（超出部分忽略）。
const MAX_TAGS_PER_ITEM: usize = 10;
/// 单个标签最大字符数（Unicode scalar 计）。
const MAX_TAG_CHARS: usize = 24;

/// 把一组标签拼成 FTS `tags` 列内容（空格分隔）。
fn tags_fts_text(tags: &[String]) -> String {
    tags.join(" ")
}

/// 批量读取一批 clip_id 的标签（一次 IN 查询，避免 N+1）。
/// 返回 `clip_id -> Vec<tag>`（每行内按 created_at 升序，再按 tag 升序兜底）。
/// 指定个数的占位符直接内联（标签读取为批量短 id 集合，远小于 SQLite 变量上限）。
fn load_tags_for(conn: &Connection, ids: &[String]) -> Result<HashMap<String, Vec<String>>> {
    let mut map: HashMap<String, Vec<String>> = HashMap::new();
    if ids.is_empty() {
        return Ok(map);
    }
    let placeholders = vec!["?"; ids.len()].join(",");
    let sql = format!(
        "SELECT clip_id, tag FROM clip_tags WHERE clip_id IN ({placeholders}) \
         ORDER BY clip_id, created_at ASC, tag ASC"
    );
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map(rusqlite::params_from_iter(ids.iter()), |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    })?;
    for r in rows {
        let (clip_id, tag) = r?;
        map.entry(clip_id).or_default().push(tag);
    }
    Ok(map)
}

/// 对一批已映射的摘要批量回填标签（一次 IN 查询后按 id 分派）。
fn attach_tags(conn: &Connection, items: &mut [ClipItemSummary]) -> Result<()> {
    if items.is_empty() {
        return Ok(());
    }
    let ids: Vec<String> = items.iter().map(|i| i.id.clone()).collect();
    let mut map = load_tags_for(conn, &ids)?;
    for item in items.iter_mut() {
        if let Some(tags) = map.remove(&item.id) {
            item.tags = tags;
        }
    }
    Ok(())
}

pub struct StorageRepository {
    conn: Arc<Mutex<Connection>>,
    crypto: CryptoEngine,
    assets_dir: Mutex<Option<PathBuf>>,
}

/// 时间锚点聚合所需的时区边界（由调用方按 CalendarContext 的目标时区算好）。
/// SQLite 自身无时区概念，所有本地日/周/月边界都以 Unix 秒传入。
pub struct TimelineBoundaries {
    /// 今天 00:00（本地）对应的 Unix 秒
    pub today_start: f64,
    /// 昨天 00:00（本地）
    pub yesterday_start: f64,
    /// 本周起始（本地，按 first_weekday）
    pub this_week_start: f64,
    /// 上周起始（本地，按 first_weekday）
    pub last_week_start: f64,
    /// 当前本地年份（区分「本年度月份桶」与「更早年度年桶」）
    pub current_year: i32,
    /// 本地月份起点，按时间降序 (year, month, start_unix_secs)
    pub month_starts: Vec<(i32, u32, f64)>,
}

/// 时间锚点计数行：第一行为「今天/昨天/本周/上周」四个近端计数，
/// 其余每行一个更早的本地月份桶（year/month/year_count）。
pub struct AnchorCountRow {
    pub today_count: u32,
    pub yesterday_count: u32,
    pub this_week_count: u32,
    pub last_week_count: u32,
    pub last_used_at: f64,
    pub year: Option<i32>,
    pub month: Option<u32>,
    pub year_count: u32,
}

/// 派生分类（kind）过滤：query_items 与 time_group_timestamps 共用。
/// 入库与迁移时已将 classify_kind 结果持久化到 clip_items.kind（code/json 归一为 'code'），
/// 查询与时间戳聚合直接走 idx_clip_items_kind 索引，O(log N) 完成过滤。
struct DerivedKindFilter {
    kind: Option<String>,
}

impl DerivedKindFilter {
    fn new(kind: Option<&str>) -> Self {
        let kind = kind.map(str::to_ascii_lowercase);
        Self { kind }
    }

    fn push_sql_conditions(&self, conditions: &mut Vec<String>) {
        match self.kind.as_deref() {
            Some("sensitive") => conditions.push("ci.is_sensitive = 1".to_string()),
            Some("text") => conditions.push("ci.kind = 'text'".to_string()),
            Some("code" | "json") => conditions.push("ci.kind IN ('code', 'json')".to_string()),
            Some("color") => conditions.push("ci.kind = 'color'".to_string()),
            Some("image") => conditions.push("ci.kind = 'image'".to_string()),
            Some("file") => conditions.push("ci.kind = 'file'".to_string()),
            Some("url") => conditions.push("ci.kind = 'url'".to_string()),
            _ => {}
        }
    }
}

/// `clip_items ci LEFT JOIN clip_payloads cp` 的摘要投影列。
/// 顺序必须与 [`map_summary_row`] 的索引严格一致；四处查询（分页 / 按 id 批量 /
/// 单条回读 / save 回显）共用这一份定义，避免列序漂移导致映射错位。
/// 第 4 列（索引 3）由调用方决定摘要表达式（原文 / 截断前缀 / COALESCE 全文）。
const SUMMARY_COLUMN_TAIL: &str = "ci.created_at, ci.last_used_at, ci.copy_count, ci.favorite, \
     ci.source_app_bundle_id, ci.source_app_name, ci.is_sensitive, ci.deleted_at, ci.payload_path, \
     cp.ocr_text, cp.metadata_json, ci.kind, ci.source_device_id, ci.source_device_name, ci.source_platform";

fn summary_columns(summary_expr: &str) -> String {
    format!("ci.id, ci.item_type, ci.title, {summary_expr}, {SUMMARY_COLUMN_TAIL}")
}

/// 单行 → ClipItemSummary。列序见 [`summary_columns`]。
fn map_summary_row(row: &rusqlite::Row<'_>, assets_dir: Option<&Path>) -> rusqlite::Result<ClipItemSummary> {
    let item_type: String = row.get(1)?;
    let stored_path: Option<String> = row.get(12)?;
    let resolved_path =
        PayloadAssetStore::resolve_for_runtime(&item_type, stored_path.as_deref(), assets_dir);
    Ok(ClipItemSummary {
        id: row.get(0)?,
        item_type,
        title: row.get(2)?,
        summary: row.get(3)?,
        created_at: row.get(4)?,
        last_used_at: row.get(5)?,
        copy_count: row.get(6)?,
        favorite: row.get::<_, i64>(7)? == 1,
        source_app_bundle_id: row.get(8)?,
        source_app_name: row.get(9)?,
        is_sensitive: row.get::<_, i64>(10)? == 1,
        deleted_at: row.get(11)?,
        payload_path: resolved_path,
        ocr_text: row.get(13)?,
        metadata_json: row.get(14)?,
        kind: row.get(15)?,
        source_device_id: row.get(16)?,
        source_device_name: row.get(17)?,
        source_platform: row.get(18)?,
        // tags 逐行映射无法批量，由调用方在返回 Vec 后统一 attach_tags 回填。
        tags: Vec::new(),
    })
}

/// 搜索条件构造结果：显式携带「是否需要 JOIN clip_payloads」，
/// 不再靠 `conditions.iter().any(|c| c.contains("cp."))` 字符串嗅探
/// （新增条件若写成 `ocr_text LIKE` 会漏 JOIN 直接运行期报错）。
struct SearchConditions {
    fts_join: String,
    conditions: Vec<String>,
    params: Vec<Box<dyn rusqlite::ToSql>>,
    needs_payload_join: bool,
}

/// 同步对账时的本地行快照（只取裁决需要的列）。
struct LocalSyncRow {
    last_used_at: f64,
    deleted_at: Option<f64>,
    copy_count: i64,
    updated_at: f64,
    id: String,
    favorite_updated_at: f64,
    tags_updated_at: f64,
}

/// 删除状态裁决（对齐 data-model §3 冲突矩阵）。
///
/// 旧实现把 `deleted_at` 与 `updated_at` 混成一个标量比较
///（`remote.deleted_at.unwrap_or(updated_at)` vs `local.deleted_at.unwrap_or(updated_at)`），
/// 于是「删除后又被粘贴/编辑」会静默撤销删除。这里按矩阵逐分支判定：
///
/// - 本地活跃 + 远端删除：`local.last_used_at > remote.deleted_at` → 保留本地，否则采纳删除
/// - 本地删除 + 远端活跃：`remote.updated_at > local.deleted_at` → 恢复，否则保留删除
/// - 两侧同态：保持本地状态
fn resolve_deleted_state(local: &LocalSyncRow, remote: &crate::sync::SyncItemRecord) -> Option<f64> {
    match (local.deleted_at, remote.deleted_at) {
        // 本地活跃 / 远端删除
        (None, Some(remote_deleted)) => {
            if local.last_used_at > remote_deleted {
                None
            } else {
                Some(remote_deleted)
            }
        }
        // 本地删除 / 远端活跃
        (Some(local_deleted), None) => {
            if remote.updated_at > local_deleted {
                None
            } else {
                Some(local_deleted)
            }
        }
        // 两侧同态：沿用远端值（活跃→活跃为 None；删除→删除取远端时间戳）
        (None, None) => None,
        (Some(_), Some(remote_deleted)) => Some(remote_deleted),
    }
}

/// 转义 LIKE 模式中的元字符（配合 `ESCAPE '\'` 使用）。
/// 不转义时短词 token 里的 `_` / `%` 会被当成通配符：搜 `_` 命中全库。
fn escape_like_token(token: &str) -> String {
    let mut out = String::with_capacity(token.len() + 4);
    for ch in token.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '%' => out.push_str("\\%"),
            '_' => out.push_str("\\_"),
            other => out.push(other),
        }
    }
    out
}

fn compute_kind_and_metadata(
    item_type: &str,
    is_sensitive: bool,
    metadata_json: Option<&str>,
    summary: &str,
    payload_path: Option<&str>,
) -> (&'static str, Option<String>) {
    use crate::algorithms::kind::{classify_kind, ItemKind};
    let kind = classify_kind(item_type, is_sensitive, metadata_json, summary, payload_path);
    let kind_str = match kind {
        ItemKind::Text => "text",
        ItemKind::Image => "image",
        ItemKind::File => "file",
        ItemKind::Url => "url",
        ItemKind::Code => "code",
        ItemKind::Json => "json",
        ItemKind::Color => "color",
        ItemKind::Sensitive => "sensitive",
    };
    let has_lang = metadata_json
        .and_then(|s| serde_json::from_str::<serde_json::Value>(s).ok())
        .and_then(|v| v.get("language").and_then(|l| l.as_str()).map(|s| !s.trim().is_empty()))
        .unwrap_or(false);
    let resolved_meta = if !has_lang && matches!(kind, ItemKind::Code | ItemKind::Json) {
        let detected = if kind == ItemKind::Json {
            Some("json".to_string())
        } else {
            crate::algorithms::language::classify_language(summary)
        };
        if let Some(lang) = detected {
            let mut obj = metadata_json
                .and_then(|s| serde_json::from_str::<serde_json::Value>(s).ok())
                .and_then(|v| v.as_object().cloned())
                .unwrap_or_default();
            obj.insert("language".to_string(), serde_json::Value::String(lang));
            serde_json::to_string(&obj).ok()
        } else {
            metadata_json.map(|s| s.to_string())
        }
    } else {
        metadata_json.map(|s| s.to_string())
    };
    (kind_str, resolved_meta)
}

impl StorageRepository {
    /// 标签规范化（契约 §1，唯一定义，作为关联函数供 `Self::normalize_tag` 调用）：
    /// - trim 首尾空白；剥离所有前导 `#`（`##api` → `api`）；折叠内部连续空白为单个空格；
    /// - 空串 → `None`；
    /// - 截断到 [`MAX_TAG_CHARS`] 个字符（`chars().take`，不切坏多字节字符）。
    pub(crate) fn normalize_tag(raw: &str) -> Option<String> {
        let trimmed = raw.trim();
        let stripped = trimmed.trim_start_matches('#');
        // split_whitespace + join(" ") 同时完成 trim 与内部空白折叠。
        let collapsed = stripped.split_whitespace().collect::<Vec<_>>().join(" ");
        if collapsed.is_empty() {
            return None;
        }
        let truncated: String = collapsed.chars().take(MAX_TAG_CHARS).collect();
        if truncated.is_empty() {
            None
        } else {
            Some(truncated)
        }
    }

    pub fn new(db_path: &str, master_key: &[u8]) -> Result<Self> {
        let conn = Connection::open(db_path)?;
        initialize_database(&conn)?;
        let crypto = CryptoEngine::new(master_key)?;
        Ok(Self {
            conn: Arc::new(Mutex::new(conn)),
            crypto,
            assets_dir: Mutex::new(None),
        })
    }


    pub fn set_assets_dir<P: AsRef<Path>>(&self, dir: Option<P>) {
        *self.assets_dir.lock() = dir.map(|p| p.as_ref().to_path_buf());
    }

    pub fn assets_dir(&self) -> Option<PathBuf> {
        self.assets_dir.lock().clone()
    }

    pub fn resolve_payload_path(&self, item_type: &str, stored_path: Option<&str>) -> Option<String> {
        let dir = self.assets_dir();
        PayloadAssetStore::resolve_for_runtime(item_type, stored_path, dir.as_deref())
    }

    pub fn normalize_payload_path(&self, item_type: &str, payload_path: Option<&str>) -> Option<String> {
        let dir = self.assets_dir();
        PayloadAssetStore::normalize_for_storage(item_type, payload_path, dir.as_deref())
    }

    /// 测试与迁移诊断辅助：读取数据库内存储的原始 payload_path 字段（不做运行时目录拼接）
    pub fn raw_stored_payload_path(&self, id: &str) -> Result<Option<String>> {
        let conn = self.conn.lock();
        let val: Option<Option<String>> = conn
            .query_row(
                "SELECT payload_path FROM clip_items WHERE id = ?1",
                params![id],
                |r| r.get(0),
            )
            .optional()?;
        Ok(val.flatten())
    }

    pub fn crypto(&self) -> &CryptoEngine {
        &self.crypto
    }

    /// 主密钥轮换：用当前密钥解密全部密文载荷，改用新密钥重新加密落盘。
    /// 仅迁移场景调用（如从旧版固定密钥迁移到钥匙串密钥）；调用方应在
    /// 轮换后用新密钥重新打开引擎（本实例的内存密钥不随之切换）。
    /// 返回重加密的载荷条数。
    pub fn rekey(&self, new_master_key: &[u8]) -> Result<usize> {
        let new_crypto = CryptoEngine::new(new_master_key)?;
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;

        let rows: Vec<(String, Vec<u8>, Vec<u8>)> = {
            let mut stmt = tx.prepare(
                "SELECT id, encrypted_content, nonce FROM clip_payloads WHERE encrypted_content IS NOT NULL",
            )?;
            let mapped = stmt.query_map([], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?))
            })?;
            mapped.collect::<std::result::Result<Vec<_>, _>>()?
        };

        let mut count = 0;
        for (id, enc, nonce) in rows {
            let plaintext = self.crypto.decrypt(&enc, &nonce)?;
            let (new_enc, new_nonce) = new_crypto.encrypt(&plaintext)?;
            tx.execute(
                "UPDATE clip_payloads SET encrypted_content = ?1, nonce = ?2 WHERE id = ?3",
                params![&new_enc, &new_nonce, &id],
            )?;
            count += 1;
        }

        tx.commit()?;
        Ok(count)
    }
    pub fn has_encrypted_payloads(&self) -> Result<bool> {
        let conn = self.conn.lock();
        let exists: bool = conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM clip_payloads WHERE encrypted_content IS NOT NULL LIMIT 1)",
            [],
            |row| row.get(0),
        )?;
        Ok(exists)
    }

    pub fn save_item(
        &self,
        item: &ClipItemSummary,
        raw_text: Option<&str>,
    ) -> Result<ClipItemSummary> {
        let assets_dir = self.assets_dir();
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        let saved = Self::save_item_in_tx(&tx, &self.crypto, assets_dir.as_deref(), item, raw_text)?;
        tx.commit()?;
        Ok(saved)
    }

    /// 批量写入：全部条目共用一个事务（导入/初始化/迁移等批量场景），
    /// 任一条目失败整体回滚；逐条语义与 save_item 完全一致（内容去重、FTS 维护）。
    pub fn save_items_batch(
        &self,
        entries: &[(ClipItemSummary, Option<String>)],
    ) -> Result<Vec<ClipItemSummary>> {
        let assets_dir = self.assets_dir();
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        let mut saved = Vec::with_capacity(entries.len());
        for (item, raw_text) in entries {
            saved.push(Self::save_item_in_tx(
                &tx,
                &self.crypto,
                assets_dir.as_deref(),
                item,
                raw_text.as_deref(),
            )?);
        }
        tx.commit()?;
        Ok(saved)
    }

    /// 全部条目的载荷路径（孤儿对账用）：单列查询，不做逐行实体映射——
    /// 启动路径全库 page() 映射在万级数据下要数百毫秒（FFI 逐行解码 +
    /// 敏感条目 detail 解密），只取路径列则 <10ms
    pub fn all_payload_paths(&self) -> Result<Vec<String>> {
        let assets_dir = self.assets_dir();
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT item_type, payload_path FROM clip_items WHERE payload_path IS NOT NULL AND payload_path != ''",
        )?;
        let rows = stmt.query_map([], |row| {
            let item_type: String = row.get(0)?;
            let stored: String = row.get(1)?;
            Ok(
                PayloadAssetStore::resolve_for_runtime(&item_type, Some(&stored), assets_dir.as_deref())
                    .unwrap_or(stored),
            )
        })?;
        let mut paths = Vec::new();
        for row in rows {
            paths.push(row?);
        }
        Ok(paths)
    }
    /// save_item 的单条核心逻辑（在调用方事务内执行，不提交）
    fn save_item_in_tx(
        tx: &rusqlite::Transaction<'_>,
        crypto: &CryptoEngine,
        assets_dir: Option<&Path>,
        item: &ClipItemSummary,
        raw_text: Option<&str>,
    ) -> Result<ClipItemSummary> {

        // 1. 先按主键精确命中
        let existing: Option<(String, i64, bool, f64, bool)> = tx
            .query_row(
                "SELECT id, copy_count, favorite, created_at, deleted_at IS NOT NULL \
                 FROM clip_items WHERE id = ?1",
                params![&item.id],
                |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get::<_, i64>(2)? == 1,
                        row.get(3)?,
                        row.get::<_, i64>(4)? == 1,
                    ))
                },
            )
            .optional()?;
        // 2. 内容去重：敏感条目不能按 summary 去重（相同掩码 != 相同明文）。
        //    条件必须与 idx_clip_items_dedup_lru 的谓词完全一致（含 is_sensitive = 0），
        //    否则部分索引不可用，退化为按 item_type 的全区间逐行比对（写路径 O(N²)）。
        //    回收站行也参与匹配：命中后复用该行并清 deleted_at，避免「删掉的内容再复制一次」
        //    产生同内容第二行（否则从回收站恢复会得到两条重复记录）。
        let existing = match existing {
            Some(v) => Some(v),
            None if !item.is_sensitive => tx
                .query_row(
                    "SELECT id, copy_count, favorite, created_at, deleted_at IS NOT NULL \
                     FROM clip_items \
                     WHERE item_type = ?1 AND summary = ?2 AND is_sensitive = 0 \
                     ORDER BY (deleted_at IS NULL) DESC, last_used_at DESC LIMIT 1",
                    params![&item.item_type, &item.summary],
                    |row| {
                        Ok((
                            row.get(0)?,
                            row.get(1)?,
                            row.get::<_, i64>(2)? == 1,
                            row.get(3)?,
                            row.get::<_, i64>(4)? == 1,
                        ))
                    },
                )
                .optional()?,
            None => None,
        };

        let (target_id, copy_count, favorite, created_at) = match existing {
            Some((prev_id, prev_count, prev_fav, prev_created, _)) => (
                prev_id,
                prev_count + 1,
                prev_fav || item.favorite,
                prev_created,
            ),
            None => (
                item.id.clone(),
                item.copy_count.max(1),
                item.favorite,
                item.created_at,
            ),
        };

        // 2. Encrypt if sensitive
        let (stored_raw, encrypted_content, nonce) = if item.is_sensitive {
            if let Some(text) = raw_text {
                let (enc, n) = crypto.encrypt(text)?;
                (None, Some(enc), Some(n.to_vec()))
            } else {
                (None, None, None)
            }
        } else {
            (raw_text.map(|s| s.to_string()), None, None)
        };

        let normalized_payload_path = PayloadAssetStore::normalize_for_storage(
            &item.item_type,
            item.payload_path.as_deref(),
            assets_dir,
        );

        let (kind_str, resolved_metadata_json) = compute_kind_and_metadata(
            &item.item_type,
            item.is_sensitive,
            item.metadata_json.as_deref(),
            raw_text.unwrap_or(&item.summary),
            normalized_payload_path.as_deref(),
        );
        // 3. Upsert clip_items
        tx.execute(
            r#"
            INSERT INTO clip_items (
                id, item_type, title, summary, created_at, last_used_at,
                copy_count, favorite, source_app_bundle_id, source_app_name,
                is_sensitive, deleted_at, payload_path, updated_at, kind,
                source_device_id, source_device_name, source_platform, favorite_updated_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19)
            ON CONFLICT(id) DO UPDATE SET
                last_used_at = excluded.last_used_at,
                copy_count = excluded.copy_count,
                favorite = excluded.favorite,
                -- 收藏状态从「未收藏」翻转为「收藏」时刷新独立判新时钟；
                -- 已在收藏状态时保持不变（否则每次复制都会刷新收藏时间，
                -- 让本地收藏在与对端取消收藏的竞争中永远胜出）。
                favorite_updated_at = CASE
                    WHEN excluded.favorite = 1 AND clip_items.favorite = 0 THEN excluded.updated_at
                    ELSE clip_items.favorite_updated_at
                END,
                -- 尊重调用方显式传入的 deleted_at：内容去重可能命中回收站行
                --（此时重新复制 = 恢复该行，deleted_at 为 NULL）；
                -- 但显式软删写入（deleted_at 有值）不得被无条件清空。
                deleted_at = excluded.deleted_at,
                payload_path = COALESCE(excluded.payload_path, clip_items.payload_path),
                updated_at = excluded.updated_at,
                kind = excluded.kind,
                source_device_id = COALESCE(excluded.source_device_id, clip_items.source_device_id),
                source_device_name = COALESCE(excluded.source_device_name, clip_items.source_device_name),
                source_platform = COALESCE(excluded.source_platform, clip_items.source_platform),
                source_app_bundle_id = COALESCE(excluded.source_app_bundle_id, clip_items.source_app_bundle_id),
                source_app_name = COALESCE(excluded.source_app_name, clip_items.source_app_name)
            "#,
            params![
                &target_id,
                &item.item_type,
                &item.title,
                &item.summary,
                created_at,
                item.last_used_at,
                copy_count,
                if favorite { 1 } else { 0 },
                &item.source_app_bundle_id,
                &item.source_app_name,
                if item.is_sensitive { 1 } else { 0 },
                item.deleted_at,
                &normalized_payload_path,
                Self::unix_now(),
                kind_str,
                &item.source_device_id,
                &item.source_device_name,
                &item.source_platform,
                if favorite { Self::unix_now() } else { 0.0 },
            ],
        )?;

        // 4. Upsert clip_payloads
        // 保护已有全文与密文：
        // - 若冲突更新时未传入新密文，保留原有 encrypted_content / nonce；
        // - 若库内已有更长的 raw_text（例如同步/备份导入的全量正文，而本次调用仅携带截断摘要），
        //   保留库内更完整的 raw_text，防止截断摘要覆盖全文。
        tx.execute(
            r#"
            INSERT INTO clip_payloads (
                id, raw_text, encrypted_content, nonce, ocr_text, metadata_json
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            ON CONFLICT(id) DO UPDATE SET
                raw_text = CASE
                    WHEN excluded.raw_text IS NULL THEN clip_payloads.raw_text
                    WHEN clip_payloads.raw_text IS NOT NULL
                         AND length(clip_payloads.raw_text) > length(excluded.raw_text)
                         AND substr(clip_payloads.raw_text, 1, length(excluded.raw_text)) = excluded.raw_text
                    THEN clip_payloads.raw_text
                    ELSE excluded.raw_text
                END,
                encrypted_content = COALESCE(excluded.encrypted_content, clip_payloads.encrypted_content),
                nonce = COALESCE(excluded.nonce, clip_payloads.nonce),
                ocr_text = COALESCE(excluded.ocr_text, clip_payloads.ocr_text),
                metadata_json = COALESCE(excluded.metadata_json, clip_payloads.metadata_json)
            "#,
            params![
                &target_id,
                &stored_raw,
                &encrypted_content,
                &nonce,
                item.ocr_text.as_deref(),
                resolved_metadata_json.as_deref(),
            ],
        )?;
        // 5. 合并行状态：upsert 冲突时 title/summary 保留旧值（自定义标题
        //    保留特性）、ocr/metadata COALESCE 合并——返回值与 FTS 重建都
        //    必须以此为准，回显输入条目会让增量更新镜像的调用方与库错位
        let mut persisted: ClipItemSummary = tx.query_row(
            r#"
            SELECT ci.id, ci.item_type, ci.title, ci.summary, ci.created_at, ci.last_used_at,
                   ci.copy_count, ci.favorite, ci.source_app_bundle_id, ci.source_app_name,
                   ci.is_sensitive, ci.deleted_at, ci.payload_path, cp.ocr_text, cp.metadata_json, ci.kind,
                   ci.source_device_id, ci.source_device_name, ci.source_platform
            FROM clip_items ci
            LEFT JOIN clip_payloads cp ON ci.id = cp.id
            WHERE ci.id = ?1
            "#,
            params![&target_id],
            |row| {
                let item_type: String = row.get(1)?;
                let stored_path: Option<String> = row.get(12)?;
                let resolved_path = PayloadAssetStore::resolve_for_runtime(
                    &item_type,
                    stored_path.as_deref(),
                    assets_dir,
                );
                Ok(ClipItemSummary {
                    id: row.get(0)?,
                    item_type,
                    title: row.get(2)?,
                    summary: row.get(3)?,
                    created_at: row.get(4)?,
                    last_used_at: row.get(5)?,
                    copy_count: row.get(6)?,
                    favorite: row.get::<_, i64>(7)? == 1,
                    source_app_bundle_id: row.get(8)?,
                    source_app_name: row.get(9)?,
                    is_sensitive: row.get::<_, i64>(10)? == 1,
                    deleted_at: row.get(11)?,
                    payload_path: resolved_path,
                    ocr_text: row.get(13)?,
                    metadata_json: row.get(14)?,
                    kind: row.get(15)?,
                    source_device_id: row.get(16)?,
                    source_device_name: row.get(17)?,
                    source_platform: row.get(18)?,
                    // 稍后由 load_tags_for 回填。
                    tags: Vec::new(),
                })
            },
        )?;

        // 回填标签（单条：一次查询）。FTS 的 tags 列随后据此写入。
        if let Some(tags) = load_tags_for(tx, &[target_id.clone()])?.remove(&target_id) {
            persisted.tags = tags;
        }

        // clip_items.rowid：FTS 定位用（不变量 clip_fts.rowid == clip_items.rowid）。
        // 单独一次主键查询，避免在 FTS 的 DELETE/INSERT 里各嵌一次全表子查询。
        let target_rowid: i64 = tx
            .query_row(
                "SELECT rowid FROM clip_items WHERE id = ?1",
                params![&target_id],
                |r| r.get(0),
            )
            .unwrap_or(-1);

        // 6. Update clip_fts:
        // FTS5 按 rowid 定位：clip_id 是 UNINDEXED 列，按其删除/更新需全表扫描（O(N)，
        // 批量场景退化为 O(N²)）。不变量：clip_fts.rowid == clip_items.rowid。
        // rowid 已由上方 SELECT（ci.rowid）取出，直接传数字，免两次子查询全表扫。
        // 敏感条目收录 title 与 tags 供检索，正文/OCR/来源全部留空以防明文泄密。
        if target_rowid >= 0 {
            tx.execute(
                "DELETE FROM clip_fts WHERE rowid = ?1",
                params![target_rowid],
            )?;
        }
        let (fts_summary, fts_ocr, fts_app_name, fts_bundle_id) = if persisted.is_sensitive {
            ("", "", "", "")
        } else {
            (
                persisted.summary.as_str(),
                persisted.ocr_text.as_deref().unwrap_or(""),
                persisted.source_app_name.as_deref().unwrap_or(""),
                persisted.source_app_bundle_id.as_deref().unwrap_or(""),
            )
        };
        let fts_tags = tags_fts_text(&persisted.tags);
        if target_rowid >= 0 {
            tx.execute(
                r#"
                INSERT INTO clip_fts (
                    rowid, title, summary, ocr_text, source_app_name, source_app_bundle_id, tags, clip_id
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                "#,
                params![
                    target_rowid,
                    &persisted.title,
                    fts_summary,
                    fts_ocr,
                    fts_app_name,
                    fts_bundle_id,
                    &fts_tags,
                    &target_id,
                ],
            )?;
        }

        Ok(persisted)
    }

    /// 构造通用的 FTS 与 WHERE 条件片段（query_items / count_categories /
    /// time_group_anchor_counts 共享）。
    fn build_search_conditions(
        include_deleted: bool,
        favorite_only: bool,
        item_type: Option<&str>,
        search_query: Option<&str>,
        id: Option<&str>,
        tag: Option<&str>,
    ) -> SearchConditions {
        let mut conditions = Vec::new();
        let mut params: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();
        let mut needs_payload_join = false;

        if !include_deleted {
            conditions.push("ci.deleted_at IS NULL".to_string());
        }

        if favorite_only {
            conditions.push("ci.favorite = 1".to_string());
        }

        if let Some(id) = id {
            if !id.is_empty() {
                params.push(Box::new(id.to_string()));
                conditions.push(format!("ci.id = ?{}", params.len()));
            }
        }

        if let Some(itype) = item_type {
            if !itype.is_empty() {
                params.push(Box::new(itype.to_string()));
                conditions.push(format!("ci.item_type = ?{}", params.len()));
            }
        }

        // 显式 filter.tag（单标签等值过滤，大小写不敏感）与搜索词里解析出的 tag 过滤
        // 通过同一条件模板追加，多个 tag 即多条 EXISTS → 天然 AND。
        let push_tag_condition = |tag_val: &str,
                                      conditions: &mut Vec<String>,
                                      params: &mut Vec<Box<dyn rusqlite::ToSql>>| {
            if let Some(normalized) = StorageRepository::normalize_tag(tag_val) {
                params.push(Box::new(normalized));
                let idx = params.len();
                conditions.push(format!(
                    "EXISTS (SELECT 1 FROM clip_tags ct WHERE ct.clip_id = ci.id AND ct.tag = ?{idx} COLLATE NOCASE)"
                ));
            }
        };

        if let Some(t) = tag {
            if !t.trim().is_empty() {
                push_tag_condition(t, &mut conditions, &mut params);
            }
        }

        let mut fts_join = String::new();
        if let Some(q) = search_query {
            let clean_q = q.trim();
            if !clean_q.is_empty() {
                let tokens = crate::search::tokenize_search_query(clean_q);
                // 搜索词中的 `#xxx` / `tag:xxx` 解析为标签过滤（从普通关键词中剔除）。
                let (tag_tokens, keyword_tokens): (Vec<String>, Vec<String>) =
                    tokens.into_iter().partition(|t| {
                        t.starts_with('#') || t.to_lowercase().starts_with("tag:")
                    });
                for tag_token in tag_tokens {
                    // 去掉 `tag:` 前缀或前导 `#`，再交给 normalize_tag 统一处理。
                    let raw = if let Some(rest) = tag_token
                        .strip_prefix("tag:")
                        .or_else(|| tag_token.strip_prefix("Tag:"))
                        .or_else(|| tag_token.strip_prefix("TAG:"))
                    {
                        rest
                    } else {
                        tag_token.strip_prefix('#').unwrap_or(&tag_token)
                    };
                    push_tag_condition(raw, &mut conditions, &mut params);
                }

                let (long_tokens, short_tokens): (Vec<String>, Vec<String>) =
                    keyword_tokens.into_iter().partition(|t| t.chars().count() >= 3);

                if !long_tokens.is_empty() {
                    let fts_expr = long_tokens
                        .iter()
                        .map(|t| format!("\"{}\"", t.replace('"', "\"\"")))
                        .collect::<Vec<_>>()
                        .join(" ");
                    params.push(Box::new(fts_expr));
                    let fts_param_idx = params.len();
                    // 按 rowid 关联：clip_fts.rowid == clip_items.rowid 是不变量
                    //（schema v2 起由所有写路径维护，test_fts_rowid_alignment 守护）。
                    // 若按 UNINDEXED 的 clip_id 关联，每次命中都要走文本主键二分查找，
                    // 实测快照类查询慢 2–2.5×。
                    fts_join = format!(
                        "INNER JOIN (SELECT rowid AS fts_rowid FROM clip_fts WHERE clip_fts MATCH ?{fts_param_idx}) fts ON ci.rowid = fts.fts_rowid"
                    );
                }

                for st in short_tokens {
                    // 转义 LIKE 元字符：不转义时 token `_` / `%` 会退化为通配符
                    //（实测搜 `_` 命中全库），既是错结果也是一次隐式的全表探测。
                    params.push(Box::new(format!("%{}%", escape_like_token(&st))));
                    let p_idx = params.len();
                    // 敏感条目：OCR 明文不得成为搜索旁路（FTS 路径已排除敏感条目，
                    // 短词回退必须保持一致，否则 2 字符即可命中敏感正文）。
                    conditions.push(format!(
                        "(ci.title LIKE ?{p_idx} ESCAPE '\\' \
                          OR ci.summary LIKE ?{p_idx} ESCAPE '\\' \
                          OR ci.source_app_name LIKE ?{p_idx} ESCAPE '\\' \
                          OR (ci.is_sensitive = 0 AND cp.ocr_text LIKE ?{p_idx} ESCAPE '\\'))"
                    ));
                    needs_payload_join = true;
                }
            }
        }

        SearchConditions {
            fts_join,
            conditions,
            params,
            needs_payload_join,
        }
    }

    /// 这批 id 中实际存在的那些（参数化 IN，一次查询；含已软删行）。
    /// 导入去重专用：只回传 id，不做实体映射、不读载荷列。
    pub fn existing_item_ids(&self, ids: &[String]) -> Result<Vec<String>> {
        if ids.is_empty() {
            return Ok(Vec::new());
        }
        let conn = self.conn.lock();
        let mut out = Vec::new();
        // 分块避免超出 SQLite 变量上限（默认 999）
        const CHUNK: usize = 500;
        for chunk in ids.chunks(CHUNK) {
            let placeholders = vec!["?"; chunk.len()].join(",");
            let sql = format!("SELECT id FROM clip_items WHERE id IN ({placeholders})");
            let mut stmt = conn.prepare(&sql)?;
            let rows = stmt.query_map(rusqlite::params_from_iter(chunk.iter()), |r| {
                r.get::<_, String>(0)
            })?;
            for r in rows {
                out.push(r?);
            }
        }
        Ok(out)
    }

    /// 按 id 集合批量取摘要（参数化 IN，一次查询替代逐 ID N 次往返）。
    /// 批量粘贴等场景用于一次拿到全部目标条目。
    pub fn query_items_by_ids(&self, ids: &[String]) -> Result<Vec<ClipItemSummary>> {
        if ids.is_empty() {
            return Ok(Vec::new());
        }
        let assets_dir = self.assets_dir();
        let conn = self.conn.lock();

        let placeholders = vec!["?"; ids.len()].join(",");
        let summary_expr = "CASE WHEN ci.is_sensitive = 0 AND cp.raw_text IS NOT NULL AND cp.raw_text != '' THEN cp.raw_text ELSE ci.summary END";
        let sql = format!(
            r#"
            SELECT {columns}
            FROM clip_items ci
            LEFT JOIN clip_payloads cp ON ci.id = cp.id
            WHERE ci.id IN ({placeholders}) AND ci.deleted_at IS NULL
            "#,
            columns = summary_columns(summary_expr),
        );

        let mut stmt = conn.prepare(&sql)?;
        let rows = stmt.query_map(rusqlite::params_from_iter(ids.iter()), |row| {
            map_summary_row(row, assets_dir.as_deref())
        })?;

        let mut out = Vec::new();
        for r in rows {
            out.push(r?);
        }
        attach_tags(&conn, &mut out)?;
        Ok(out)
    }

    pub fn query_items(&self, filter: &QueryFilter) -> Result<Vec<ClipItemSummary>> {
        let assets_dir = self.assets_dir();
        let conn = self.conn.lock();
        let search = Self::build_search_conditions(
            filter.include_deleted,
            filter.favorite_only,
            filter.item_type.as_deref(),
            filter.search_query.as_deref(),
            filter.id.as_deref(),
            filter.tag.as_deref(),
        );
        let SearchConditions {
            fts_join,
            mut conditions,
            params,
            needs_payload_join: _,
        } = search;

        let derived = DerivedKindFilter::new(filter.kind.as_deref());
        derived.push_sql_conditions(&mut conditions);

        // 回收站列表：把「只看已删」下推到 SQL（含按删除时间倒序），
        // 避免全表扫一页活跃行再在调用方过滤已删行。
        if filter.only_deleted {
            conditions.push("ci.deleted_at IS NOT NULL".to_string());
        }
        let trash_order = if filter.only_deleted {
            "ORDER BY ci.deleted_at DESC, ci.id DESC"
        } else {
            "ORDER BY ci.last_used_at DESC, ci.id DESC"
        };

        let where_clause = if conditions.is_empty() {
            String::new()
        } else {
            format!("WHERE {}", conditions.join(" AND "))
        };

        let limit = if filter.limit == 0 { 50 } else { filter.limit };
        let offset = filter.offset;
        let limit_clause = format!("LIMIT {limit} OFFSET {offset}");

        // 单条按 id 精确查询（预览/粘贴/编辑全文契约）且非敏感时，返回 COALESCE(cp.raw_text, ci.summary)
        // 确保同步或备份导入的长文本（summary 为摘要、raw_text 为全文）能完整读出
        let is_single_id_query = filter.id.as_deref().is_some_and(|s| !s.is_empty());
        let summary_expr = if is_single_id_query {
            "CASE WHEN ci.is_sensitive = 0 AND cp.raw_text IS NOT NULL AND cp.raw_text != '' THEN cp.raw_text ELSE ci.summary END".to_string()
        } else if let Some(max_chars) = filter.summary_max_chars.filter(|&n| n > 0) {
            format!("SUBSTR(ci.summary, 1, {max_chars})")
        } else {
            "ci.summary".to_string()
        };
        let sql = format!(
            r#"
            SELECT {columns}
            FROM clip_items ci
            LEFT JOIN clip_payloads cp ON ci.id = cp.id
            {fts_join}
            {where_clause}
            {trash_order}
            {limit_clause}
            "#,
            columns = summary_columns(&summary_expr),
        );

        let mut stmt = conn.prepare(&sql)?;
        let param_refs: Vec<&dyn rusqlite::ToSql> = params.iter().map(|p| p.as_ref()).collect();

        let rows = stmt.query_map(param_refs.as_slice(), |row| {
            map_summary_row(row, assets_dir.as_deref())
        })?;

        let mut results = Vec::new();
        for r in rows {
            results.push(r?);
        }
        attach_tags(&conn, &mut results)?;
        Ok(results)
    }

    /// 全历史分类统计：基于持久化 ci.kind 列在 SQLite 内直接聚合，无需全表拉取 summary/metadata。
    /// 用 `GROUP BY kind` 单遍聚合，替代 9 个逐行求值的 `SUM(CASE WHEN kind=…)`
    ///（实测 5 万行 12ms → 8ms，且分类增减不再线性叠加成本）。
    pub fn count_categories(
        &self,
        search_query: Option<&str>,
        tag: Option<&str>,
    ) -> Result<crate::model::CategoryCounts> {
        let conn = self.conn.lock();

        let SearchConditions {
            fts_join,
            conditions,
            params,
            needs_payload_join,
        } = Self::build_search_conditions(false, false, None, search_query, None, tag);

        let where_clause = if conditions.is_empty() {
            String::new()
        } else {
            format!("WHERE {}", conditions.join(" AND "))
        };

        let payload_join = if needs_payload_join {
            "LEFT JOIN clip_payloads cp ON ci.id = cp.id"
        } else {
            ""
        };

        let sql = format!(
            r#"
            SELECT ci.kind, ci.favorite, COUNT(*)
            FROM clip_items ci
            {payload_join}
            {fts_join}
            {where_clause}
            GROUP BY ci.kind, ci.favorite
            "#
        );

        let param_refs: Vec<&dyn rusqlite::ToSql> = params.iter().map(|p| p.as_ref()).collect();
        let mut stmt = conn.prepare(&sql)?;
        let mut rows = stmt.query(param_refs.as_slice())?;

        let mut counts = crate::model::CategoryCounts::default();
        while let Some(row) = rows.next()? {
            let kind: String = row.get(0)?;
            let favorite: i64 = row.get(1)?;
            let count: i64 = row.get(2)?;
            let count = count as u64;
            counts.total += count;
            if favorite == 1 {
                counts.favorite += count;
            }
            match kind.as_str() {
                "text" => counts.text += count,
                "image" => counts.image += count,
                "file" => counts.file += count,
                "url" => counts.url += count,
                "code" | "json" => counts.code += count,
                "color" => counts.color += count,
                "sensitive" => counts.sensitive += count,
                // 未知 kind（历史遗留/未来新增）只计入 total，与旧实现的语义一致
                _ => {}
            }
        }

        Ok(counts)
    }

    /// 全量时间戳聚合：返回当前筛选（关键词/分类/派生 kind）下全部命中条目的
    /// last_used_at（降序），供时间导航锚点条做全历史时间分组。
    /// 与分页列表无关——pageSize 截断不再导致锚点条缺失更早的分组。
    pub fn time_group_timestamps(&self, filter: &QueryFilter) -> Result<Vec<f64>> {
        let conn = self.conn.lock();

        let SearchConditions {
            fts_join,
            mut conditions,
            params,
            needs_payload_join,
        } = Self::build_search_conditions(
            filter.include_deleted,
            filter.favorite_only,
            filter.item_type.as_deref(),
            filter.search_query.as_deref(),
            filter.id.as_deref(),
            filter.tag.as_deref(),
        );

        let derived = DerivedKindFilter::new(filter.kind.as_deref());
        derived.push_sql_conditions(&mut conditions);

        let where_clause = if conditions.is_empty() {
            String::new()
        } else {
            format!("WHERE {}", conditions.join(" AND "))
        };

        let payload_join = if needs_payload_join {
            "LEFT JOIN clip_payloads cp ON ci.id = cp.id"
        } else {
            ""
        };

        let sql = format!(
            r#"
            SELECT ci.last_used_at
            FROM clip_items ci
            {payload_join}
            {fts_join}
            {where_clause}
            ORDER BY ci.last_used_at DESC, ci.id DESC
            "#
        );

        let mut stmt = conn.prepare(&sql)?;
        let param_refs: Vec<&dyn rusqlite::ToSql> = params.iter().map(|p| p.as_ref()).collect();

        let mut timestamps = Vec::new();
        let mut rows = stmt.query(param_refs.as_slice())?;
        while let Some(row) = rows.next()? {
            timestamps.push(row.get(0)?);
        }

        Ok(timestamps)
    }

    /// 时间锚点计数的 SQL 内聚合版：不把全库时间戳搬进内存。
    /// 调用方（query_snapshot）只关心每个时间桶的条数，因此按
    /// caller 提供的 4 个时区边界常量在 SQLite 内直接分桶，
    /// 万级历史下省掉「数万 f64 传输 + chrono 逐条换算」。
    /// 保留 time_group_timestamps 给需要原始时间戳的调用方（Swift 侧时间轴）。
    pub fn time_group_anchor_counts(
        &self,
        filter: &QueryFilter,
        boundaries: &TimelineBoundaries,
    ) -> Result<Vec<AnchorCountRow>> {
        let conn = self.conn.lock();

        let SearchConditions {
            fts_join,
            mut conditions,
            mut params,
            needs_payload_join,
        } = Self::build_search_conditions(
            filter.include_deleted,
            filter.favorite_only,
            filter.item_type.as_deref(),
            filter.search_query.as_deref(),
            filter.id.as_deref(),
            filter.tag.as_deref(),
        );

        let derived = DerivedKindFilter::new(filter.kind.as_deref());
        derived.push_sql_conditions(&mut conditions);

        let where_clause = if conditions.is_empty() {
            String::new()
        } else {
            format!("WHERE {}", conditions.join(" AND "))
        };

        let payload_join = if needs_payload_join {
            "LEFT JOIN clip_payloads cp ON ci.id = cp.id"
        } else {
            ""
        };

        // 四个边界以 Unix 秒常量参与比较：today/yesterday/this-week/last-week
        // 起点由调用方按目标时区算好后传入。
        params.push(Box::new(boundaries.today_start));
        params.push(Box::new(boundaries.yesterday_start));
        params.push(Box::new(boundaries.this_week_start));
        params.push(Box::new(boundaries.last_week_start));
        let p_today = params.len() - 3;
        let p_yesterday = params.len() - 2;
        let p_this_week = params.len() - 1;
        let p_last_week = params.len();

        let sql = format!(
            r#"
            SELECT
                COUNT(CASE WHEN ci.last_used_at >= ?{p_today} THEN 1 END) AS today_count,
                COUNT(CASE WHEN ci.last_used_at >= ?{p_yesterday} AND ci.last_used_at < ?{p_today} THEN 1 END) AS yesterday_count,
                COUNT(CASE WHEN ci.last_used_at >= ?{p_this_week} AND ci.last_used_at < ?{p_yesterday} THEN 1 END) AS this_week_count,
                COUNT(CASE WHEN ci.last_used_at >= ?{p_last_week} AND ci.last_used_at < ?{p_this_week}
                            AND NOT (ci.last_used_at >= ?{p_yesterday} AND ci.last_used_at < ?{p_today})
                      THEN 1 END) AS last_week_count,
                0 AS month_bucket,
                0.0 AS last_used_at
            FROM clip_items ci
            {payload_join}
            {fts_join}
            {where_clause}
            "#
        );

        let param_refs: Vec<&dyn rusqlite::ToSql> = params.iter().map(|p| p.as_ref()).collect();
        let mut stmt = conn.prepare(&sql)?;
        let first = stmt.query_row(param_refs.as_slice(), |row| {
            Ok(AnchorCountRow {
                today_count: row.get::<_, i64>(0)? as u32,
                yesterday_count: row.get::<_, i64>(1)? as u32,
                this_week_count: row.get::<_, i64>(2)? as u32,
                last_week_count: row.get::<_, i64>(3)? as u32,
                last_used_at: 0.0,
                year: None,
                month: None,
                year_count: 0,
            })
        })?;

        // 月份 / 年份桶按本地时区切分。SQLite 没有时区概念（strftime 走 UTC），
        // 因此本地月份起点由调用方算好随 boundaries 传入，SQL 内用 CASE 归类。
        // 桶 id 与 group_timestamps 对齐：本年度条目 → 'month-{M}'，
        // 更早年度 → 'year-{Y}'（current_year 由调用方一并给出）。
        // 无月份边界时直接返回近端计数：CASE 不能只有 ELSE 分支（SQL 语法错误）。
        if boundaries.month_starts.is_empty() {
            return Ok(vec![first]);
        }
        let current_year = boundaries.current_year;
        let month_case = {
            let mut branches = Vec::new();
            for (year, month, start_ts) in &boundaries.month_starts {
                if *year == current_year {
                    branches.push(format!(
                        "WHEN ci.last_used_at >= {start_ts:.3} THEN 'month-{month:02}'"
                    ));
                } else if *month == 1 {
                    // 年桶下界必须取该年 1 月 1 日：若用 12 月起算，
                    // 上一年 12 月条目会被误归入下一年。
                    branches.push(format!(
                        "WHEN ci.last_used_at >= {start_ts:.3} THEN 'year-{year}'"
                    ));
                }
            }
            format!("{} ELSE 'older'", branches.join(" "))
        };

        // month_starts 覆盖本年度各月及回溯至 1970 的各年份起点
        let month_where = if where_clause.is_empty() {
            format!("WHERE ci.last_used_at < ?{p_last_week}")
        } else {
            format!("{where_clause} AND ci.last_used_at < ?{p_last_week}")
        };


        let month_sql = format!(
            r#"
            SELECT CASE
                {month_case}
            END AS bucket, COUNT(*) AS c
            FROM clip_items ci
            {payload_join}
            {fts_join}
            {month_where}
            GROUP BY bucket
            ORDER BY
                CASE WHEN bucket LIKE 'month-%' THEN 0 ELSE 1 END,
                CAST(SUBSTR(bucket, INSTR(bucket, '-') + 1) AS INTEGER) DESC
            "#
        );
        let mut month_stmt = conn.prepare(&month_sql)?;
        let month_rows = month_stmt.query_map(param_refs.as_slice(), |row| {
            let bucket: String = row.get(0)?;
            let count: i64 = row.get(1)?;
            Ok((bucket, count as u32))
        })?;

        let mut out = vec![first];
        for r in month_rows {
            let (bucket, count) = r?;
            // bucket 形如 "month-09"（本年度）或 "year-2025"（更早年度）
            if let Some(rest) = bucket.strip_prefix("month-") {
                let month = rest.parse::<u32>().unwrap_or(0);
                // month- 桶的年份 = current_year
                out.push(AnchorCountRow {
                    today_count: 0,
                    yesterday_count: 0,
                    this_week_count: 0,
                    last_week_count: 0,
                    last_used_at: 0.0,
                    year: Some(current_year),
                    month: Some(month),
                    year_count: count,
                });
            } else if let Some(rest) = bucket.strip_prefix("year-") {
                let year = rest.parse::<i32>().unwrap_or(0);
                out.push(AnchorCountRow {
                    today_count: 0,
                    yesterday_count: 0,
                    this_week_count: 0,
                    last_week_count: 0,
                    last_used_at: 0.0,
                    year: Some(year),
                    month: None,
                    year_count: count,
                });
            }
        }
        Ok(out)
    }

    pub fn get_item_detail(&self, id: &str) -> Result<ClipItemDetail> {
        let conn = self.conn.lock();

        let row = conn
            .query_row(
                r#"
                SELECT cp.raw_text, cp.encrypted_content, cp.nonce, cp.ocr_text, cp.metadata_json, ci.is_sensitive,
                       cp.ocr_encrypted, cp.ocr_nonce
                FROM clip_payloads cp
                JOIN clip_items ci ON cp.id = ci.id
                WHERE cp.id = ?1
                "#,
                params![id],
                |row| {
                    Ok((
                        row.get::<_, Option<String>>(0)?,
                        row.get::<_, Option<Vec<u8>>>(1)?,
                        row.get::<_, Option<Vec<u8>>>(2)?,
                        row.get::<_, Option<String>>(3)?,
                        row.get::<_, Option<String>>(4)?,
                        row.get::<_, i64>(5)? == 1,
                        row.get::<_, Option<Vec<u8>>>(6)?,
                        row.get::<_, Option<Vec<u8>>>(7)?,
                    ))
                },
            )
            .optional()?;

        let (raw_text, enc, nonce, ocr_text, metadata_json, is_sensitive, ocr_enc, ocr_nonce) = match row {
            Some(v) => v,
            None => return Err(CoreError::NotFound(id.to_string())),
        };

        let final_text = if is_sensitive {
            match (enc, nonce) {
                (Some(c), Some(n)) => Some(self.crypto.decrypt(&c, &n)?),
                _ => None,
            }
        } else {
            raw_text
        };

        // 敏感条目的 OCR 文本只存在于密文列（明文列必为 NULL）；
        // 解密失败必须显式报错，不得降级返回 None 让调用方以为「无 OCR 文本」
        let final_ocr = if is_sensitive {
            match (ocr_enc, ocr_nonce) {
                (Some(c), Some(n)) => Some(self.crypto.decrypt(&c, &n)?),
                _ => ocr_text,
            }
        } else {
            ocr_text
        };

        Ok(ClipItemDetail {
            id: id.to_string(),
            raw_text: final_text,
            ocr_text: final_ocr,
            metadata_json,
            is_sensitive,
        })
    }

    /// 轻量标记使用（粘贴/再次使用）：仅递增 copy_count 并刷新 last_used_at，
    /// 不触碰 clip_payloads（密文/全文）与 clip_fts，彻底杜绝掩码或截断摘要覆盖原文。
    ///
    /// 关键：**不推进 updated_at**。使用不是元数据编辑——若把粘贴当作元数据写入，
    /// 对端只要「用过」这条记录就会在 LWW 中胜出，把另一台设备刚做的收藏/删除
    /// 静默回滚（实测：B 收藏 → A 粘贴 → B 拉取后收藏丢失）。跨端置顶依靠
    /// `last_used_at = MAX(local, remote)` 传播，与本时间戳无关。
    pub fn mark_used(&self, id: &str, used_at: f64) -> Result<ClipItemSummary> {
        let conn = self.conn.lock();
        let changed = conn.execute(
            r#"
            UPDATE clip_items
            SET last_used_at = ?1,
                copy_count = copy_count + 1
            WHERE id = ?2
            "#,
            params![used_at, id],
        )?;
        drop(conn);
        if changed == 0 {
            return Err(CoreError::NotFound(id.to_string()));
        }
        self.get_item_summary(id)
    }

    pub fn toggle_favorite(&self, id: &str) -> Result<ClipItemSummary> {
        let conn = self.conn.lock();
        let now = Self::unix_now();
        // favorite_updated_at 是收藏状态的独立判新时钟：粘贴只动 last_used_at，
        // 因此「A 粘贴 + B 收藏」不会再互相覆盖。同时推进 updated_at 以兼容
        // 尚未携带该字段的旧版对端（旧端只认 updated_at）。
        conn.execute(
            "UPDATE clip_items SET favorite = CASE WHEN favorite = 1 THEN 0 ELSE 1 END, \
             favorite_updated_at = ?1, updated_at = ?1 WHERE id = ?2",
            params![now, id],
        )?;

        drop(conn);
        self.get_item_summary(id)
    }

    // ---------------------------------------------------------------------
    // 轻量标签（契约 §1、§4）
    // ---------------------------------------------------------------------

    /// 规范化一组标签：逐个 normalize_tag、按小写判重（保留首次出现的大小写）、
    /// 截断到 [`MAX_TAGS_PER_ITEM`] 个。返回 (展示名, 小写判重键) 的有序去重列表。
    fn normalize_tag_list(tags: &[String]) -> Vec<String> {
        let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
        let mut out: Vec<String> = Vec::new();
        for raw in tags {
            let Some(norm) = Self::normalize_tag(raw) else {
                continue;
            };
            let key = norm.to_lowercase();
            if seen.insert(key) {
                out.push(norm);
                if out.len() >= MAX_TAGS_PER_ITEM {
                    break;
                }
            }
        }
        out
    }

    /// 在事务内用给定标签列表全量替换某条目的标签，并推进 tags_updated_at、重建 FTS 行。
    /// 调用方保证 id 存在；不做条目存在性校验之外的额外副作用。
    fn write_tags_in_tx(
        tx: &rusqlite::Transaction<'_>,
        id: &str,
        tags: &[String],
        now: f64,
    ) -> Result<()> {
        tx.execute("DELETE FROM clip_tags WHERE clip_id = ?1", params![id])?;
        for tag in tags {
            tx.execute(
                "INSERT OR IGNORE INTO clip_tags (clip_id, tag, created_at) VALUES (?1, ?2, ?3)",
                params![id, tag, now],
            )?;
        }
        tx.execute(
            "UPDATE clip_items SET tags_updated_at = ?1 WHERE id = ?2",
            params![now, id],
        )?;
        // 标签变更后重建该行 FTS（tags 列），并推进 tags_updated_at。
        Self::rebuild_fts_row_in_tx(tx, id)?;
        Ok(())
    }

    /// 全量替换某条目的标签。返回带 tags 的最新摘要。
    pub fn set_tags(&self, id: &str, tags: &[String]) -> Result<ClipItemSummary> {
        let normalized = Self::normalize_tag_list(tags);
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        // 校验条目存在（否则不静默创建孤儿标签）。
        let exists: bool = tx
            .query_row("SELECT 1 FROM clip_items WHERE id = ?1", params![id], |_| Ok(()))
            .optional()?
            .is_some();
        if !exists {
            return Err(CoreError::NotFound(id.to_string()));
        }
        Self::write_tags_in_tx(&tx, id, &normalized, Self::unix_now())?;
        let summary = Self::load_summary_in_tx(&tx, id)?;
        tx.commit()?;
        Ok(summary)
    }

    /// 追加单个标签（已存在则无变化）。返回带 tags 的最新摘要。
    pub fn add_tag(&self, id: &str, tag: &str) -> Result<ClipItemSummary> {
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        let exists: bool = tx
            .query_row("SELECT 1 FROM clip_items WHERE id = ?1", params![id], |_| Ok(()))
            .optional()?
            .is_some();
        if !exists {
            return Err(CoreError::NotFound(id.to_string()));
        }
        let mut current: Vec<String> = load_tags_for(&tx, &[id.to_string()])?
            .remove(id)
            .unwrap_or_default();
        if let Some(norm) = Self::normalize_tag(tag) {
            // 判重键不区分大小写；已达上限则忽略新标签。
            let key = norm.to_lowercase();
            let already = current.iter().any(|t| t.to_lowercase() == key);
            if !already && current.len() < MAX_TAGS_PER_ITEM {
                current.push(norm);
            }
        }
        Self::write_tags_in_tx(&tx, id, &current, Self::unix_now())?;
        let summary = Self::load_summary_in_tx(&tx, id)?;
        tx.commit()?;
        Ok(summary)
    }

    /// 移除单个标签（大小写不敏感匹配）。返回带 tags 的最新摘要。
    pub fn remove_tag(&self, id: &str, tag: &str) -> Result<ClipItemSummary> {
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        let exists: bool = tx
            .query_row("SELECT 1 FROM clip_items WHERE id = ?1", params![id], |_| Ok(()))
            .optional()?
            .is_some();
        if !exists {
            return Err(CoreError::NotFound(id.to_string()));
        }
        let target_key = Self::normalize_tag(tag)
            .map(|t| t.to_lowercase())
            .unwrap_or_else(|| tag.to_lowercase());
        let current: Vec<String> = load_tags_for(&tx, &[id.to_string()])?
            .remove(id)
            .unwrap_or_default();
        let filtered: Vec<String> = current
            .into_iter()
            .filter(|t| t.to_lowercase() != target_key)
            .collect();
        Self::write_tags_in_tx(&tx, id, &filtered, Self::unix_now())?;
        let summary = Self::load_summary_in_tx(&tx, id)?;
        tx.commit()?;
        Ok(summary)
    }

    /// 统计全部未删除条目使用到的标签（按 count DESC, name ASC）。
    pub fn list_tags(&self) -> Result<Vec<TagStat>> {
        let conn = self.conn.lock();
        // 按小写聚合并取任一原样大小写作为展示名（MAX(tag) 稳定可预期）。
        let mut stmt = conn.prepare(
            r#"
            SELECT MAX(ct.tag) AS name, COUNT(*) AS cnt
            FROM clip_tags ct
            JOIN clip_items ci ON ct.clip_id = ci.id
            WHERE ci.deleted_at IS NULL
            GROUP BY lower(ct.tag)
            ORDER BY cnt DESC, name ASC
            "#,
        )?;
        let rows = stmt.query_map([], |row| {
            Ok(TagStat {
                name: row.get(0)?,
                count: row.get::<_, i64>(1)? as u32,
            })
        })?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r?);
        }
        Ok(out)
    }

    /// 全库重命名标签（大小写不敏感匹配）。合并到已存在的同名标签。
    /// 返回受影响的条目数（去重后的 clip_id 数）。
    pub fn rename_tag(&self, old: &str, new: &str) -> Result<u32> {
        let Some(new_norm) = Self::normalize_tag(new) else {
            return Ok(0);
        };
        let old_key = Self::normalize_tag(old)
            .map(|t| t.to_lowercase())
            .unwrap_or_else(|| old.to_lowercase());
        if old_key.is_empty() || old_key == new_norm.to_lowercase() {
            // 新旧判重键相同：仅大小写/空白差异，无需改动。
            return Ok(0);
        }
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        // 收集旧标签关联的条目（未删除）。
        let affected: Vec<String> = {
            let mut stmt = tx.prepare(
                "SELECT DISTINCT clip_id FROM clip_tags \
                 WHERE tag = ?1 COLLATE NOCASE",
            )?;
            let rows = stmt.query_map(params![old], |r| r.get::<_, String>(0))?;
            rows.collect::<std::result::Result<Vec<_>, _>>()?
        };
        if affected.is_empty() {
            tx.commit()?;
            return Ok(0);
        }
        let now = Self::unix_now();
        let mut touched: Vec<String> = Vec::new();
        for clip_id in &affected {
            let mut current: Vec<String> =
                load_tags_for(&tx, std::slice::from_ref(clip_id))?.remove(clip_id).unwrap_or_default();
            // 删除旧标签、插入新标签（若已存在同名则合并，不重复）。
            let mut new_list: Vec<String> = Vec::new();
            let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
            for t in current.drain(..) {
                if t.to_lowercase() == old_key {
                    continue; // 旧标签移除
                }
                let key = t.to_lowercase();
                if seen.insert(key) {
                    new_list.push(t);
                }
            }
            let new_key = new_norm.to_lowercase();
            if !seen.contains(&new_key) && new_list.len() < MAX_TAGS_PER_ITEM {
                new_list.push(new_norm.clone());
            }
            // 仅在结果确实变化时更新（旧标签本就在、新标签合并）。
            Self::write_tags_in_tx(&tx, clip_id, &new_list, now)?;
            touched.push(clip_id.clone());
        }
        tx.commit()?;
        Ok(touched.len() as u32)
    }

    /// 删除某标签（解除所有关联），不删除条目。返回受影响条目数。
    pub fn delete_tag(&self, name: &str) -> Result<u32> {
        let key = Self::normalize_tag(name)
            .map(|t| t.to_lowercase())
            .unwrap_or_else(|| name.to_lowercase());
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        let affected: Vec<String> = {
            let mut stmt = tx.prepare(
                "SELECT DISTINCT clip_id FROM clip_tags WHERE tag = ?1 COLLATE NOCASE",
            )?;
            let rows = stmt.query_map(params![name], |r| r.get::<_, String>(0))?;
            rows.collect::<std::result::Result<Vec<_>, _>>()?
        };
        if affected.is_empty() {
            tx.commit()?;
            return Ok(0);
        }
        let now = Self::unix_now();
        for clip_id in &affected {
            let current: Vec<String> =
                load_tags_for(&tx, std::slice::from_ref(clip_id))?.remove(clip_id).unwrap_or_default();
            let filtered: Vec<String> = current
                .into_iter()
                .filter(|t| t.to_lowercase() != key)
                .collect();
            Self::write_tags_in_tx(&tx, clip_id, &filtered, now)?;
        }
        tx.commit()?;
        Ok(affected.len() as u32)
    }

    /// 在事务内读取单条摘要（带 tags），供标签写操作回显。
    fn load_summary_in_tx(tx: &rusqlite::Transaction<'_>, id: &str) -> Result<ClipItemSummary> {
        let assets_dir_snapshot = None; // 标签写操作不涉及载荷路径解析，返回原始路径即可
        let mut summary = tx.query_row(
            &format!(
                r#"
                SELECT {columns}
                FROM clip_items ci
                LEFT JOIN clip_payloads cp ON ci.id = cp.id
                WHERE ci.id = ?1
                "#,
                columns = summary_columns("ci.summary"),
            ),
            params![id],
            |row| map_summary_row(row, assets_dir_snapshot),
        )?;
        if let Some(tags) = load_tags_for(tx, &[id.to_string()])?.remove(id) {
            summary.tags = tags;
        }
        Ok(summary)
    }

    pub fn toggle_sensitive(&self, id: &str) -> Result<ClipItemSummary> {
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;

        let row: Option<(
            String,
            String,
            String,
            bool,
            Option<String>,
            Option<String>,
            Option<Vec<u8>>,
            Option<Vec<u8>>,
            Option<String>,
            Option<String>,
            Option<String>,
            Option<String>,
        )> = tx
            .query_row(
                r#"
                SELECT ci.item_type, ci.title, ci.summary, ci.is_sensitive, ci.payload_path,
                       cp.raw_text, cp.encrypted_content, cp.nonce, cp.ocr_text, cp.metadata_json,
                       ci.source_app_name, ci.source_app_bundle_id
                FROM clip_items ci
                LEFT JOIN clip_payloads cp ON ci.id = cp.id
                WHERE ci.id = ?1
                "#,
                params![id],
                |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get::<_, i64>(3)? == 1,
                        row.get(4)?,
                        row.get(5)?,
                        row.get(6)?,
                        row.get(7)?,
                        row.get(8)?,
                        row.get(9)?,
                        row.get(10)?,
                        row.get(11)?,
                    ))
                },
            )
            .optional()?;

        let (
            item_type,
            title,
            summary,
            is_sensitive,
            payload_path,
            raw_text,
            encrypted_content,
            nonce,
            ocr_text,
            metadata_json,
            source_app_name,
            source_app_bundle_id,
        ) = match row {
            Some(v) => v,
            None => return Err(CoreError::NotFound(id.to_string())),
        };

        let now = Self::unix_now();

        if !is_sensitive {
            let plain = raw_text.filter(|s| !s.is_empty()).unwrap_or(summary);
            let (enc, n) = self.crypto.encrypt(&plain)?;
            let new_summary = crate::algorithms::sensitive::mask_sensitive_text(&plain);

            tx.execute(
                r#"
                UPDATE clip_items
                SET is_sensitive = 1,
                    summary = ?1,
                    kind = 'sensitive',
                    updated_at = ?2
                WHERE id = ?3
                "#,
                params![&new_summary, now, id],
            )?;

            // OCR 文本一并纳入加密：ocr_text 明文列对敏感行必须为 NULL，
            // 否则敏感正文以明文落盘，且会被短词 LIKE 回退检索到。
            let (ocr_enc, ocr_n) = match ocr_text.as_deref().filter(|s| !s.is_empty()) {
                Some(text) => {
                    let (e, n) = self.crypto.encrypt(text)?;
                    (Some(e), Some(n.to_vec()))
                }
                None => (None, None),
            };

            tx.execute(
                r#"
                INSERT INTO clip_payloads (id, raw_text, encrypted_content, nonce, ocr_text, ocr_encrypted, ocr_nonce)
                VALUES (?3, NULL, ?1, ?2, NULL, ?4, ?5)
                ON CONFLICT(id) DO UPDATE SET
                    raw_text = NULL,
                    ocr_text = NULL,
                    encrypted_content = excluded.encrypted_content,
                    nonce = excluded.nonce,
                    ocr_encrypted = COALESCE(excluded.ocr_encrypted, clip_payloads.ocr_encrypted),
                    ocr_nonce = COALESCE(excluded.ocr_nonce, clip_payloads.ocr_nonce)
                "#,
                params![&enc, &n.to_vec(), id, &ocr_enc, &ocr_n],
            )?;

            tx.execute(
                "DELETE FROM clip_fts WHERE rowid = (SELECT rowid FROM clip_items WHERE id = ?1)",
                params![id],
            )?;
            tx.execute(
                r#"
                INSERT INTO clip_fts (
                    rowid, title, summary, ocr_text, source_app_name, source_app_bundle_id, clip_id
                )
                SELECT rowid, title, '', '', '', '', id
                FROM clip_items WHERE id = ?1
                "#,
                params![id],
            )?;
        } else {
            let plain = match (encrypted_content, nonce) {
                (Some(c), Some(n)) => self.crypto.decrypt(&c, &n)?,
                _ => {
                    return Err(CoreError::InvalidData(
                        "Missing encrypted content or nonce for sensitive item".to_string(),
                    ))
                }
            };

            let (kind_str, resolved_metadata_json) = compute_kind_and_metadata(
                &item_type,
                false,
                metadata_json.as_deref(),
                &plain,
                payload_path.as_deref(),
            );

            let new_summary = plain.clone();

            tx.execute(
                r#"
                UPDATE clip_items
                SET is_sensitive = 0,
                    summary = ?1,
                    kind = ?2,
                    updated_at = ?3
                WHERE id = ?4
                "#,
                params![&new_summary, kind_str, now, id],
            )?;

            let raw_text_to_set = if item_type == "text" || item_type == "url" {
                Some(plain.as_str())
            } else {
                None
            };

            // 解除敏感：OCR 文本从密文列还原回明文列，并清空密文
            tx.execute(
                r#"
                UPDATE clip_payloads
                SET raw_text = ?1,
                    encrypted_content = NULL,
                    nonce = NULL,
                    metadata_json = ?2
                WHERE id = ?3
                "#,
                params![raw_text_to_set, resolved_metadata_json.as_deref(), id],
            )?;
            // 解密 OCR 密文（在事务内完成，失败则整体回滚，不会留下「已解除敏感但 OCR 丢失」的中间态）
            let ocr_plain: Option<String> = {
                let cipher_row: Option<(Option<Vec<u8>>, Option<Vec<u8>>)> = tx
                    .query_row(
                        "SELECT ocr_encrypted, ocr_nonce FROM clip_payloads WHERE id = ?1",
                        params![id],
                        |r| Ok((r.get(0)?, r.get(1)?)),
                    )
                    .optional()?;
                match cipher_row {
                    Some((Some(c), Some(n))) => Some(self.crypto.decrypt(&c, &n)?),
                    _ => None,
                }
            };
            tx.execute(
                "UPDATE clip_payloads SET ocr_text = ?1, ocr_encrypted = NULL, ocr_nonce = NULL WHERE id = ?2",
                params![ocr_plain.as_deref(), id],
            )?;

            tx.execute(
                "DELETE FROM clip_fts WHERE rowid = (SELECT rowid FROM clip_items WHERE id = ?1)",
                params![id],
            )?;
            // FTS 用刚还原出的 OCR 明文：事务开始时读到的 ocr_text 对敏感行是 NULL，
            // 直接复用会让解除敏感后的条目丢失 OCR 检索能力。
            tx.execute(
                r#"
                INSERT INTO clip_fts (
                    rowid, title, summary, ocr_text, source_app_name, source_app_bundle_id, clip_id
                ) VALUES ((SELECT rowid FROM clip_items WHERE id = ?6), ?1, ?2, ?3, ?4, ?5, ?6)
                "#,
                params![
                    &title,
                    &new_summary,
                    ocr_plain.as_deref().unwrap_or(""),
                    source_app_name.as_deref().unwrap_or(""),
                    source_app_bundle_id.as_deref().unwrap_or(""),
                    id,
                ],
            )?;
        }

        tx.commit()?;
        drop(conn);

        self.get_item_summary(id)
    }

    pub fn soft_delete(&self, id: &str) -> Result<()> {
        let conn = self.conn.lock();
        let now = Self::unix_now();
        // 幂等软删：已带 deleted_at 的条目保留原始删除时间（撤销宽限窗口按首次删除计时）
        conn.execute(
            "UPDATE clip_items SET deleted_at = COALESCE(deleted_at, ?1), updated_at = ?1 WHERE id = ?2",
            params![now, id],
        )?;
        Ok(())
    }

    /// 从回收站恢复条目。
    ///
    /// 必须同时重建 FTS 行：同步对账在远端软删时会删掉 FTS 行，而恢复路径
    /// 若只把 `deleted_at` 置 NULL，条目回到列表却永远搜不到（实测复现）。
    /// 本地软删/恢复不受影响（soft_delete 不动 FTS），此处重建是幂等的。
    pub fn restore_deleted(&self, id: &str) -> Result<()> {
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        let now = Self::unix_now();
        tx.execute(
            "UPDATE clip_items SET deleted_at = NULL, updated_at = ?1 WHERE id = ?2",
            params![now, id],
        )?;
        Self::rebuild_fts_row_in_tx(&tx, id)?;
        tx.commit()?;
        Ok(())
    }

    /// 按 `clip_items` 当前状态重建单条 FTS 行（rowid 对齐不变量：
    /// clip_fts.rowid == clip_items.rowid）。敏感条目的正文/OCR/来源一律留空。
    fn rebuild_fts_row_in_tx(tx: &rusqlite::Transaction<'_>, id: &str) -> Result<()> {
        let rowid: Option<i64> = tx
            .query_row(
                "SELECT rowid FROM clip_items WHERE id = ?1",
                params![id],
                |r| r.get(0),
            )
            .optional()?;
        let Some(rowid) = rowid else {
            return Ok(());
        };
        tx.execute("DELETE FROM clip_fts WHERE rowid = ?1", params![rowid])?;
        // 已软删的条目不应留在索引里（与对账路径一致）
        let deleted: bool = tx.query_row(
            "SELECT deleted_at IS NOT NULL FROM clip_items WHERE id = ?1",
            params![id],
            |r| r.get::<_, i64>(0),
        )? == 1;
        if deleted {
            return Ok(());
        }
        tx.execute(
            r#"
            INSERT INTO clip_fts (
                rowid, title, summary, ocr_text, source_app_name, source_app_bundle_id, tags, clip_id
            )
            SELECT ci.rowid, ci.title,
                   CASE WHEN ci.is_sensitive = 1 THEN '' ELSE ci.summary END,
                   CASE WHEN ci.is_sensitive = 1 THEN '' ELSE COALESCE(cp.ocr_text, '') END,
                   CASE WHEN ci.is_sensitive = 1 THEN '' ELSE COALESCE(ci.source_app_name, '') END,
                   CASE WHEN ci.is_sensitive = 1 THEN '' ELSE COALESCE(ci.source_app_bundle_id, '') END,
                   COALESCE((SELECT group_concat(ct.tag, ' ') FROM clip_tags ct WHERE ct.clip_id = ci.id), ''),
                   ci.id
            FROM clip_items ci
            LEFT JOIN clip_payloads cp ON ci.id = cp.id
            WHERE ci.id = ?1
            "#,
            params![id],
        )?;
        Ok(())
    }

    /// 同步/导入用：全量替换某条目的标签集合（在事务内）。
    /// - DELETE + INSERT clip_tags（判重键 NOCASE，保留原大小写）
    /// - 推进 clip_items.tags_updated_at
    /// - 刷新 clip_fts.tags 列（须在 FTS 重建之后调用，避免被重建覆盖）
    /// 注意：调用方需保证 tags 已规范化（远端来自同代码设备，导入路径经 normalize_tag）。
    fn sync_write_tags_in_tx(
        tx: &rusqlite::Transaction<'_>,
        clip_id: &str,
        tags: &[String],
        tags_updated_at: f64,
    ) -> Result<()> {
        tx.execute("DELETE FROM clip_tags WHERE clip_id = ?1", params![clip_id])?;
        let base = Self::unix_now();
        for (i, tag) in tags.iter().enumerate() {
            if tag.is_empty() {
                continue;
            }
            tx.execute(
                "INSERT OR IGNORE INTO clip_tags (clip_id, tag, created_at) VALUES (?1, ?2, ?3)",
                params![clip_id, tag, base + i as f64 * 1e-6],
            )?;
        }
        tx.execute(
            "UPDATE clip_items SET tags_updated_at = ?1 WHERE id = ?2",
            params![tags_updated_at, clip_id],
        )?;
        let tags_text = tags.join(" ");
        tx.execute(
            "UPDATE clip_fts SET tags = ?1 WHERE rowid = (SELECT rowid FROM clip_items WHERE id = ?2)",
            params![tags_text, clip_id],
        )?;
        Ok(())
    }

    pub fn purge_item(&self, id: &str) -> Result<()> {
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        Self::record_tombstone_in_tx(&tx, id)?;
        tx.execute("DELETE FROM clip_fts WHERE rowid = (SELECT rowid FROM clip_items WHERE id = ?1)", params![id])?;
        tx.execute("DELETE FROM clip_payloads WHERE id = ?1", params![id])?;
        tx.execute("DELETE FROM clip_items WHERE id = ?1", params![id])?;
        tx.commit()?;
        Ok(())
    }

    pub fn clear_all_history(&self, keep_favorites: bool) -> Result<Vec<PrunedItemRecord>> {
        let assets_dir = self.assets_dir();
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        let now = Self::unix_now();
        let records = {
            let mut stmt = if keep_favorites {
                tx.prepare("SELECT id, item_type, payload_path FROM clip_items WHERE favorite = 0")?
            } else {
                tx.prepare("SELECT id, item_type, payload_path FROM clip_items")?
            };

            let rows = stmt.query_map([], |row| {
                let id: String = row.get(0)?;
                let item_type: String = row.get(1)?;
                let stored: Option<String> = row.get(2)?;
                Ok(PrunedItemRecord {
                    id,
                    payload_path: PayloadAssetStore::resolve_for_runtime(
                        &item_type,
                        stored.as_deref(),
                        assets_dir.as_deref(),
                    ),
                })
            })?;

            let mut records = Vec::new();
            for r in rows {
                records.push(r?);
            }
            records
        };

        if keep_favorites {
            tx.execute(
                "INSERT OR REPLACE INTO sync_tombstones (id, deleted_at) SELECT id, ?1 FROM clip_items WHERE favorite = 0",
                params![now],
            )?;
            tx.execute(
                "DELETE FROM clip_fts WHERE rowid IN (SELECT rowid FROM clip_items WHERE favorite = 0)",
                [],
            )?;
            tx.execute(
                "DELETE FROM clip_payloads WHERE id IN (SELECT id FROM clip_items WHERE favorite = 0)",
                [],
            )?;
            tx.execute("DELETE FROM clip_items WHERE favorite = 0", [])?;
        } else {
            tx.execute(
                "INSERT OR REPLACE INTO sync_tombstones (id, deleted_at) SELECT id, ?1 FROM clip_items",
                params![now],
            )?;
            tx.execute("DELETE FROM clip_fts", [])?;
            tx.execute("DELETE FROM clip_payloads", [])?;
            tx.execute("DELETE FROM clip_items", [])?;
        }
        tx.commit()?;
        drop(conn);
        // 清空历史会写入与删除同规模的 WAL（实测 4.6 万行 → 40MB+，且永不自动回收）。
        // 显式 TRUNCATE，让 -wal 文件立刻回落到 journal_size_limit 以内。
        {
            let conn = self.conn.lock();
            crate::storage::schema::checkpoint_truncate(&conn);
        }
        Ok(records)
    }

    fn unix_now() -> f64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs_f64()
    }

    /// 硬删除前记录云端墓碑（行删除后导出器无法再看到它）
    fn record_tombstone_in_tx(tx: &rusqlite::Transaction<'_>, id: &str) -> Result<()> {
        tx.execute(
            "INSERT OR REPLACE INTO sync_tombstones (id, deleted_at) VALUES (?1, ?2)",
            params![id, Self::unix_now()],
        )?;
        Ok(())
    }

    /// 批量硬删除一组条目（同事务内）：墓碑 → FTS → payloads → items。
    /// 分块执行集合级 SQL，把每条的 4~5 次往返降为每块 4 次。
    /// 不变量：clip_fts.rowid == clip_items.rowid，故 FTS 按 rowid 集合删。
    fn batch_hard_delete_in_tx(
        tx: &rusqlite::Transaction<'_>,
        candidates: &[(String, i64)],
    ) -> Result<()> {
        if candidates.is_empty() {
            return Ok(());
        }
        let now = Self::unix_now();
        const CHUNK: usize = 100;

        for chunk in candidates.chunks(CHUNK) {
            let rowids: Vec<i64> = chunk
                .iter()
                .filter(|(_, rowid)| *rowid >= 0)
                .map(|(_, rowid)| *rowid)
                .collect();

            // 墓碑：按 ID 批量 INSERT ... SELECT（同步语义：客户端按 ID 收敛删除）
            let ids_json = serde_json::to_string(
                &chunk.iter().map(|(id, _)| id.as_str()).collect::<Vec<_>>(),
            )
            .unwrap_or_else(|_| "[]".to_string());
            tx.execute(
                "INSERT OR REPLACE INTO sync_tombstones (id, deleted_at) \
                 SELECT value, ?1 FROM json_each(?2)",
                params![now, ids_json],
            )?;

            if !rowids.is_empty() {
                let rowid_list = rowids
                    .iter()
                    .map(|r| r.to_string())
                    .collect::<Vec<_>>()
                    .join(",");
                tx.execute(
                    &format!("DELETE FROM clip_fts WHERE rowid IN ({rowid_list})"),
                    [],
                )?;
            }
            let id_params = chunk
                .iter()
                .map(|(id, _)| id.clone())
                .collect::<Vec<_>>();
            let id_placeholders = vec!["?"; id_params.len()].join(",");
            tx.execute(
                &format!("DELETE FROM clip_payloads WHERE id IN ({id_placeholders})"),
                rusqlite::params_from_iter(id_params.iter()),
            )?;
            tx.execute(
                &format!("DELETE FROM clip_items WHERE id IN ({id_placeholders})"),
                rusqlite::params_from_iter(id_params.iter()),
            )?;
        }
        Ok(())
    }

    /// 回写 OCR 文本。
    ///
    /// 安全不变量：`is_sensitive = 1` 的行，OCR 文本只能进密文列
    ///（`ocr_encrypted`/`ocr_nonce`），明文列 `ocr_text` 必须为 NULL。
    /// 否则敏感正文会以明文落盘，并经短词 LIKE 回退被检索到。
    pub fn update_ocr_text(&self, id: &str, ocr_text: &str) -> Result<()> {
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;

        let is_sensitive: bool = tx
            .query_row(
                "SELECT is_sensitive FROM clip_items WHERE id = ?1",
                params![id],
                |r| Ok(r.get::<_, i64>(0)? == 1),
            )
            .optional()?
            .ok_or_else(|| CoreError::NotFound(id.to_string()))?;

        if is_sensitive {
            let (enc, n) = self.crypto.encrypt(ocr_text)?;
            tx.execute(
                "UPDATE clip_payloads SET ocr_text = NULL, ocr_encrypted = ?1, ocr_nonce = ?2 WHERE id = ?3",
                params![&enc, &n.to_vec(), id],
            )?;
        } else {
            tx.execute(
                "UPDATE clip_payloads SET ocr_text = ?1, ocr_encrypted = NULL, ocr_nonce = NULL WHERE id = ?2",
                params![ocr_text, id],
            )?;
        }
        tx.execute(
            "UPDATE clip_items SET updated_at = ?1 WHERE id = ?2",
            params![Self::unix_now(), id],
        )?;

        struct OcrFtsRecord {
            title: String,
            summary: String,
            app_name: Option<String>,
            app_bundle: Option<String>,
            is_sensitive: bool,
        }

        let item: Option<OcrFtsRecord> = tx
            .query_row(
                "SELECT title, summary, source_app_name, source_app_bundle_id, is_sensitive FROM clip_items WHERE id = ?1",
                params![id],
                |row| {
                    Ok(OcrFtsRecord {
                        title: row.get(0)?,
                        summary: row.get(1)?,
                        app_name: row.get(2)?,
                        app_bundle: row.get(3)?,
                        is_sensitive: row.get::<_, i64>(4)? == 1,
                    })
                },
            )
            .optional()?;

        if let Some(record) = item {
            tx.execute("DELETE FROM clip_fts WHERE rowid = (SELECT rowid FROM clip_items WHERE id = ?1)", params![id])?;
            let (fts_summary, fts_ocr, fts_app_name, fts_bundle_id) = if record.is_sensitive {
                ("", "", "", "")
            } else {
                (
                    record.summary.as_str(),
                    ocr_text,
                    record.app_name.as_deref().unwrap_or(""),
                    record.app_bundle.as_deref().unwrap_or(""),
                )
            };
            tx.execute(
                r#"
                INSERT INTO clip_fts (
                    rowid, title, summary, ocr_text, source_app_name, source_app_bundle_id, clip_id
                ) VALUES ((SELECT rowid FROM clip_items WHERE id = ?6), ?1, ?2, ?3, ?4, ?5, ?6)
                "#,
                params![
                    &record.title,
                    fts_summary,
                    fts_ocr,
                    fts_app_name,
                    fts_bundle_id,
                    id,
                ],
            )?;
        }

        tx.commit()?;
        Ok(())
    }
    pub fn update_ocr_text_masked(&self, id: &str, raw_ocr_text: &str) -> Result<Option<String>> {
        let trimmed = raw_ocr_text.trim();
        if trimmed.is_empty() {
            return Ok(None);
        }
        let detection = crate::algorithms::sensitive::detect_sensitive(trimmed);
        let storable = if detection.is_sensitive {
            detection.masked_text
        } else {
            trimmed.to_string()
        };

        self.update_ocr_text(id, &storable)?;
        Ok(Some(storable))
    }
    pub fn update_title(&self, id: &str, title: &str) -> Result<()> {
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;

        tx.execute(
            "UPDATE clip_items SET title = ?1, updated_at = ?2 WHERE id = ?3",
            params![title, Self::unix_now(), id],
        )?;
        let updated_fts = tx.execute(
            "UPDATE clip_fts SET title = ?1 WHERE rowid = (SELECT rowid FROM clip_items WHERE id = ?2)",
            params![title, id],
        )?;
        if updated_fts == 0 {
            tx.execute(
                r#"
                INSERT INTO clip_fts (
                    rowid, title, summary, ocr_text, source_app_name, source_app_bundle_id, clip_id
                )
                SELECT ci.rowid, ?1,
                       CASE WHEN ci.is_sensitive = 1 THEN '' ELSE ci.summary END,
                       CASE WHEN ci.is_sensitive = 1 THEN '' ELSE COALESCE(cp.ocr_text, '') END,
                       CASE WHEN ci.is_sensitive = 1 THEN '' ELSE COALESCE(ci.source_app_name, '') END,
                       CASE WHEN ci.is_sensitive = 1 THEN '' ELSE COALESCE(ci.source_app_bundle_id, '') END,
                       ci.id
                FROM clip_items ci
                LEFT JOIN clip_payloads cp ON ci.id = cp.id
                WHERE ci.id = ?2
                "#,
                params![title, id],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    pub fn prune_expired(&self, config: &RetentionConfig) -> Result<Vec<PrunedItemRecord>> {
        let assets_dir = self.assets_dir();
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;

        // 候选条目直接带出 rowid/item_type/payload_path，删除阶段无需逐条反查
        let mut candidates: Vec<(String, i64, String, Option<String>)> = Vec::new();

        // 1. Prune by max age
        if let Some(days) = config.max_age_days {
            if days > 0 {
                let cutoff = Self::unix_now() - (days as f64 * 86400.0);
                // 只清活跃条目：软删除条目在撤销宽限窗口内，由回收站路径处理
                let mut stmt = tx.prepare(
                    "SELECT id, rowid, item_type, payload_path FROM clip_items \
                     WHERE favorite = 0 AND deleted_at IS NULL AND last_used_at < ?1 \
                       AND NOT EXISTS (SELECT 1 FROM clip_tags ct WHERE ct.clip_id = clip_items.id)",
                )?;
                let rows = stmt.query_map(params![cutoff], |r| {
                    Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
                })?;
                for r in rows {
                    candidates.push(r?);
                }
            }
        }

        // 2. Prune by max item count
        if let Some(max_items) = config.max_item_count {
            if max_items > 0 {
                let total: i64 = tx.query_row(
                    "SELECT COUNT(*) FROM clip_items WHERE favorite = 0 AND deleted_at IS NULL",
                    [],
                    |r| r.get(0),
                )?;
                if total > max_items as i64 {
                    let excess = total - max_items as i64;
                    let mut stmt = tx.prepare(
                        "SELECT id, rowid, item_type, payload_path FROM clip_items \
                         WHERE favorite = 0 AND deleted_at IS NULL \
                           AND NOT EXISTS (SELECT 1 FROM clip_tags ct WHERE ct.clip_id = clip_items.id) \
                         ORDER BY last_used_at ASC LIMIT ?1",
                    )?;
                    let rows = stmt.query_map(params![excess], |r| {
                        Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
                    })?;
                    for r in rows {
                        candidates.push(r?);
                    }
                }
            }
        }

        // 顺手清理超期云端墓碑（7 天后不再随 pack 广播）
        tx.execute(
            "DELETE FROM sync_tombstones WHERE deleted_at < ?1",
            params![Self::unix_now() - crate::sync::TOMBSTONE_RETENTION_SECS],
        )?;

        if candidates.is_empty() {
            tx.commit()?;
            return Ok(Vec::new());
        }

        // 按 id 去重（两条规则可能命中同一行）
        candidates.sort_by(|a, b| a.0.cmp(&b.0));
        candidates.dedup_by(|a, b| a.0 == b.0);

        let mut records = Vec::with_capacity(candidates.len());
        for (id, _, item_type, stored_path) in &candidates {
            records.push(PrunedItemRecord {
                id: id.clone(),
                payload_path: PayloadAssetStore::resolve_for_runtime(
                    item_type,
                    stored_path.as_deref(),
                    assets_dir.as_deref(),
                ),
            });
        }

        let id_rowids: Vec<(String, i64)> = candidates
            .into_iter()
            .map(|(id, rowid, _, _)| (id, rowid))
            .collect();
        Self::batch_hard_delete_in_tx(&tx, &id_rowids)?;

        tx.commit()?;
        drop(conn);
        if !records.is_empty() {
            // 保留期清理是最大的单次硬删除来源（5 万行库一次可删数千行），
            // 提交后截断 WAL，避免 -wal 长期停在几十 MB。
            let conn = self.conn.lock();
            crate::storage::schema::checkpoint_truncate(&conn);
        }
        Ok(records)
    }

    /// 磁盘配额驱逐：仅统计 managed_dir 下受管载荷文件字节数，
    /// 超出 limit_bytes 时按 LRU（last_used_at 升序）彻底删除非收藏或已软删除条目并记录墓碑，
    /// 返回被驱逐条目的 PrunedItemRecord 列表。
    pub fn enforce_disk_limit(
        &self,
        managed_dir: &str,
        limit_bytes: u64,
    ) -> Result<Vec<PrunedItemRecord>> {
        if limit_bytes == 0 {
            return Ok(Vec::new());
        }
        let root = std::path::Path::new(managed_dir);
        let candidates: Vec<(String, String, String, bool, bool, f64, bool)> = {
            let conn = self.conn.lock();
            let mut stmt = conn.prepare(
                r#"
                SELECT id, item_type, payload_path, favorite, deleted_at IS NOT NULL, last_used_at,
                       EXISTS(SELECT 1 FROM clip_tags ct WHERE ct.clip_id = clip_items.id) AS has_tags
                FROM clip_items
                WHERE payload_path IS NOT NULL AND payload_path != ''
                ORDER BY last_used_at ASC
                "#,
            )?;
            let rows = stmt.query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, i64>(3)? == 1,
                    row.get::<_, bool>(4)?,
                    row.get::<_, f64>(5)?,
                    row.get::<_, bool>(6)?,
                ))
            })?;
            rows.collect::<std::result::Result<Vec<_>, _>>()?
        };

        let mut total_bytes: u64 = 0;
        let mut evictable: Vec<(String, String, u64, f64)> = Vec::new();

        for (id, item_type, path_str, is_favorite, is_deleted, last_used_at, has_tags) in candidates {
            let resolved = PayloadAssetStore::resolve_for_runtime(
                &item_type,
                Some(&path_str),
                Some(root),
            )
            .unwrap_or(path_str);
            let path = std::path::Path::new(&resolved);
            if !path.starts_with(root) {
                continue;
            }
            let size = std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);
            total_bytes = total_bytes.saturating_add(size);
            // 带标签的条目受保护：不参与 LRU 磁盘驱逐。
            if (is_deleted || !is_favorite) && !has_tags {
                evictable.push((id, resolved, size, last_used_at));
            }
        }

        if total_bytes <= limit_bytes {
            return Ok(Vec::new());
        }

        evictable.sort_by(|a, b| a.3.partial_cmp(&b.3).unwrap_or(std::cmp::Ordering::Equal));

        let mut to_evict: Vec<(String, String)> = Vec::new();
        for (id, path_str, size, _) in evictable {
            if total_bytes <= limit_bytes {
                break;
            }
            to_evict.push((id, path_str));
            total_bytes = total_bytes.saturating_sub(size);
        }

        if to_evict.is_empty() {
            return Ok(Vec::new());
        }

        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        let mut records = Vec::with_capacity(to_evict.len());
        let mut id_rowids: Vec<(String, i64)> = Vec::with_capacity(to_evict.len());
        for (id, path_str) in to_evict {
            // 删除前复核：候选集是「释放锁做 metadata 遍历之前」的快照，
            // 期间用户可能已收藏该条目或从回收站恢复它。不复核就会物理删除
            // 用户刚收藏的内容（并写墓碑，无法从对端恢复）。
            let still_evictable: Option<i64> = tx
                .query_row(
                    "SELECT rowid FROM clip_items WHERE id = ?1 \
                     AND (favorite = 0 OR deleted_at IS NOT NULL) \
                     AND NOT EXISTS (SELECT 1 FROM clip_tags ct WHERE ct.clip_id = clip_items.id)",
                    params![&id],
                    |r| r.get(0),
                )
                .optional()?;
            let Some(rowid) = still_evictable else {
                continue;
            };
            id_rowids.push((id.clone(), rowid));
            records.push(PrunedItemRecord {
                id,
                payload_path: Some(path_str),
            });
        }
        Self::batch_hard_delete_in_tx(&tx, &id_rowids)?;
        tx.commit()?;
        drop(conn);
        if !records.is_empty() {
            let conn = self.conn.lock();
            crate::storage::schema::checkpoint_truncate(&conn);
        }
        Ok(records)
    }

    fn get_item_summary(&self, id: &str) -> Result<ClipItemSummary> {
        let assets_dir = self.assets_dir();
        let conn = self.conn.lock();
        conn.query_row(
            &format!(
                r#"
            SELECT {columns}
            FROM clip_items ci
            LEFT JOIN clip_payloads cp ON ci.id = cp.id
            WHERE ci.id = ?1
            "#,
                columns = summary_columns("ci.summary"),
            ),
            params![id],
            |row| map_summary_row(row, assets_dir.as_deref()),
        )
        .map_err(|e| match e {
            rusqlite::Error::QueryReturnedNoRows => CoreError::NotFound(id.to_string()),
            other => CoreError::Database(other),
        })
    }
    pub fn count_items(&self) -> Result<u64> {
        let conn = self.conn.lock();
        let count: i64 = conn.query_row(
            "SELECT COUNT(*) FROM clip_items WHERE deleted_at IS NULL",
            [],
            |r| r.get(0),
        )?;
        Ok(count as u64)
    }

    pub fn count_favorites(&self) -> Result<u64> {
        let conn = self.conn.lock();
        let count: i64 = conn.query_row(
            "SELECT COUNT(*) FROM clip_items WHERE favorite = 1 AND deleted_at IS NULL",
            [],
            |r| r.get(0),
        )?;
        Ok(count as u64)
    }
    /// 导出同步条目。安全不变量：敏感条目绝不导出（pack 仅压缩不加密）；
    /// 除活跃条目与软删墓碑外，还合并硬删除路径留下的 sync_tombstones。
    /// 导出同步条目。默认导出最近 500 条活跃条目 + 全部收藏 + 7 天内墓碑。
    pub fn export_sync_items(
        &self,
        assets_dir: Option<&str>,
    ) -> Result<Vec<crate::sync::SyncItemRecord>> {
        self.export_sync_items_ext(assets_dir, false, Some(500))
    }

    pub fn export_sync_items_ext(
        &self,
        assets_dir: Option<&str>,
        allow_sensitive: bool,
        max_active_items: Option<u32>,
    ) -> Result<Vec<crate::sync::SyncItemRecord>> {
        let conn = self.conn.lock();
        let tombstone_cutoff = Self::unix_now() - crate::sync::TOMBSTONE_RETENTION_SECS;
        let limit_val = max_active_items.unwrap_or(500) as i64;
        let sensitive_flag = if allow_sensitive { 1 } else { 0 };

        let mut stmt = conn.prepare(
            r#"
            SELECT ci.id, ci.item_type, ci.title, ci.summary, cp.raw_text,
                   ci.is_sensitive, ci.favorite, ci.created_at, ci.last_used_at, ci.deleted_at,
                   ci.updated_at, ci.copy_count, ci.payload_path,
                   ci.source_app_bundle_id, ci.source_app_name,
                   ci.source_device_id, ci.source_device_name, ci.source_platform,
                   cp.encrypted_content, cp.nonce, ci.favorite_updated_at, ci.tags_updated_at
            FROM clip_items ci
            LEFT JOIN clip_payloads cp ON ci.id = cp.id
            WHERE (ci.is_sensitive = 0 OR ?2 = 1)
              AND (
                  ci.id IN (
                      SELECT id FROM clip_items
                      WHERE deleted_at IS NULL AND (is_sensitive = 0 OR ?2 = 1)
                      ORDER BY last_used_at DESC LIMIT ?3
                  )
                  OR (ci.favorite = 1 AND ci.deleted_at IS NULL)
                  OR (ci.deleted_at IS NOT NULL AND ci.deleted_at >= ?1)
              )
            ORDER BY ci.last_used_at DESC
            "#
        )?;

        let rows = stmt.query_map(
            params![tombstone_cutoff, sensitive_flag, limit_val],
            |row| {
            let id: String = row.get(0)?;
            let item_type: String = row.get(1)?;
            let title: String = row.get(2)?;
            let summary: String = row.get(3)?;
            let raw_text: Option<String> = row.get(4)?;
            let is_sensitive: bool = row.get::<_, i64>(5)? == 1;
            let is_favorite: bool = row.get::<_, i64>(6)? == 1;
            let created_at: f64 = row.get(7)?;
            let last_used_at: f64 = row.get(8)?;
            let deleted_at: Option<f64> = row.get(9)?;
            let updated_at: f64 = row.get(10)?;
            let copy_count: i64 = row.get(11)?;
            let payload_path: Option<String> = row.get(12)?;
            let source_app_bundle_id: Option<String> = row.get(13)?;
            let source_app_name: Option<String> = row.get(14)?;
            let source_device_id: Option<String> = row.get(15)?;
            let source_device_name: Option<String> = row.get(16)?;
            let source_platform: Option<String> = row.get(17)?;
            let encrypted_content: Option<Vec<u8>> = row.get(18)?;
            let nonce: Option<Vec<u8>> = row.get(19)?;
            let favorite_updated_at: f64 = row.get(20)?;
            let tags_updated_at: f64 = row.get(21)?;

            // 附件池：单张附件上限 5MB，超限附件仅留存本机，不随 pack 同步
            let asset_file_name = if item_type == "file" {
                None
            } else {
                payload_path.as_deref().and_then(|p| {
                    let dir = std::path::Path::new(assets_dir?);
                    let target_path = if !p.contains('/') && !p.contains('\\') {
                        let candidate = dir.join(p);
                        if candidate.exists() { Some(candidate) } else { None }
                    } else {
                        let path = std::path::Path::new(p);
                        if path.starts_with(dir) { Some(path.to_path_buf()) } else { None }
                    };
                    let path = target_path?;
                    let meta = std::fs::metadata(&path).ok()?;
                    if meta.len() > crate::sync::MAX_SYNC_ASSET_BYTES {
                        return None;
                    }
                    path.file_name()
                        .and_then(|n| n.to_str())
                        .map(|n| n.to_string())
                })
            };

            Ok((
                crate::sync::SyncItemRecord {
                    id,
                    item_type,
                    title,
                    summary,
                    raw_text,
                    is_sensitive,
                    is_favorite,
                    created_at,
                    last_used_at,
                    updated_at,
                    favorite_updated_at,
                    copy_count,
                    asset_file_name,
                    deleted_at,
                    source_app_bundle_id,
                    source_app_name,
                    source_device_id,
                    source_device_name,
                    source_platform,
                    // tags 在收集完成后批量回填（避免 N+1）
                    tags: Vec::new(),
                    tags_updated_at,
                },
                encrypted_content,
                nonce,
            ))
        })?;

        let mut items = Vec::new();
        for row in rows {
            let (mut item, encrypted_content, nonce) = row?;
            if item.is_sensitive && item.raw_text.is_none() {
                if let (Some(enc), Some(n)) = (encrypted_content, nonce) {
                    item.raw_text = Some(self.crypto.decrypt(&enc, &n)?);
                }
            }
            items.push(item);
        }

        // 批量回填 tags（升序），避免 N+1：一次性查所有涉及 id 的 clip_tags。
        if !items.is_empty() {
            let mut tag_map: HashMap<String, Vec<String>> = HashMap::new();
            let mut stmt = conn.prepare(
                "SELECT clip_id, tag FROM clip_tags ORDER BY clip_id, created_at ASC, tag ASC",
            )?;
            let rows = stmt.query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?;
            for row in rows {
                let (clip_id, tag) = row?;
                tag_map.entry(clip_id).or_default().push(tag);
            }
            for item in &mut items {
                if let Some(tags) = tag_map.remove(&item.id) {
                    item.tags = tags;
                }
            }
        }

        // 硬删除墓碑：行已物理删除，只携带 id 与删除时间让对端软删同 id 条目
        {
            let mut stmt = conn.prepare(
                "SELECT id, deleted_at FROM sync_tombstones WHERE deleted_at >= ?1",
            )?;
            let rows = stmt.query_map(params![tombstone_cutoff], |row| {
                let id: String = row.get(0)?;
                let deleted_at: f64 = row.get(1)?;
                Ok(crate::sync::SyncItemRecord {
                    id,
                    item_type: String::new(),
                    title: String::new(),
                    summary: String::new(),
                    raw_text: None,
                    is_sensitive: false,
                    is_favorite: false,
                    created_at: deleted_at,
                    last_used_at: deleted_at,
                    updated_at: deleted_at,
                    favorite_updated_at: 0.0,
                    copy_count: 0,
                    asset_file_name: None,
                    deleted_at: Some(deleted_at),
                    source_app_bundle_id: None,
                    source_app_name: None,
                    source_device_id: None,
                    source_device_name: None,
                    source_platform: None,
                    tags: Vec::new(),
                    tags_updated_at: 0.0,
                })
            })?;
            for row in rows {
                items.push(row?);
            }
        }

        Ok(items)
    }

    pub fn get_sync_cursor(&self, device_id: &str) -> Result<Option<String>> {
        let conn = self.conn.lock();
        let res: Option<Option<String>> = conn
            .query_row(
                "SELECT last_fingerprint FROM sync_cursors WHERE device_id = ?1",
                params![device_id],
                |r| r.get(0),
            )
            .optional()?;
        Ok(res.flatten())
    }

    pub fn set_sync_cursor(&self, device_id: &str, fingerprint: &str) -> Result<()> {
        let conn = self.conn.lock();
        let now = Self::unix_now();
        conn.execute(
            r#"
            INSERT INTO sync_cursors (device_id, last_fingerprint, synced_at)
            VALUES (?1, ?2, ?3)
            ON CONFLICT(device_id) DO UPDATE SET
                last_fingerprint = excluded.last_fingerprint,
                synced_at = excluded.synced_at
            "#,
            params![device_id, fingerprint, now],
        )?;
        Ok(())
    }

    pub fn get_all_sync_cursors(&self) -> Result<std::collections::HashMap<String, String>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare("SELECT device_id, last_fingerprint FROM sync_cursors WHERE last_fingerprint IS NOT NULL")?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
        let mut map = std::collections::HashMap::new();
        for r in rows {
            let (k, v) = r?;
            map.insert(k, v);
        }
        Ok(map)
    }
    pub fn reconcile_sync_items(
        &self,
        items: &[crate::sync::SyncItemRecord],
        asset_paths: &std::collections::HashMap<String, String>,
    ) -> Result<u32> {
        let assets_dir = self.assets_dir();
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        let mut merged_count = 0;

        for item in items {
            let local: Option<LocalSyncRow> = tx
                .query_row(
                    "SELECT last_used_at, deleted_at, copy_count, favorite, updated_at, id, favorite_updated_at, tags_updated_at \
                     FROM clip_items WHERE id = ?1",
                    params![&item.id],
                    |row| {
                        Ok(LocalSyncRow {
                            last_used_at: row.get(0)?,
                            deleted_at: row.get(1)?,
                            copy_count: row.get(2)?,
                            updated_at: row.get(4)?,
                            id: row.get(5)?,
                            favorite_updated_at: row.get(6)?,
                            tags_updated_at: row.get(7)?,
                        })
                    },
                )
                .optional()?;

            // 跨端同内容去重归并：若按 id 未命中，且为非敏感活跃条目，按 (item_type, summary) 查重归并存量行
            let local = match local {
                Some(l) => Some(l),
                None if !item.is_sensitive && item.deleted_at.is_none() => {
                    tx.query_row(
                        "SELECT last_used_at, deleted_at, copy_count, favorite, updated_at, id, favorite_updated_at, tags_updated_at \
                         FROM clip_items \
                         WHERE item_type = ?1 AND summary = ?2 AND is_sensitive = 0 AND deleted_at IS NULL \
                         ORDER BY last_used_at DESC LIMIT 1",
                        params![&item.item_type, &item.summary],
                        |row| {
                            Ok(LocalSyncRow {
                                last_used_at: row.get(0)?,
                                deleted_at: row.get(1)?,
                                copy_count: row.get(2)?,
                                updated_at: row.get(4)?,
                                id: row.get(5)?,
                                favorite_updated_at: row.get(6)?,
                                tags_updated_at: row.get(7)?,
                            })
                        },
                    ).optional()?
                }
                None => None,
            };

            match local {
                Some(local_row) => {
                    let matched_id = local_row.id.clone();
                    // 删除状态裁决（data-model §3 冲突矩阵）：
                    // - 本地活跃 / 远端删除：本地在远端删除之后还用过 → 保留本地，否则采纳删除
                    // - 本地删除 / 远端活跃：远端在本地删除之后有更新 → 恢复，否则保留删除
                    // 修复点：旧实现把 deleted_at 与 updated_at 混成一个标量比较，
                    // 导致「删除后又被粘贴/更新」会静默撤销删除。
                    let resolved_deleted = resolve_deleted_state(&local_row, item);
                    let deletion_changed = resolved_deleted != local_row.deleted_at;

                    // 元数据 LWW（标题/摘要/载荷/来源）：只看元数据编辑时间
                    let metadata_wins = item.updated_at > local_row.updated_at;
                    // 收藏 LWW：独立时钟。旧版对端不带 favorite_updated_at（=0），
                    // 回退到 updated_at 以保持旧行为（否则收藏永不传播）。
                    let remote_fav_time = if item.favorite_updated_at > 0.0 {
                        item.favorite_updated_at
                    } else {
                        item.updated_at
                    };
                    let local_fav_time = if local_row.favorite_updated_at > 0.0 {
                        local_row.favorite_updated_at
                    } else {
                        local_row.updated_at
                    };
                    let favorite_wins = remote_fav_time > local_fav_time;

                    // 标签对账：tags_win = 远端标签时间戳更新；
                    // 旧 pack（双方均为 0）时若本地无标签而远端有 → 取远端（非空优先）。
                    let local_tags_empty = tx
                        .query_row(
                            "SELECT COUNT(*) FROM clip_tags WHERE clip_id = ?1",
                            params![&matched_id],
                            |r| r.get::<_, i64>(0),
                        )? == 0;
                    let tags_win = item.tags_updated_at > local_row.tags_updated_at
                        || (item.tags_updated_at == 0.0
                            && local_row.tags_updated_at == 0.0
                            && local_tags_empty
                            && !item.tags.is_empty());

                    // 单调字段（copy_count / last_used_at）无条件合并；
                    // 若三项都没有变化则整条跳过，不做无谓写入。
                    let monotonic_progress = item.copy_count > local_row.copy_count
                        || item.last_used_at > local_row.last_used_at;
                    if !metadata_wins && !deletion_changed && !favorite_wins && !monotonic_progress && !tags_win {
                        continue;
                    }

                    let (existing_meta, existing_payload_path): (Option<String>, Option<String>) = tx
                        .query_row(
                            "SELECT cp.metadata_json, ci.payload_path FROM clip_items ci LEFT JOIN clip_payloads cp ON ci.id = cp.id WHERE ci.id = ?1",
                            params![&matched_id],
                            |r| Ok((r.get(0)?, r.get(1)?)),
                        )
                        .optional()?
                        .unwrap_or((None, None));
                    let normalized_asset_path = PayloadAssetStore::normalize_for_storage(
                        &item.item_type,
                        asset_paths.get(&item.id).or_else(|| asset_paths.get(&matched_id)).map(|s| s.as_str()),
                        assets_dir.as_deref(),
                    );
                    let merged_payload_path = normalized_asset_path
                        .clone()
                        .or(existing_payload_path);
                    let (kind_str, resolved_meta) = compute_kind_and_metadata(
                        &item.item_type,
                        item.is_sensitive,
                        existing_meta.as_deref(),
                        item.raw_text.as_deref().unwrap_or(&item.summary),
                        merged_payload_path.as_deref(),
                    );
                    if metadata_wins && resolved_meta != existing_meta {
                        tx.execute(
                            "UPDATE clip_payloads SET metadata_json = ?1 WHERE id = ?2",
                            params![resolved_meta.as_deref(), &matched_id],
                        )?;
                    }
                    // 逐字段裁决：只有胜出的字段被覆盖，其余保留本地值。
                    // CASE 条件用 0/1 参数传入，SQL 保持单次往返。
                    tx.execute(
                        r#"
                        UPDATE clip_items
                        SET title = CASE WHEN ?1 = 1 THEN ?2 ELSE title END,
                            summary = CASE WHEN ?1 = 1 THEN ?3 ELSE summary END,
                            last_used_at = MAX(last_used_at, ?4),
                            copy_count = MAX(?5, copy_count),
                            favorite = CASE WHEN ?6 = 1 THEN ?7 ELSE favorite END,
                            favorite_updated_at = CASE WHEN ?6 = 1 THEN ?8 ELSE favorite_updated_at END,
                            deleted_at = ?9,
                            updated_at = CASE WHEN ?1 = 1 THEN ?10 ELSE updated_at END,
                            payload_path = CASE WHEN ?1 = 1 THEN COALESCE(?11, payload_path) ELSE payload_path END,
                            kind = CASE WHEN ?1 = 1 THEN ?12 ELSE kind END,
                            source_app_bundle_id = CASE WHEN ?1 = 1 THEN COALESCE(?13, source_app_bundle_id) ELSE source_app_bundle_id END,
                            source_app_name = CASE WHEN ?1 = 1 THEN COALESCE(?14, source_app_name) ELSE source_app_name END,
                            source_device_id = CASE WHEN ?1 = 1 THEN COALESCE(?15, source_device_id) ELSE source_device_id END,
                            source_device_name = CASE WHEN ?1 = 1 THEN COALESCE(?16, source_device_name) ELSE source_device_name END,
                            source_platform = CASE WHEN ?1 = 1 THEN COALESCE(?17, source_platform) ELSE source_platform END
                        WHERE id = ?18
                        "#,
                        params![
                            if metadata_wins { 1 } else { 0 },
                            &item.title,
                            &item.summary,
                            item.last_used_at,
                            item.copy_count,
                            if favorite_wins { 1 } else { 0 },
                            if item.is_favorite { 1 } else { 0 },
                            remote_fav_time,
                            resolved_deleted,
                            item.updated_at,
                            normalized_asset_path.as_deref(),
                            kind_str,
                            &item.source_app_bundle_id,
                            &item.source_app_name,
                            &item.source_device_id,
                            &item.source_device_name,
                            &item.source_platform,
                            &matched_id,
                        ],
                    )?;
                    // 按最终状态重算 FTS 行（活跃则重建、已删除则移除）
                    Self::rebuild_fts_row_in_tx(&tx, &matched_id)?;
                    // 标签胜出：全量替换 clip_tags、更新 tags_updated_at，并刷新 FTS tags 列
                    //（必须在 rebuild 之后写入，否则重建会覆盖 tags 列）
                    if tags_win {
                        Self::sync_write_tags_in_tx(&tx, &matched_id, &item.tags, item.tags_updated_at)?;
                    }
                    if metadata_wins {
                        if let Some(text) = &item.raw_text {
                            if item.is_sensitive {
                                let (enc, nonce) = self.crypto.encrypt(text)?;
                                tx.execute(
                                    "UPDATE clip_payloads SET raw_text = NULL, encrypted_content = ?1, nonce = ?2 WHERE id = ?3",
                                    params![&enc, &nonce, &matched_id],
                                )?;
                            } else {
                                tx.execute(
                                    "UPDATE clip_payloads SET raw_text = ?1, encrypted_content = NULL, nonce = NULL WHERE id = ?2",
                                    params![text, &matched_id],
                                )?;
                            }
                        }
                    }
                    merged_count += 1;
                }
                None => {
                    // 墓碑检查：本地已硬删除的条目不因陈旧 pack 复活。
                    // LWW：仅当远端时间晚于墓碑删除时间才允许重新插入（更新者胜）。
                    let remote_time = item.deleted_at.unwrap_or(item.updated_at);
                    let tombstone: Option<f64> = tx
                        .query_row(
                            "SELECT deleted_at FROM sync_tombstones WHERE id = ?1",
                            params![&item.id],
                            |row| row.get(0),
                        )
                        .optional()?;
                    if tombstone.is_some_and(|t| t >= remote_time) {
                        continue;
                    }
                    // 纯墓碑记录（硬删除条目）：item_type/title/summary 均为空。
                    // 旧实现会把它当成新条目插入，在对端回收站留下一条空字段幽灵行。
                    if item.item_type.is_empty() && item.deleted_at.is_some() {
                        tx.execute(
                            "INSERT OR REPLACE INTO sync_tombstones (id, deleted_at) VALUES (?1, ?2)",
                            params![&item.id, remote_time],
                        )?;
                        merged_count += 1;
                        continue;
                    }
                    // New record
                    let new_payload_path = PayloadAssetStore::normalize_for_storage(
                        &item.item_type,
                        asset_paths.get(&item.id).map(|s| s.as_str()),
                        assets_dir.as_deref(),
                    );
                    let (kind_str, resolved_meta) = compute_kind_and_metadata(
                        &item.item_type,
                        item.is_sensitive,
                        None,
                        item.raw_text.as_deref().unwrap_or(&item.summary),
                        new_payload_path.as_deref(),
                    );
                    tx.execute(
                        r#"
                        INSERT INTO clip_items (
                            id, item_type, title, summary, created_at, last_used_at,
                            copy_count, favorite, source_app_bundle_id, source_app_name,
                            is_sensitive, deleted_at, updated_at, payload_path, kind,
                            source_device_id, source_device_name, source_platform, favorite_updated_at
                        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19)
                        "#,
                        params![
                            &item.id,
                            &item.item_type,
                            &item.title,
                            &item.summary,
                            item.created_at,
                            item.last_used_at,
                            item.copy_count.max(1),
                            if item.is_favorite { 1 } else { 0 },
                            &item.source_app_bundle_id,
                            &item.source_app_name,
                            if item.is_sensitive { 1 } else { 0 },
                            item.deleted_at,
                            item.updated_at,
                            new_payload_path.as_deref(),
                            kind_str,
                            &item.source_device_id,
                            &item.source_device_name,
                            &item.source_platform,
                            item.favorite_updated_at,
                        ],
                    )?;
                    if item.is_sensitive {
                        let (enc, nonce) = if let Some(text) = &item.raw_text {
                            let (e, n) = self.crypto.encrypt(text)?;
                            (Some(e), Some(n))
                        } else {
                            (None, None)
                        };
                        tx.execute(
                            "INSERT INTO clip_payloads (id, raw_text, encrypted_content, nonce, metadata_json) VALUES (?1, NULL, ?2, ?3, ?4)",
                            params![&item.id, &enc, &nonce, resolved_meta.as_deref()],
                        )?;
                    } else {
                        tx.execute(
                            "INSERT INTO clip_payloads (id, raw_text, metadata_json) VALUES (?1, ?2, ?3)",
                            params![&item.id, &item.raw_text, resolved_meta.as_deref()],
                        )?;
                    }
                    if item.deleted_at.is_none() {
                        Self::rebuild_fts_row_in_tx(&tx, &item.id)?;
                        // 新条目：直接落地远端标签（rebuild 之后写 FTS tags 列）
                        if !item.tags.is_empty() {
                            Self::sync_write_tags_in_tx(&tx, &item.id, &item.tags, item.tags_updated_at)?;
                        }
                    }
                    merged_count += 1;
                }
            }
        }

        tx.commit()?;
        Ok(merged_count)
    }

    pub fn export_backup_items(
        &self,
        mode: crate::exchange::SensitiveExportMode,
    ) -> Result<Vec<crate::exchange::export::BackupExportItem>> {
        let conn = self.conn.lock();
        // 排除敏感数据时在 SQL 层过滤：避免先 LEFT JOIN 拉出大体积密文/nonce
        // 再在 Rust 侧丢弃（万级历史 + 大载荷时白读几百 MB）。
        let exclude_sensitive = matches!(mode, crate::exchange::SensitiveExportMode::Exclude);
        let sensitive_clause = if exclude_sensitive {
            " AND ci.is_sensitive = 0"
        } else {
            ""
        };
        let sql = format!(
            r#"
            SELECT ci.id, ci.item_type, ci.title, ci.summary, cp.raw_text,
                   cp.encrypted_content, cp.nonce, ci.is_sensitive, ci.favorite,
                   ci.created_at, ci.last_used_at, ci.copy_count
            FROM clip_items ci
            LEFT JOIN clip_payloads cp ON ci.id = cp.id
            WHERE ci.deleted_at IS NULL{sensitive_clause}
            ORDER BY ci.last_used_at DESC
            "#
        );
        let mut stmt = conn.prepare(&sql)?;

        let rows = stmt.query_map([], |row| {
            let id: String = row.get(0)?;
            let item_type: String = row.get(1)?;
            let title: String = row.get(2)?;
            let summary: String = row.get(3)?;
            let raw_text: Option<String> = row.get(4)?;
            let encrypted: Option<Vec<u8>> = row.get(5)?;
            let nonce: Option<Vec<u8>> = row.get(6)?;
            let is_sensitive: bool = row.get::<_, i64>(7)? == 1;
            let favorite: bool = row.get::<_, i64>(8)? == 1;
            let created_at: f64 = row.get(9)?;
            let last_used_at: f64 = row.get(10)?;
            let copy_count: i64 = row.get(11)?;

            Ok((
                id,
                item_type,
                title,
                summary,
                raw_text,
                encrypted,
                nonce,
                is_sensitive,
                favorite,
                created_at,
                last_used_at,
                copy_count,
            ))
        })?;

        let mut results = Vec::new();
        for row in rows {
            let (
                id,
                item_type,
                title,
                summary,
                raw_text,
                encrypted,
                nonce,
                is_sensitive,
                is_favorite,
                created_at,
                last_used_at,
                copy_count,
            ) = row?;

            if is_sensitive && mode == crate::exchange::SensitiveExportMode::Exclude {
                continue;
            }

            let (final_summary, final_raw) = if is_sensitive {
                match mode {
                    crate::exchange::SensitiveExportMode::Exclude => continue,
                    crate::exchange::SensitiveExportMode::Masked => {
                        ("••••••••".to_string(), Some("••••••••".to_string()))
                    }
                    crate::exchange::SensitiveExportMode::Plaintext => {
                        // 解密失败必须报错：静默跳过会让用户误以为备份完整
                        let text = if let (Some(enc), Some(n)) = (encrypted, nonce) {
                            Some(self.crypto.decrypt(&enc, &n)?)
                        } else {
                            raw_text
                        };
                        (summary, text)
                    }
                }
            } else {
                (summary, raw_text)
            };

            results.push(crate::exchange::export::BackupExportItem {
                id,
                item_type,
                title,
                summary: final_summary,
                raw_text: final_raw,
                is_sensitive,
                is_favorite,
                created_at,
                last_used_at,
                copy_count,
                // 标签批量回填（避免 N+1）
                tags: Vec::new(),
            });
        }

        // 批量回填 tags（升序）
        if !results.is_empty() {
            let mut tag_map: HashMap<String, Vec<String>> = HashMap::new();
            let mut stmt = conn.prepare(
                "SELECT clip_id, tag FROM clip_tags ORDER BY clip_id, created_at ASC, tag ASC",
            )?;
            let rows = stmt.query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?;
            for row in rows {
                let (clip_id, tag) = row?;
                tag_map.entry(clip_id).or_default().push(tag);
            }
            for item in &mut results {
                if let Some(tags) = tag_map.remove(&item.id) {
                    item.tags = tags;
                }
            }
        }

        Ok(results)
    }

    pub fn import_backup_items(
        &self,
        items: &[crate::exchange::export::BackupExportItem],
    ) -> Result<crate::exchange::ImportReport> {
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        let mut report = crate::exchange::ImportReport::default();

        for item in items {
            // Masked 导出的敏感条目正文是掩码字面量，导入只会建立以掩码为正文的
            // 假敏感条目，跳过并计数
            if item.is_sensitive && item.raw_text.as_deref() == Some("••••••••") {
                report.skipped_masked += 1;
                continue;
            }
            // Check deduplication by id or active summary
            // Check deduplication: sensitive items only deduplicate on identical ID to prevent
            // mask collision (e.g. '********'), non-sensitive items deduplicate on id or matching active summary.
            let exists: bool = if item.is_sensitive {
                tx.query_row(
                    "SELECT 1 FROM clip_items WHERE id = ?1",
                    params![&item.id],
                    |_| Ok(true),
                )
                .optional()?
                .unwrap_or(false)
            } else {
                tx.query_row(
                    "SELECT 1 FROM clip_items WHERE id = ?1 OR (item_type = ?2 AND summary = ?3 AND deleted_at IS NULL AND is_sensitive = 0)",
                    params![&item.id, &item.item_type, &item.summary],
                    |_| Ok(true),
                )
                .optional()?
                .unwrap_or(false)
            };

            if exists {
                report.skipped_duplicates += 1;
                continue;
            }

            let (stored_raw, encrypted_content, nonce) = if item.is_sensitive {
                if let Some(text) = &item.raw_text {
                    let (enc, n) = self.crypto.encrypt(text)?;
                    (None, Some(enc), Some(n.to_vec()))
                } else {
                    (None, None, None)
                }
            } else {
                (item.raw_text.clone(), None, None)
            };

            let (kind_str, resolved_meta) = compute_kind_and_metadata(
                &item.item_type,
                item.is_sensitive,
                None,
                item.raw_text.as_deref().unwrap_or(&item.summary),
                None,
            );

            tx.execute(
                r#"
                INSERT INTO clip_items (
                    id, item_type, title, summary, created_at, last_used_at,
                    copy_count, favorite, source_app_bundle_id, source_app_name,
                    is_sensitive, deleted_at, updated_at, kind, favorite_updated_at
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, NULL, NULL, ?9, NULL, ?10, ?11, ?12)
                "#,
                params![
                    &item.id,
                    &item.item_type,
                    &item.title,
                    &item.summary,
                    item.created_at,
                    item.last_used_at,
                    item.copy_count,
                    if item.is_favorite { 1 } else { 0 },
                    if item.is_sensitive { 1 } else { 0 },
                    // 备份格式不携带 updated_at；写导入时刻，防止首轮同步被旧远端记录覆盖
                    Self::unix_now(),
                    kind_str,
                    // 收藏状态随导入一起落地：给它独立的判新时间，避免首轮同步被对端旧值覆盖
                    if item.is_favorite { Self::unix_now() } else { 0.0 },
                ],
            )?;

            tx.execute(
                r#"
                INSERT INTO clip_payloads (
                    id, raw_text, encrypted_content, nonce, metadata_json
                ) VALUES (?1, ?2, ?3, ?4, ?5)
                "#,
                params![&item.id, &stored_raw, &encrypted_content, &nonce, resolved_meta.as_deref()],
            )?;

            let fts_summary = if item.is_sensitive { "" } else { item.summary.as_str() };
            tx.execute(
                r#"
                INSERT INTO clip_fts (
                    rowid, title, summary, ocr_text, source_app_name, source_app_bundle_id, clip_id
                ) VALUES ((SELECT rowid FROM clip_items WHERE id = ?3), ?1, ?2, '', '', '', ?3)
                "#,
                params![&item.title, fts_summary, &item.id],
            )?;
            // 导入标签：规范化（trim/#/空白折叠/截断24）、大小写不敏感判重、上限 10，
            // 然后写入 clip_tags 并推进 tags_updated_at + 刷新 FTS tags 列。
            if !item.tags.is_empty() {
                let mut normalized: Vec<String> = Vec::new();
                let mut seen_lower: std::collections::HashSet<String> = std::collections::HashSet::new();
                for raw in &item.tags {
                    if normalized.len() >= 10 {
                        break;
                    }
                    if let Some(tag) = Self::normalize_tag(raw) {
                        if seen_lower.insert(tag.to_lowercase()) {
                            normalized.push(tag);
                        }
                    }
                }
                if !normalized.is_empty() {
                    Self::sync_write_tags_in_tx(&tx, &item.id, &normalized, Self::unix_now())?;
                }
            }
            report.imported_count += 1;
        }

        tx.commit()?;
        Ok(report)
    }
}
