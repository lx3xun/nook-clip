use rusqlite::Connection;

use crate::error::Result;

pub fn initialize_database(conn: &Connection) -> Result<()> {
    conn.busy_timeout(std::time::Duration::from_millis(5000))?;
    let _: String = conn.query_row("PRAGMA journal_mode = WAL;", [], |row| row.get(0))?;
    conn.pragma_update(None, "synchronous", "NORMAL")?;
    conn.pragma_update(None, "foreign_keys", "ON")?;
    // 限制 SQLite 页缓存上限为 512KB（默认 -2000 约 8MB），防止万级历史或大文本 FTS 查询后页缓存长期膨胀
    conn.pragma_update(None, "cache_size", -512)?;
    conn.pragma_update(None, "temp_store", "MEMORY")?;
    conn.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS clip_items (
            id TEXT PRIMARY KEY,
            item_type TEXT NOT NULL,
            title TEXT NOT NULL,
            summary TEXT NOT NULL,
            created_at REAL NOT NULL,
            last_used_at REAL NOT NULL,
            copy_count INTEGER NOT NULL DEFAULT 1,
            favorite INTEGER NOT NULL DEFAULT 0,
            source_app_bundle_id TEXT,
            source_app_name TEXT,
            is_sensitive INTEGER NOT NULL DEFAULT 0,
            deleted_at REAL,
            payload_path TEXT,
            updated_at REAL NOT NULL DEFAULT 0,
            kind TEXT NOT NULL DEFAULT 'text',
            source_device_id TEXT,
            source_device_name TEXT,
            source_platform TEXT
        );

        CREATE INDEX IF NOT EXISTS idx_clip_items_active_timeline
        ON clip_items (deleted_at, last_used_at DESC);

        CREATE INDEX IF NOT EXISTS idx_clip_items_favorite
        ON clip_items (favorite, last_used_at DESC);

        CREATE INDEX IF NOT EXISTS idx_clip_items_type
        ON clip_items (item_type, last_used_at DESC);
        CREATE INDEX IF NOT EXISTS idx_clip_items_dedup_summary
        ON clip_items (item_type, summary) WHERE deleted_at IS NULL AND is_sensitive = 0;
        CREATE TABLE IF NOT EXISTS clip_payloads (
            id TEXT PRIMARY KEY,
            raw_text TEXT,
            encrypted_content BLOB,
            nonce BLOB,
            ocr_text TEXT,
            metadata_json TEXT,
            FOREIGN KEY(id) REFERENCES clip_items(id) ON DELETE CASCADE
        );

        -- 硬删除（prune/purge/clear）条目的云端墓碑：行已物理删除，仅留
        -- id 与删除时间随 pack 广播 7 天，防止对端把已删条目当作新条目复活
        CREATE TABLE IF NOT EXISTS sync_tombstones (
            id TEXT PRIMARY KEY,
            deleted_at REAL NOT NULL
        );
        -- 增量同步游标：记录各设备上次拉取成功的指纹（ETag / mtime），未变化时短路跳过下载
        CREATE TABLE IF NOT EXISTS sync_cursors (
            device_id TEXT PRIMARY KEY,
            last_fingerprint TEXT,
            synced_at REAL NOT NULL
        );


        CREATE VIRTUAL TABLE IF NOT EXISTS clip_fts USING fts5(
            title,
            summary,
            ocr_text,
            source_app_name,
            source_app_bundle_id,
            clip_id UNINDEXED,
            tokenize = 'trigram'
        );
        "#,
    )?;
    // Soft migration for existing clip_items tables without payload_path
    if let Err(e) = conn.execute("ALTER TABLE clip_items ADD COLUMN payload_path TEXT;", []) {
        // 仅忽略重复列（列已存在）；其余迁移错误必须上抛，不能吞掉
        if !e.to_string().contains("duplicate column name") {
            return Err(e.into());
        }
    }
    // Soft migration for existing clip_items tables without updated_at (pack v2 LWW 判新)
    if let Err(e) = conn.execute(
        "ALTER TABLE clip_items ADD COLUMN updated_at REAL NOT NULL DEFAULT 0;",
        [],
    ) {
        if !e.to_string().contains("duplicate column name") {
            return Err(e.into());
        }
    }
    // Soft migration for existing clip_items tables without kind (persisted derived kind column)
    let mut kind_column_added = false;
    if let Err(e) = conn.execute(
        "ALTER TABLE clip_items ADD COLUMN kind TEXT NOT NULL DEFAULT 'text';",
        [],
    ) {
        if !e.to_string().contains("duplicate column name") {
            return Err(e.into());
        }
    } else {
        kind_column_added = true;
    }
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_clip_items_kind ON clip_items (deleted_at, kind, last_used_at DESC);",
        [],
    )?;
    // Soft migration for source device & platform columns
    for col in &["source_device_id", "source_device_name", "source_platform"] {
        if let Err(e) = conn.execute(&format!("ALTER TABLE clip_items ADD COLUMN {} TEXT;", col), []) {
            if !e.to_string().contains("duplicate column name") {
                return Err(e.into());
            }
        }
    }


    // 索引结构 v2：clip_fts 行的 rowid 与 clip_items.rowid 一一对齐。
    // FTS5 表的 clip_id 是 UNINDEXED 列，按其删除/更新必须全表扫描（写路径 O(N)、
    // 批量 O(N²)）；对齐后所有 FTS 维护按 rowid 定位（O(log N)）。
    // 存量库（user_version < 2）一次性全删重建；user_version 从 0 起跳，
    // 新库重建为空操作。
    let version: i64 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    if version < 2 {
        conn.execute_batch(
            r#"
            DELETE FROM clip_fts;
            INSERT INTO clip_fts (rowid, title, summary, ocr_text, source_app_name, source_app_bundle_id, clip_id)
            SELECT ci.rowid, ci.title, ci.summary, COALESCE(cp.ocr_text, ''),
                   COALESCE(ci.source_app_name, ''), COALESCE(ci.source_app_bundle_id, ''), ci.id
            FROM clip_items ci
            LEFT JOIN clip_payloads cp ON ci.id = cp.id
            WHERE ci.is_sensitive = 0;
            PRAGMA user_version = 2;
            "#,
        )?;
    }
    if version < 4 || kind_column_added {
        use crate::algorithms::kind::{classify_kind, ItemKind};
        struct KindMigrationRow {
            id: String,
            item_type: String,
            is_sensitive: bool,
            payload_path: Option<String>,
            summary: String,
            metadata_json: Option<String>,
        }
        let rows: Vec<KindMigrationRow> = {
            let mut stmt = conn.prepare(
                r#"
                SELECT ci.id, ci.item_type, ci.is_sensitive, ci.payload_path,
                       COALESCE(cp.raw_text, ci.summary), cp.metadata_json
                FROM clip_items ci
                LEFT JOIN clip_payloads cp ON ci.id = cp.id
                "#,
            )?;
            let mapped = stmt.query_map([], |row| {
                Ok(KindMigrationRow {
                    id: row.get(0)?,
                    item_type: row.get(1)?,
                    is_sensitive: row.get::<_, i64>(2)? == 1,
                    payload_path: row.get(3)?,
                    summary: row.get(4)?,
                    metadata_json: row.get(5)?,
                })
            })?;
            mapped.collect::<std::result::Result<Vec<_>, _>>()?
        };
        for row in rows {
            let k = classify_kind(
                &row.item_type,
                row.is_sensitive,
                row.metadata_json.as_deref(),
                &row.summary,
                row.payload_path.as_deref(),
            );
            let kind_str = match k {
                ItemKind::Text => "text",
                ItemKind::Image => "image",
                ItemKind::File => "file",
                ItemKind::Url => "url",
                ItemKind::Code => "code",
                ItemKind::Json => "json",
                ItemKind::Color => "color",
                ItemKind::Sensitive => "sensitive",
            };
            conn.execute(
                "UPDATE clip_items SET kind = ?1 WHERE id = ?2",
                rusqlite::params![kind_str, row.id],
            )?;
        }
        conn.execute_batch("PRAGMA user_version = 4;")?;
    }
    if version < 5 {
        conn.execute_batch(
            r#"
            DELETE FROM clip_fts;
            INSERT INTO clip_fts (rowid, title, summary, ocr_text, source_app_name, source_app_bundle_id, clip_id)
            SELECT ci.rowid, ci.title,
                   CASE WHEN ci.is_sensitive = 1 THEN '' ELSE ci.summary END,
                   CASE WHEN ci.is_sensitive = 1 THEN '' ELSE COALESCE(cp.ocr_text, '') END,
                   CASE WHEN ci.is_sensitive = 1 THEN '' ELSE COALESCE(ci.source_app_name, '') END,
                   CASE WHEN ci.is_sensitive = 1 THEN '' ELSE COALESCE(ci.source_app_bundle_id, '') END,
                   ci.id
            FROM clip_items ci
            LEFT JOIN clip_payloads cp ON ci.id = cp.id;
            PRAGMA user_version = 5;
            "#,
        )?;
    }

    Ok(())
}
pub fn database_has_encrypted_payloads(db_path: &str) -> bool {
    if !std::path::Path::new(db_path).exists() {
        return false;
    }
    let flags = rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX;
    match rusqlite::Connection::open_with_flags(db_path, flags) {
        Ok(conn) => match &conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM clip_payloads WHERE encrypted_content IS NOT NULL LIMIT 1)",
            [],
            |row| row.get::<_, bool>(0),
        ) {
            Ok(has_encrypted) => *has_encrypted,
            Err(rusqlite::Error::SqliteFailure(_, Some(msg)))
                if msg.contains("no such table") =>
            {
                false
            }
            // 数据库存在但遇到 SQLITE_BUSY / I/O 异常时保守视为可能含有密文，防止误生成新密钥
            Err(_) => true,
        },
        Err(_) => true,
    }
}
