use rusqlite::Connection;

use crate::error::Result;

/// 当前 schema 版本。
///
/// - v2：clip_fts.rowid 与 clip_items.rowid 对齐（写路径由按 clip_id 全表扫描降为按 rowid）
/// - v4：派生分类 kind 列回填
/// - v5：FTS 中敏感条目的正文/OCR/来源置空
/// - v6：索引结构与统计信息修订（见 `migrate_to_v6`）
/// - v7：轻量标签（clip_tags 表 + clip_fts.tags 列 + clip_items.tags_updated_at）
pub const SCHEMA_VERSION: i64 = 7;

/// WAL 文件大小上限（8 MiB）。默认 -1 表示永不截断，一次「清空历史」或大批量
/// 清理会把 -wal 文件永久撑到几十 MB 直到进程退出。
const JOURNAL_SIZE_LIMIT_BYTES: i64 = 8 * 1024 * 1024;

pub fn initialize_database(conn: &Connection) -> Result<()> {
    conn.busy_timeout(std::time::Duration::from_millis(5000))?;
    let _: String = conn.query_row("PRAGMA journal_mode = WAL;", [], |row| row.get(0))?;
    conn.pragma_update(None, "synchronous", "NORMAL")?;
    conn.pragma_update(None, "foreign_keys", "ON")?;
    // journal_size_limit 会回显设置后的值（一行结果），必须走 query_row 消费，
    // 否则 execute 报 ExecuteReturnedResults。
    let _ = conn.query_row(
        &format!("PRAGMA journal_size_limit = {JOURNAL_SIZE_LIMIT_BYTES};"),
        [],
        |_| Ok(()),
    );
    // 页缓存上限 512KB：万级历史 + 大文本 FTS 查询下，热查询工作集很小，
    // 实测 512KB / 8MB / 64MB 三档在全部热路径上差异在噪声内；
    // 收紧上限是为了避免大结果集把页缓存长期撑大后常驻。
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
            source_platform TEXT,
            favorite_updated_at REAL NOT NULL DEFAULT 0
        );

        CREATE INDEX IF NOT EXISTS idx_clip_items_active_timeline
        ON clip_items (deleted_at, last_used_at DESC, id DESC);

        CREATE INDEX IF NOT EXISTS idx_clip_items_favorite
        ON clip_items (favorite, deleted_at, last_used_at DESC, id DESC);

        CREATE INDEX IF NOT EXISTS idx_clip_items_type
        ON clip_items (item_type, last_used_at DESC);
        -- 内容去重查找专用：与 save_item_in_tx 的 WHERE 对齐
        --（item_type + summary + is_sensitive = 0）。**非**部分索引：去重需要在
        -- 活跃行与回收站行之间统一裁决（同内容再次复制应复用回收站行而不是新建第二行），
        -- 部分索引的 `deleted_at IS NULL` 谓词会让这条查询无法使用索引。
        CREATE INDEX IF NOT EXISTS idx_clip_items_dedup
        ON clip_items (item_type, summary, last_used_at DESC);
        -- 回收站列表（deleted_at IS NOT NULL，按删除时间倒序）
        CREATE INDEX IF NOT EXISTS idx_clip_items_trash
        ON clip_items (deleted_at DESC, id DESC)
        WHERE deleted_at IS NOT NULL;
        -- 孤儿对账 / 磁盘限额驱逐：只关心带载荷路径的行
        CREATE INDEX IF NOT EXISTS idx_clip_items_payload_lru
        ON clip_items (last_used_at ASC)
        WHERE payload_path IS NOT NULL AND payload_path != '';
        CREATE TABLE IF NOT EXISTS clip_payloads (
            id TEXT PRIMARY KEY,
            raw_text TEXT,
            encrypted_content BLOB,
            nonce BLOB,
            ocr_text TEXT,
            -- 敏感条目的 OCR 文本密文：ocr_text 明文列对 is_sensitive = 1 的行必须为 NULL，
            -- 否则敏感正文以明文落盘（且可经短词 LIKE 回退被检索到）
            ocr_encrypted BLOB,
            ocr_nonce BLOB,
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


        -- 轻量标签：每条目多标签（大小写不敏感判重，保留原始大小写展示）。
        -- clip_id 外键级联：条目硬删除时标签一并清除。
        CREATE TABLE IF NOT EXISTS clip_tags (
            clip_id TEXT NOT NULL,
            tag TEXT NOT NULL COLLATE NOCASE,
            created_at REAL NOT NULL,
            PRIMARY KEY (clip_id, tag),
            FOREIGN KEY (clip_id) REFERENCES clip_items(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_clip_tags_tag ON clip_tags (tag COLLATE NOCASE, clip_id);
        CREATE INDEX IF NOT EXISTS idx_clip_tags_clip ON clip_tags (clip_id);

        CREATE VIRTUAL TABLE IF NOT EXISTS clip_fts USING fts5(
            title,
            summary,
            ocr_text,
            source_app_name,
            source_app_bundle_id,
            tags,
            clip_id UNINDEXED,
            tokenize = 'trigram'
        );
        "#,
    )?;

    // 列级软迁移：按 PRAGMA table_info 判定缺列再 ALTER，不依赖错误字符串匹配
    //（不同 SQLite 版本/本地化下 duplicate column 的措辞不保证一致）。
    let existing_columns = table_columns(conn, "clip_items")?;
    let mut kind_column_added = false;
    for (name, ddl) in [
        ("payload_path", "payload_path TEXT"),
        ("updated_at", "updated_at REAL NOT NULL DEFAULT 0"),
        ("kind", "kind TEXT NOT NULL DEFAULT 'text'"),
        ("source_device_id", "source_device_id TEXT"),
        ("source_device_name", "source_device_name TEXT"),
        ("source_platform", "source_platform TEXT"),
        (
            "favorite_updated_at",
            "favorite_updated_at REAL NOT NULL DEFAULT 0",
        ),
        ("tags_updated_at", "tags_updated_at REAL NOT NULL DEFAULT 0"),
    ] {
        if !existing_columns.iter().any(|c| c == name) {
            conn.execute(&format!("ALTER TABLE clip_items ADD COLUMN {ddl};"), [])?;
            if name == "kind" {
                kind_column_added = true;
            }
        }
    }
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_clip_items_kind ON clip_items (deleted_at, kind, last_used_at DESC, id DESC);",
        [],
    )?;

    // clip_payloads 的列级软迁移（敏感条目 OCR 密文列）
    let payload_columns = table_columns(conn, "clip_payloads")?;
    for (name, ddl) in [
        ("ocr_encrypted", "ocr_encrypted BLOB"),
        ("ocr_nonce", "ocr_nonce BLOB"),
    ] {
        if !payload_columns.iter().any(|c| c == name) {
            conn.execute(&format!("ALTER TABLE clip_payloads ADD COLUMN {ddl};"), [])?;
        }
    }

    // 迁移判定以「打开时读到的版本」为快照，各步骤只升不降。
    let version: i64 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;

    // 索引结构 v2：clip_fts 行的 rowid 与 clip_items.rowid 一一对齐。
    // FTS5 表的 clip_id 是 UNINDEXED 列，按其删除/更新必须全表扫描（写路径 O(N)、
    // 批量 O(N²)）；对齐后所有 FTS 维护按 rowid 定位（O(log N)）。
    // 存量库（user_version < 2）一次性全删重建；user_version 从 0 起跳，
    // 新库重建为空操作。
    if version < 2 {
        conn.execute_batch(
            r#"
            DELETE FROM clip_fts;
            INSERT INTO clip_fts (rowid, title, summary, ocr_text, source_app_name, source_app_bundle_id, tags, clip_id)
            SELECT ci.rowid, ci.title, ci.summary, COALESCE(cp.ocr_text, ''),
                   COALESCE(ci.source_app_name, ''), COALESCE(ci.source_app_bundle_id, ''), '', ci.id
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
        // 回填与版本号同事务：中断时整体回滚，避免「半回填 + 已升版本」的错位状态。
        let tx = conn.unchecked_transaction()?;
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
            tx.execute(
                "UPDATE clip_items SET kind = ?1 WHERE id = ?2",
                rusqlite::params![kind_str, row.id],
            )?;
        }
        // 只有确实低于 v4 时才推进版本；缺列回填（version 已 >= 4）不得把版本写回 4。
        if version < 4 {
            tx.execute_batch("PRAGMA user_version = 4;")?;
        }
        tx.commit()?;
    }
    if version < 5 {
        conn.execute_batch(
            r#"
            DELETE FROM clip_fts;
            INSERT INTO clip_fts (rowid, title, summary, ocr_text, source_app_name, source_app_bundle_id, tags, clip_id)
            SELECT ci.rowid, ci.title,
                   CASE WHEN ci.is_sensitive = 1 THEN '' ELSE ci.summary END,
                   CASE WHEN ci.is_sensitive = 1 THEN '' ELSE COALESCE(cp.ocr_text, '') END,
                   CASE WHEN ci.is_sensitive = 1 THEN '' ELSE COALESCE(ci.source_app_name, '') END,
                   CASE WHEN ci.is_sensitive = 1 THEN '' ELSE COALESCE(ci.source_app_bundle_id, '') END,
                   '',
                   ci.id
            FROM clip_items ci
            LEFT JOIN clip_payloads cp ON ci.id = cp.id;
            PRAGMA user_version = 5;
            "#,
        )?;
    }
    if version < 6 {
        migrate_to_v6(conn)?;
    }

    if version < 7 {
        migrate_to_v7(conn)?;
    }

    // 每次打开顺带让优化器按需刷新统计信息（无统计需求时是空操作）。
    // PRAGMA optimize 在部分版本会返回一行、部分版本不返回，统一忽略两种结果。
    let _ = conn.query_row("PRAGMA optimize;", [], |_| Ok::<(), rusqlite::Error>(()));
    Ok(())
}

/// v6：索引结构与统计信息修订。
///
/// 1. 时间线/分类/收藏索引补 `id DESC` 末列——查询是
///    `ORDER BY last_used_at DESC, id DESC`，缺末列会让 SQLite 建临时 B-Tree
///    并把整个 OFFSET 前缀物化（深翻页/refreshHasMore 的 offset 查询尤其明显）。
/// 2. 收藏索引把 `deleted_at` 提前，避免 `favorite=1 AND deleted_at IS NULL`
///    只靠首列定位后在有序扫描中大量跳过已删行。
/// 3. 新增去重/回收站/载荷路径三条部分索引（定义见建表语句）。
/// 4. 首次 ANALYZE：仓库此前从未生成 sqlite_stat1，优化器只能按经验估值。
fn migrate_to_v6(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        r#"
        DROP INDEX IF EXISTS idx_clip_items_active_timeline;
        DROP INDEX IF EXISTS idx_clip_items_favorite;
        DROP INDEX IF EXISTS idx_clip_items_kind;

        CREATE INDEX IF NOT EXISTS idx_clip_items_active_timeline
        ON clip_items (deleted_at, last_used_at DESC, id DESC);

        CREATE INDEX IF NOT EXISTS idx_clip_items_favorite
        ON clip_items (favorite, deleted_at, last_used_at DESC, id DESC);

        CREATE INDEX IF NOT EXISTS idx_clip_items_kind
        ON clip_items (deleted_at, kind, last_used_at DESC, id DESC);

        DROP INDEX IF EXISTS idx_clip_items_dedup_summary;
        DROP INDEX IF EXISTS idx_clip_items_dedup_lru;
        CREATE INDEX IF NOT EXISTS idx_clip_items_dedup
        ON clip_items (item_type, summary, last_used_at DESC);

        CREATE INDEX IF NOT EXISTS idx_clip_items_trash
        ON clip_items (deleted_at DESC, id DESC)
        WHERE deleted_at IS NOT NULL;

        CREATE INDEX IF NOT EXISTS idx_clip_items_payload_lru
        ON clip_items (last_used_at ASC)
        WHERE payload_path IS NOT NULL AND payload_path != '';
        "#,
    )?;
    // ANALYZE 在空库/小库上是毫秒级；万级历史约数十毫秒，一次性成本。
    conn.execute_batch("ANALYZE;")?;
    conn.execute_batch("PRAGMA user_version = 6;")?;
    Ok(())
}

/// v7：轻量标签。
///
/// 1. `clip_tags` 表与索引由 initialize 的 `CREATE ... IF NOT EXISTS` 保证存在
///    （新库与存量库都在此处之前建好）。
/// 2. `clip_items.tags_updated_at` 由列级软迁移补齐（本函数之前已执行）。
/// 3. `clip_fts` 需要新增 `tags` 列：FTS5 不支持 ALTER ADD COLUMN，只能 DROP 后
///    按新结构重建，并全量回填每行的 tags 文本（敏感条目也写入 tags，
///    正文/OCR/来源仍置空）。
fn migrate_to_v7(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        r#"
        DROP TABLE IF EXISTS clip_fts;
        CREATE VIRTUAL TABLE clip_fts USING fts5(
            title,
            summary,
            ocr_text,
            source_app_name,
            source_app_bundle_id,
            tags,
            clip_id UNINDEXED,
            tokenize = 'trigram'
        );
        "#,
    )?;
    // 全量回填：tags 列聚合该条目全部标签（空格分隔，配合 trigram 分词可子串命中）。
    // 敏感条目：title + tags 正常写入；summary/ocr/来源置空。
    conn.execute_batch(
        r#"
        INSERT INTO clip_fts (rowid, title, summary, ocr_text, source_app_name, source_app_bundle_id, tags, clip_id)
        SELECT ci.rowid, ci.title,
               CASE WHEN ci.is_sensitive = 1 THEN '' ELSE ci.summary END,
               CASE WHEN ci.is_sensitive = 1 THEN '' ELSE COALESCE(cp.ocr_text, '') END,
               CASE WHEN ci.is_sensitive = 1 THEN '' ELSE COALESCE(ci.source_app_name, '') END,
               CASE WHEN ci.is_sensitive = 1 THEN '' ELSE COALESCE(ci.source_app_bundle_id, '') END,
               COALESCE((SELECT group_concat(ct.tag, ' ') FROM clip_tags ct WHERE ct.clip_id = ci.id), ''),
               ci.id
        FROM clip_items ci
        LEFT JOIN clip_payloads cp ON ci.id = cp.id;
        "#,
    )?;
    conn.execute_batch("PRAGMA user_version = 7;")?;
    Ok(())
}

/// 读取表的列名集合（用于列级软迁移）。
fn table_columns(conn: &Connection, table: &str) -> Result<Vec<String>> {
    let mut stmt = conn.prepare(&format!("PRAGMA table_info({table})"))?;
    let rows = stmt.query_map([], |row| row.get::<_, String>(1))?;
    Ok(rows.collect::<std::result::Result<Vec<_>, _>>()?)
}

/// 截断 WAL 文件（清空历史/大批量清理后调用）。
/// `journal_size_limit` 只约束下次 checkpoint 的重启点，不会主动回收；
/// 显式 TRUNCATE 才能把磁盘占用立刻降下来。
pub fn checkpoint_truncate(conn: &Connection) {
    // 单连接、无并发读者时不会阻塞；失败（如被其它连接占用）时静默降级为自动 checkpoint
    let _ = conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);");
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
