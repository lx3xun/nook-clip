use parking_lot::Mutex;
use rusqlite::{params, Connection, OptionalExtension};
use std::sync::Arc;

use crate::{
    crypto::CryptoEngine,
    error::{CoreError, Result},
    model::{ClipItemDetail, ClipItemSummary, PrunedItemRecord, QueryFilter, RetentionConfig},
    storage::schema::initialize_database,
};

pub struct StorageRepository {
    conn: Arc<Mutex<Connection>>,
    crypto: CryptoEngine,
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
    pub fn new(db_path: &str, master_key: &[u8]) -> Result<Self> {
        let conn = Connection::open(db_path)?;
        initialize_database(&conn)?;
        let crypto = CryptoEngine::new(master_key)?;
        Ok(Self {
            conn: Arc::new(Mutex::new(conn)),
            crypto,
        })
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
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        let saved = Self::save_item_in_tx(&tx, &self.crypto, item, raw_text)?;
        tx.commit()?;
        Ok(saved)
    }

    /// 批量写入：全部条目共用一个事务（导入/初始化/迁移等批量场景），
    /// 任一条目失败整体回滚；逐条语义与 save_item 完全一致（内容去重、FTS 维护）。
    pub fn save_items_batch(
        &self,
        entries: &[(ClipItemSummary, Option<String>)],
    ) -> Result<Vec<ClipItemSummary>> {
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        let mut saved = Vec::with_capacity(entries.len());
        for (item, raw_text) in entries {
            saved.push(Self::save_item_in_tx(
                &tx,
                &self.crypto,
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
        let conn = self.conn.lock();
        let mut stmt = conn
            .prepare("SELECT payload_path FROM clip_items WHERE payload_path IS NOT NULL AND payload_path != ''")?;
        let rows = stmt.query_map([], |row| row.get::<_, String>(0))?;
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
        item: &ClipItemSummary,
        raw_text: Option<&str>,
    ) -> Result<ClipItemSummary> {

        // 1. Check if item already exists by exact ID OR by identical active content (content deduplication)
        let existing: Option<(String, i64, bool, f64)> = tx
            .query_row(
                "SELECT id, copy_count, favorite, created_at FROM clip_items WHERE id = ?1",
                params![&item.id],
                |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get::<_, i64>(2)? == 1,
                        row.get(3)?,
                    ))
                },
            )
            .optional()?;
        // 内容去重：敏感条目不能按 summary 去重（相同掩码 != 相同明文）
        let existing = match existing {
            Some(v) => Some(v),
            None if !item.is_sensitive => tx
                .query_row(
                    "SELECT id, copy_count, favorite, created_at FROM clip_items 
                     WHERE item_type = ?1 AND summary = ?2 AND deleted_at IS NULL 
                     ORDER BY last_used_at DESC LIMIT 1",
                    params![&item.item_type, &item.summary],
                    |row| {
                        Ok((
                            row.get(0)?,
                            row.get(1)?,
                            row.get::<_, i64>(2)? == 1,
                            row.get(3)?,
                        ))
                    },
                )
                .optional()?,
            None => None,
        };

        let (target_id, copy_count, favorite, created_at) = match existing {
            Some((prev_id, prev_count, prev_fav, prev_created)) => (
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

        let (kind_str, resolved_metadata_json) = compute_kind_and_metadata(
            &item.item_type,
            item.is_sensitive,
            item.metadata_json.as_deref(),
            raw_text.unwrap_or(&item.summary),
            item.payload_path.as_deref(),
        );

        // 3. Upsert clip_items
        tx.execute(
            r#"
            INSERT INTO clip_items (
                id, item_type, title, summary, created_at, last_used_at,
                copy_count, favorite, source_app_bundle_id, source_app_name,
                is_sensitive, deleted_at, payload_path, updated_at, kind
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
            ON CONFLICT(id) DO UPDATE SET
                last_used_at = excluded.last_used_at,
                copy_count = excluded.copy_count,
                favorite = excluded.favorite,
                deleted_at = NULL,
                payload_path = COALESCE(excluded.payload_path, clip_items.payload_path),
                updated_at = excluded.updated_at,
                kind = excluded.kind
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
                &item.payload_path,
                Self::unix_now(),
                kind_str,
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
        let persisted: ClipItemSummary = tx.query_row(
            r#"
            SELECT ci.id, ci.item_type, ci.title, ci.summary, ci.created_at, ci.last_used_at,
                   ci.copy_count, ci.favorite, ci.source_app_bundle_id, ci.source_app_name,
                   ci.is_sensitive, ci.deleted_at, ci.payload_path, cp.ocr_text, cp.metadata_json, ci.kind
            FROM clip_items ci
            LEFT JOIN clip_payloads cp ON ci.id = cp.id
            WHERE ci.id = ?1
            "#,
            params![&target_id],
            |row| {
                Ok(ClipItemSummary {
                    id: row.get(0)?,
                    item_type: row.get(1)?,
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
                    payload_path: row.get::<_, Option<String>>(12)?,
                    ocr_text: row.get(13)?,
                    metadata_json: row.get(14)?,
                    kind: row.get(15)?,
                })
            },
        )?;

        // 6. Update clip_fts:
        // FTS5 按 rowid 定位：clip_id 是 UNINDEXED 列，按其删除/更新需全表扫描（O(N)，
        // 批量场景退化为 O(N²)）。不变量：clip_fts.rowid == clip_items.rowid。
        // 敏感条目收录 title 供别名检索，正文/OCR/来源全部留空以防明文泄密。
        tx.execute(
            "DELETE FROM clip_fts WHERE rowid = (SELECT rowid FROM clip_items WHERE id = ?1)",
            params![&target_id],
        )?;
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
        tx.execute(
            r#"
            INSERT INTO clip_fts (
                rowid, title, summary, ocr_text, source_app_name, source_app_bundle_id, clip_id
            ) VALUES ((SELECT rowid FROM clip_items WHERE id = ?6), ?1, ?2, ?3, ?4, ?5, ?6)
            "#,
            params![
                &persisted.title,
                fts_summary,
                fts_ocr,
                fts_app_name,
                fts_bundle_id,
                &target_id,
            ],
        )?;

        Ok(persisted)
    }

    /// 构造通用的 FTS 与 WHERE 条件片段（query_items 与 count_categories 共享）
    fn build_search_conditions(
        include_deleted: bool,
        favorite_only: bool,
        item_type: Option<&str>,
        search_query: Option<&str>,
        id: Option<&str>,
    ) -> (String, Vec<String>, Vec<Box<dyn rusqlite::ToSql>>) {
        let mut conditions = Vec::new();
        let mut params: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();

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

        let mut fts_join = String::new();
        if let Some(q) = search_query {
            let clean_q = q.trim();
            if !clean_q.is_empty() {
                let tokens = crate::search::tokenize_search_query(clean_q);
                let (long_tokens, short_tokens): (Vec<String>, Vec<String>) =
                    tokens.into_iter().partition(|t| t.chars().count() >= 3);

                if !long_tokens.is_empty() {
                    let fts_expr = long_tokens
                        .iter()
                        .map(|t| format!("\"{}\"", t.replace('"', "\"\"")))
                        .collect::<Vec<_>>()
                        .join(" ");
                    params.push(Box::new(fts_expr));
                    let fts_param_idx = params.len();
                    fts_join = format!(
                        "INNER JOIN (SELECT clip_id FROM clip_fts WHERE clip_fts MATCH ?{fts_param_idx}) fts ON ci.id = fts.clip_id"
                    );
                }

                for st in short_tokens {
                    params.push(Box::new(format!("%{st}%")));
                    let p_idx = params.len();
                    conditions.push(format!(
                        "(ci.title LIKE ?{p_idx} OR ci.summary LIKE ?{p_idx} OR ci.source_app_name LIKE ?{p_idx} OR cp.ocr_text LIKE ?{p_idx})"
                    ));
                }
            }
        }

        (fts_join, conditions, params)
    }
    pub fn query_items(&self, filter: &QueryFilter) -> Result<Vec<ClipItemSummary>> {
        let conn = self.conn.lock();

        let (fts_join, mut conditions, params) = Self::build_search_conditions(
            filter.include_deleted,
            filter.favorite_only,
            filter.item_type.as_deref(),
            filter.search_query.as_deref(),
            filter.id.as_deref(),
        );

        let derived = DerivedKindFilter::new(filter.kind.as_deref());
        derived.push_sql_conditions(&mut conditions);

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
            "CASE WHEN ci.is_sensitive = 0 AND cp.raw_text IS NOT NULL AND cp.raw_text != '' THEN cp.raw_text ELSE ci.summary END"
        } else {
            "ci.summary"
        };

        let sql = format!(
            r#"
            SELECT ci.id, ci.item_type, ci.title, {summary_expr}, ci.created_at, ci.last_used_at,
                   ci.copy_count, ci.favorite, ci.source_app_bundle_id, ci.source_app_name,
                   ci.is_sensitive, ci.deleted_at, ci.payload_path, cp.ocr_text, cp.metadata_json, ci.kind
            FROM clip_items ci
            LEFT JOIN clip_payloads cp ON ci.id = cp.id
            {fts_join}
            {where_clause}
            ORDER BY ci.last_used_at DESC, ci.id DESC
            {limit_clause}
            "#
        );

        let mut stmt = conn.prepare(&sql)?;
        let param_refs: Vec<&dyn rusqlite::ToSql> = params.iter().map(|p| p.as_ref()).collect();

        let rows = stmt.query_map(param_refs.as_slice(), |row| {
            Ok(ClipItemSummary {
                id: row.get(0)?,
                item_type: row.get(1)?,
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
                payload_path: row.get::<_, Option<String>>(12)?,
                ocr_text: row.get(13)?,
                metadata_json: row.get(14)?,
                kind: row.get(15)?,
            })
        })?;

        let mut results = Vec::new();
        for r in rows {
            results.push(r?);
        }
        Ok(results)
    }

    /// 全历史分类统计：基于持久化 ci.kind 列在 SQLite 内直接聚合，无需全表拉取 summary/metadata
    pub fn count_categories(&self, search_query: Option<&str>) -> Result<crate::model::CategoryCounts> {
        let conn = self.conn.lock();

        let (fts_join, conditions, params) =
            Self::build_search_conditions(false, false, None, search_query, None);

        let where_clause = if conditions.is_empty() {
            String::new()
        } else {
            format!("WHERE {}", conditions.join(" AND "))
        };

        let need_payload_join = conditions.iter().any(|c| c.contains("cp."));
        let payload_join = if need_payload_join {
            "LEFT JOIN clip_payloads cp ON ci.id = cp.id"
        } else {
            ""
        };

        let sql = format!(
            r#"
            SELECT
                COUNT(*),
                COALESCE(SUM(CASE WHEN ci.favorite = 1 THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN ci.kind = 'text' THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN ci.kind = 'image' THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN ci.kind = 'file' THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN ci.kind = 'url' THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN ci.kind IN ('code', 'json') THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN ci.kind = 'color' THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN ci.kind = 'sensitive' THEN 1 ELSE 0 END), 0)
            FROM clip_items ci
            {payload_join}
            {fts_join}
            {where_clause}
            "#
        );

        let param_refs: Vec<&dyn rusqlite::ToSql> = params.iter().map(|p| p.as_ref()).collect();
        let counts = conn.query_row(&sql, param_refs.as_slice(), |row| {
            Ok(crate::model::CategoryCounts {
                total: row.get::<_, i64>(0)? as u64,
                favorite: row.get::<_, i64>(1)? as u64,
                text: row.get::<_, i64>(2)? as u64,
                image: row.get::<_, i64>(3)? as u64,
                file: row.get::<_, i64>(4)? as u64,
                url: row.get::<_, i64>(5)? as u64,
                code: row.get::<_, i64>(6)? as u64,
                color: row.get::<_, i64>(7)? as u64,
                sensitive: row.get::<_, i64>(8)? as u64,
            })
        })?;

        Ok(counts)
    }

    /// 全量时间戳聚合：返回当前筛选（关键词/分类/派生 kind）下全部命中条目的
    /// last_used_at（降序），供时间导航锚点条做全历史时间分组。
    /// 与分页列表无关——pageSize 截断不再导致锚点条缺失更早的分组。
    pub fn time_group_timestamps(&self, filter: &QueryFilter) -> Result<Vec<f64>> {
        let conn = self.conn.lock();

        let (fts_join, mut conditions, params) = Self::build_search_conditions(
            filter.include_deleted,
            filter.favorite_only,
            filter.item_type.as_deref(),
            filter.search_query.as_deref(),
            filter.id.as_deref(),
        );

        let derived = DerivedKindFilter::new(filter.kind.as_deref());
        derived.push_sql_conditions(&mut conditions);

        let where_clause = if conditions.is_empty() {
            String::new()
        } else {
            format!("WHERE {}", conditions.join(" AND "))
        };

        let need_payload_join = conditions.iter().any(|c| c.contains("cp."));
        let payload_join = if need_payload_join {
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

    pub fn get_item_detail(&self, id: &str) -> Result<ClipItemDetail> {
        let conn = self.conn.lock();

        let row = conn
            .query_row(
                r#"
                SELECT cp.raw_text, cp.encrypted_content, cp.nonce, cp.ocr_text, cp.metadata_json, ci.is_sensitive
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
                    ))
                },
            )
            .optional()?;

        let (raw_text, enc, nonce, ocr_text, metadata_json, is_sensitive) = match row {
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

        Ok(ClipItemDetail {
            id: id.to_string(),
            raw_text: final_text,
            ocr_text,
            metadata_json,
            is_sensitive,
        })
    }

    /// 轻量标记使用（粘贴/再次使用）：仅递增 copy_count 并刷新 last_used_at / updated_at，
    /// 不触碰 clip_payloads（密文/全文）与 clip_fts，彻底杜绝掩码或截断摘要覆盖原文。
    pub fn mark_used(&self, id: &str, used_at: f64) -> Result<ClipItemSummary> {
        let conn = self.conn.lock();
        let now = Self::unix_now();
        let changed = conn.execute(
            r#"
            UPDATE clip_items
            SET last_used_at = ?1,
                copy_count = copy_count + 1,
                updated_at = ?2
            WHERE id = ?3
            "#,
            params![used_at, now, id],
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
        conn.execute(
            "UPDATE clip_items SET favorite = CASE WHEN favorite = 1 THEN 0 ELSE 1 END, updated_at = ?1 WHERE id = ?2",
            params![now, id],
        )?;

        drop(conn);
        self.get_item_summary(id)
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

            tx.execute(
                r#"
                INSERT INTO clip_payloads (id, raw_text, encrypted_content, nonce)
                VALUES (?3, NULL, ?1, ?2)
                ON CONFLICT(id) DO UPDATE SET
                    raw_text = NULL,
                    encrypted_content = excluded.encrypted_content,
                    nonce = excluded.nonce
                "#,
                params![&enc, &n.to_vec(), id],
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

            tx.execute(
                "DELETE FROM clip_fts WHERE rowid = (SELECT rowid FROM clip_items WHERE id = ?1)",
                params![id],
            )?;
            tx.execute(
                r#"
                INSERT INTO clip_fts (
                    rowid, title, summary, ocr_text, source_app_name, source_app_bundle_id, clip_id
                ) VALUES ((SELECT rowid FROM clip_items WHERE id = ?6), ?1, ?2, ?3, ?4, ?5, ?6)
                "#,
                params![
                    &title,
                    &new_summary,
                    ocr_text.as_deref().unwrap_or(""),
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

    pub fn restore_deleted(&self, id: &str) -> Result<()> {
        let conn = self.conn.lock();
        let now = Self::unix_now();
        conn.execute(
            "UPDATE clip_items SET deleted_at = NULL, updated_at = ?1 WHERE id = ?2",
            params![now, id],
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
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        let now = Self::unix_now();
        let records = {
            let mut stmt = if keep_favorites {
                tx.prepare("SELECT id, payload_path FROM clip_items WHERE favorite = 0")?
            } else {
                tx.prepare("SELECT id, payload_path FROM clip_items")?
            };

            let rows = stmt.query_map([], |row| {
                Ok(PrunedItemRecord {
                    id: row.get(0)?,
                    payload_path: row.get::<_, Option<String>>(1)?,
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

    pub fn update_ocr_text(&self, id: &str, ocr_text: &str) -> Result<()> {
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;

        tx.execute(
            "UPDATE clip_payloads SET ocr_text = ?1 WHERE id = ?2",
            params![ocr_text, id],
        )?;
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
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;

        let mut candidate_ids: Vec<String> = Vec::new();

        // 1. Prune by max age
        if let Some(days) = config.max_age_days {
            if days > 0 {
                let cutoff = Self::unix_now() - (days as f64 * 86400.0);
                // 只清活跃条目：软删除条目在撤销宽限窗口内，由回收站路径处理
                let mut stmt = tx.prepare(
                    "SELECT id FROM clip_items WHERE favorite = 0 AND deleted_at IS NULL AND last_used_at < ?1",
                )?;
                let rows = stmt.query_map(params![cutoff], |r| r.get(0))?;
                for r in rows {
                    candidate_ids.push(r?);
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
                        "SELECT id FROM clip_items WHERE favorite = 0 AND deleted_at IS NULL ORDER BY last_used_at ASC LIMIT ?1",
                    )?;
                    let rows = stmt.query_map(params![excess], |r| r.get(0))?;
                    for r in rows {
                        candidate_ids.push(r?);
                    }
                }
            }
        }

        // 顺手清理超期云端墓碑（7 天后不再随 pack 广播）
        tx.execute(
            "DELETE FROM sync_tombstones WHERE deleted_at < ?1",
            params![Self::unix_now() - crate::sync::TOMBSTONE_RETENTION_SECS],
        )?;

        if candidate_ids.is_empty() {
            tx.commit()?;
            return Ok(Vec::new());
        }

        candidate_ids.sort();
        candidate_ids.dedup();

        let mut records = Vec::new();
        for id in &candidate_ids {
            let (rowid, payload_path): (i64, Option<String>) = tx
                .query_row(
                    "SELECT rowid, payload_path FROM clip_items WHERE id = ?1",
                    params![id],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .unwrap_or((-1, None));
            records.push(PrunedItemRecord {
                id: id.clone(),
                payload_path,
            });
            Self::record_tombstone_in_tx(&tx, id)?;
            if rowid >= 0 {
                tx.execute("DELETE FROM clip_fts WHERE rowid = ?1", params![rowid])?;
            }
            tx.execute("DELETE FROM clip_payloads WHERE id = ?1", params![id])?;
            tx.execute("DELETE FROM clip_items WHERE id = ?1", params![id])?;
        }

        tx.commit()?;
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
        let candidates: Vec<(String, String, bool, bool, f64)> = {
            let conn = self.conn.lock();
            let mut stmt = conn.prepare(
                r#"
                SELECT id, payload_path, favorite, deleted_at IS NOT NULL, last_used_at
                FROM clip_items
                WHERE payload_path IS NOT NULL AND payload_path != ''
                ORDER BY last_used_at ASC
                "#,
            )?;
            let rows = stmt.query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)? == 1,
                    row.get::<_, bool>(3)?,
                    row.get::<_, f64>(4)?,
                ))
            })?;
            rows.collect::<std::result::Result<Vec<_>, _>>()?
        };

        let mut total_bytes: u64 = 0;
        let mut evictable: Vec<(String, String, u64, f64)> = Vec::new();

        for (id, path_str, is_favorite, is_deleted, last_used_at) in candidates {
            let path = std::path::Path::new(&path_str);
            if !path.starts_with(root) {
                continue;
            }
            let size = std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);
            total_bytes = total_bytes.saturating_add(size);
            if is_deleted || !is_favorite {
                evictable.push((id, path_str, size, last_used_at));
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
        for (id, path_str) in to_evict {
            Self::record_tombstone_in_tx(&tx, &id)?;
            tx.execute(
                "DELETE FROM clip_fts WHERE rowid = (SELECT rowid FROM clip_items WHERE id = ?1)",
                params![&id],
            )?;
            tx.execute("DELETE FROM clip_payloads WHERE id = ?1", params![&id])?;
            tx.execute("DELETE FROM clip_items WHERE id = ?1", params![&id])?;
            records.push(PrunedItemRecord {
                id,
                payload_path: Some(path_str),
            });
        }
        tx.commit()?;
        Ok(records)
    }

    fn get_item_summary(&self, id: &str) -> Result<ClipItemSummary> {
        let conn = self.conn.lock();
        conn.query_row(
            r#"
            SELECT ci.id, ci.item_type, ci.title, ci.summary, ci.created_at, ci.last_used_at,
                   ci.copy_count, ci.favorite, ci.source_app_bundle_id, ci.source_app_name,
                   ci.is_sensitive, ci.deleted_at, ci.payload_path, cp.ocr_text, cp.metadata_json, ci.kind
            FROM clip_items ci
            LEFT JOIN clip_payloads cp ON ci.id = cp.id
            WHERE ci.id = ?1
            "#,
            params![id],
            |row| {
                Ok(ClipItemSummary {
                    id: row.get(0)?,
                    item_type: row.get(1)?,
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
                    payload_path: row.get::<_, Option<String>>(12)?,
                    ocr_text: row.get(13)?,
                    metadata_json: row.get(14)?,
                    kind: row.get(15)?,
                })
            },
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
    pub fn export_sync_items(
        &self,
        assets_dir: Option<&str>,
    ) -> Result<Vec<crate::sync::SyncItemRecord>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            r#"
            SELECT ci.id, ci.item_type, ci.title, ci.summary, cp.raw_text,
                   ci.is_sensitive, ci.favorite, ci.created_at, ci.last_used_at, ci.deleted_at,
                   ci.updated_at, ci.copy_count, ci.payload_path
            FROM clip_items ci
            LEFT JOIN clip_payloads cp ON ci.id = cp.id
            WHERE ci.is_sensitive = 0
              AND (ci.deleted_at IS NULL OR ci.deleted_at >= ?1)
            ORDER BY ci.last_used_at DESC
            "#
        )?;

        // 墓碑保留 7 天：超期墓碑不再随 pack 推送（spec US1，T010）
        let tombstone_cutoff = Self::unix_now() - crate::sync::TOMBSTONE_RETENTION_SECS;
        let rows = stmt.query_map(
            params![tombstone_cutoff],
            |row| {
            let id: String = row.get(0)?;
            let item_type: String = row.get(1)?;
            let title: String = row.get(2)?;
            let summary: String = row.get(3)?;
            let raw_text: Option<String> = row.get(4)?;
            let is_favorite: bool = row.get::<_, i64>(6)? == 1;
            let created_at: f64 = row.get(7)?;
            let last_used_at: f64 = row.get(8)?;
            let deleted_at: Option<f64> = row.get(9)?;
            let updated_at: f64 = row.get(10)?;
            let copy_count: i64 = row.get(11)?;
            let payload_path: Option<String> = row.get(12)?;

            // 附件池：仅受管载荷目录内的文件随 pack 同步（content-addressed 文件名）；
            // 用户原始文件路径（file 类条目）绝不外发
            let asset_file_name = payload_path.as_deref().and_then(|p| {
                let dir = std::path::Path::new(assets_dir?);
                let path = std::path::Path::new(p);
                if path.starts_with(dir) {
                    path.file_name()
                        .and_then(|n| n.to_str())
                        .map(|n| n.to_string())
                } else {
                    None
                }
            });

            Ok(crate::sync::SyncItemRecord {
                id,
                item_type,
                title,
                summary,
                raw_text,
                is_sensitive: false,
                is_favorite,
                created_at,
                last_used_at,
                updated_at,
                copy_count,
                asset_file_name,
                deleted_at,
            })
        })?;

        let mut items = Vec::new();
        for item in rows {
            items.push(item?);
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
                    copy_count: 0,
                    asset_file_name: None,
                    deleted_at: Some(deleted_at),
                })
            })?;
            for row in rows {
                items.push(row?);
            }
        }

        Ok(items)
    }
    pub fn reconcile_sync_items(
        &self,
        items: &[crate::sync::SyncItemRecord],
        asset_paths: &std::collections::HashMap<String, String>,
    ) -> Result<u32> {
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        let mut merged_count = 0;

        for item in items {
            let local: Option<(f64, Option<f64>, i64, bool, f64)> = tx
                .query_row(
                    "SELECT last_used_at, deleted_at, copy_count, favorite, updated_at FROM clip_items WHERE id = ?1",
                    params![&item.id],
                    |row| {
                        Ok((
                            row.get(0)?,
                            row.get(1)?,
                            row.get(2)?,
                            row.get::<_, i64>(3)? == 1,
                            row.get(4)?,
                        ))
                    },
                )
                .optional()?;

            match local {
                Some((_local_last_used, local_deleted, local_copies, _local_fav, local_updated)) => {
                    // LWW（data-model §3）：元数据按 updated_at 判新；删除以 deleted_at 为准。
                    // 存量行 updated_at=0（迁移默认值），首轮远端必胜，合并后自愈。
                    let remote_time = item.deleted_at.unwrap_or(item.updated_at);
                    let local_time = local_deleted.unwrap_or(local_updated);

                    // LWW rule: if remote is newer, update
                    if remote_time > local_time {
                        let (existing_meta, existing_payload_path): (Option<String>, Option<String>) = tx
                            .query_row(
                                "SELECT cp.metadata_json, ci.payload_path FROM clip_items ci LEFT JOIN clip_payloads cp ON ci.id = cp.id WHERE ci.id = ?1",
                                params![&item.id],
                                |r| Ok((r.get(0)?, r.get(1)?)),
                            )
                            .optional()?
                            .unwrap_or((None, None));
                        let merged_payload_path = asset_paths
                            .get(&item.id)
                            .cloned()
                            .or(existing_payload_path);
                        let (kind_str, resolved_meta) = compute_kind_and_metadata(
                            &item.item_type,
                            item.is_sensitive,
                            existing_meta.as_deref(),
                            item.raw_text.as_deref().unwrap_or(&item.summary),
                            merged_payload_path.as_deref(),
                        );
                        if resolved_meta != existing_meta {
                            tx.execute(
                                "UPDATE clip_payloads SET metadata_json = ?1 WHERE id = ?2",
                                params![resolved_meta.as_deref(), &item.id],
                            )?;
                        }
                        tx.execute(
                            r#"
                            UPDATE clip_items
                            SET title = ?1, summary = ?2, last_used_at = ?3,
                                favorite = ?4, deleted_at = ?5,
                                copy_count = MAX(?6, copy_count),
                                updated_at = ?7,
                                payload_path = COALESCE(?8, payload_path),
                                kind = ?9
                            WHERE id = ?10
                            "#,
                            params![
                                &item.title,
                                &item.summary,
                                item.last_used_at,
                                if item.is_favorite { 1 } else { 0 },
                                item.deleted_at,
                                local_copies.max(item.copy_count),
                                item.updated_at,
                                asset_paths.get(&item.id),
                                kind_str,
                                &item.id,
                            ],
                        )?;
                        // 按最终状态重算 FTS 行：非敏感且未删除则重建（保留本机已有 ocr_text 与 source_app）
                        tx.execute(
                            "DELETE FROM clip_fts WHERE rowid = (SELECT rowid FROM clip_items WHERE id = ?1)",
                            params![&item.id],
                        )?;
                        if item.deleted_at.is_none() {
                            let fts_summary = if item.is_sensitive { "" } else { item.summary.as_str() };
                            tx.execute(
                                r#"
                                INSERT INTO clip_fts (
                                    rowid, title, summary, ocr_text, source_app_name, source_app_bundle_id, clip_id
                                )
                                SELECT ci.rowid, ?1, ?2,
                                       CASE WHEN ?4 = 1 THEN '' ELSE COALESCE(cp.ocr_text, '') END,
                                       CASE WHEN ?4 = 1 THEN '' ELSE COALESCE(ci.source_app_name, '') END,
                                       CASE WHEN ?4 = 1 THEN '' ELSE COALESCE(ci.source_app_bundle_id, '') END,
                                       ci.id
                                FROM clip_items ci
                                LEFT JOIN clip_payloads cp ON ci.id = cp.id
                                WHERE ci.id = ?3
                                "#,
                                params![&item.title, fts_summary, &item.id, if item.is_sensitive { 1 } else { 0 }],
                            )?;
                        }
                        if let Some(text) = &item.raw_text {
                            if item.is_sensitive {
                                let (enc, nonce) = self.crypto.encrypt(text)?;
                                tx.execute(
                                    "UPDATE clip_payloads SET raw_text = NULL, encrypted_content = ?1, nonce = ?2 WHERE id = ?3",
                                    params![&enc, &nonce, &item.id],
                                )?;
                            } else {
                                tx.execute(
                                    "UPDATE clip_payloads SET raw_text = ?1, encrypted_content = NULL, nonce = NULL WHERE id = ?2",
                                    params![text, &item.id],
                                )?;
                            }
                        }
                        merged_count += 1;
                    }
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
                    // New record
                    let new_payload_path = asset_paths.get(&item.id);
                    let (kind_str, resolved_meta) = compute_kind_and_metadata(
                        &item.item_type,
                        item.is_sensitive,
                        None,
                        item.raw_text.as_deref().unwrap_or(&item.summary),
                        new_payload_path.map(|s| s.as_str()),
                    );
                    tx.execute(
                        r#"
                        INSERT INTO clip_items (
                            id, item_type, title, summary, created_at, last_used_at,
                            copy_count, favorite, source_app_bundle_id, source_app_name,
                            is_sensitive, deleted_at, updated_at, payload_path, kind
                        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, NULL, NULL, ?9, ?10, ?11, ?12, ?13)
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
                            if item.is_sensitive { 1 } else { 0 },
                            item.deleted_at,
                            item.updated_at,
                            new_payload_path,
                            kind_str,
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
                        let fts_summary = if item.is_sensitive { "" } else { item.summary.as_str() };
                        tx.execute(
                            r#"
                            INSERT INTO clip_fts (
                                rowid, title, summary, ocr_text, source_app_name, source_app_bundle_id, clip_id
                            ) VALUES ((SELECT rowid FROM clip_items WHERE id = ?3), ?1, ?2, '', '', '', ?3)
                            "#,
                            params![&item.title, fts_summary, &item.id],
                        )?;
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
        let mut stmt = conn.prepare(
            r#"
            SELECT ci.id, ci.item_type, ci.title, ci.summary, cp.raw_text,
                   cp.encrypted_content, cp.nonce, ci.is_sensitive, ci.favorite,
                   ci.created_at, ci.last_used_at, ci.copy_count
            FROM clip_items ci
            LEFT JOIN clip_payloads cp ON ci.id = cp.id
            WHERE ci.deleted_at IS NULL
            ORDER BY ci.last_used_at DESC
            "#,
        )?;

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
            });
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
                    is_sensitive, deleted_at, updated_at, kind
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, NULL, NULL, ?9, NULL, ?10, ?11)
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
            report.imported_count += 1;
        }

        tx.commit()?;
        Ok(report)
    }
}
