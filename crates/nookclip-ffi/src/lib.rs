uniffi::setup_scaffolding!();

use nookclip_core::{algorithms, model as core_model, storage::StorageRepository, CoreError};
use std::sync::Arc;

#[derive(uniffi::Error, thiserror::Error, Debug)]
pub enum NookClipError {
    #[error("Database error: {0}")]
    DatabaseError(String),
    #[error("Item not found: {0}")]
    NotFound(String),
    #[error("Crypto error: {0}")]
    CryptoError(String),
    #[error("Serialization error: {0}")]
    SerializationError(String),
    #[error("Invalid argument: {0}")]
    InvalidArgument(String),
    #[error("IO error: {0}")]
    IoError(String),
    #[error("Invalid data: {0}")]
    InvalidData(String),
}

impl From<CoreError> for NookClipError {
    fn from(err: CoreError) -> Self {
        match err {
            CoreError::Database(e) => NookClipError::DatabaseError(e.to_string()),
            CoreError::NotFound(id) => NookClipError::NotFound(id),
            CoreError::Crypto(e) => NookClipError::CryptoError(e),
            CoreError::Serialization(e) => NookClipError::SerializationError(e),
            CoreError::InvalidArgument(e) => NookClipError::InvalidArgument(e),
            CoreError::Io(e) => NookClipError::IoError(e.to_string()),
            CoreError::InvalidData(e) => NookClipError::InvalidData(e),
        }
    }
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct ClipItemSummary {
    pub id: String,
    pub item_type: String,
    pub title: String,
    pub summary: String,
    pub created_at: f64,
    pub last_used_at: f64,
    pub copy_count: i64,
    pub favorite: bool,
    pub source_app_bundle_id: Option<String>,
    pub source_app_name: Option<String>,
    pub is_sensitive: bool,
    pub deleted_at: Option<f64>,
    pub payload_path: Option<String>,
    pub ocr_text: Option<String>,
    pub metadata_json: Option<String>,
    #[uniffi(default = "")]
    pub kind: String,
}

impl From<core_model::ClipItemSummary> for ClipItemSummary {
    fn from(m: core_model::ClipItemSummary) -> Self {
        Self {
            id: m.id,
            item_type: m.item_type,
            title: m.title,
            summary: m.summary,
            created_at: m.created_at,
            last_used_at: m.last_used_at,
            copy_count: m.copy_count,
            favorite: m.favorite,
            source_app_bundle_id: m.source_app_bundle_id,
            source_app_name: m.source_app_name,
            is_sensitive: m.is_sensitive,
            deleted_at: m.deleted_at,
            payload_path: m.payload_path,
            ocr_text: m.ocr_text,
            metadata_json: m.metadata_json,
            kind: m.kind,
        }
    }
}

/// 批量写入条目：item 字段语义与 save_item 参数一致
///（ocr_text/metadata_json 取 item 内字段），raw_text 为可选明文
#[derive(uniffi::Record, Clone, Debug)]
pub struct BatchSaveItem {
    pub item: ClipItemSummary,
    pub raw_text: Option<String>,
}


impl From<ClipItemSummary> for core_model::ClipItemSummary {
    fn from(m: ClipItemSummary) -> Self {
        Self {
            id: m.id,
            item_type: m.item_type,
            title: m.title,
            summary: m.summary,
            created_at: m.created_at,
            last_used_at: m.last_used_at,
            copy_count: m.copy_count,
            favorite: m.favorite,
            source_app_bundle_id: m.source_app_bundle_id,
            source_app_name: m.source_app_name,
            is_sensitive: m.is_sensitive,
            deleted_at: m.deleted_at,
            payload_path: m.payload_path,
            ocr_text: m.ocr_text,
            metadata_json: m.metadata_json,
            kind: m.kind,
        }
    }
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct ClipItemDetail {
    pub id: String,
    pub raw_text: Option<String>,
    pub ocr_text: Option<String>,
    pub metadata_json: Option<String>,
    pub is_sensitive: bool,
}

impl From<core_model::ClipItemDetail> for ClipItemDetail {
    fn from(d: core_model::ClipItemDetail) -> Self {
        Self {
            id: d.id,
            raw_text: d.raw_text,
            ocr_text: d.ocr_text,
            metadata_json: d.metadata_json,
            is_sensitive: d.is_sensitive,
        }
    }
}
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PrunedItemRecord {
    pub id: String,
    pub payload_path: Option<String>,
}

impl From<core_model::PrunedItemRecord> for PrunedItemRecord {
    fn from(r: core_model::PrunedItemRecord) -> Self {
        Self {
            id: r.id,
            payload_path: r.payload_path,
        }
    }
}
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct SyncReport {
    pub pulled_count: u32,
    pub pushed_count: u32,
    pub tombstoned_count: u32,
    pub assets_transferred: u32,
    /// 拉取失败但未中断其余设备的 pack（设备名 + 错误摘要）
    pub failed_packs: Vec<String>,
}

impl From<nookclip_core::sync::engine::SyncReport> for SyncReport {
    fn from(r: nookclip_core::sync::engine::SyncReport) -> Self {
        Self {
            pulled_count: r.pulled_count,
            pushed_count: r.pushed_count,
            tombstoned_count: r.tombstoned_count,
            assets_transferred: r.assets_transferred,
            failed_packs: r.failed_packs,
        }
    }
}
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq)]
pub enum SensitiveExportMode {
    Exclude,
    Masked,
    Plaintext,
}

impl From<SensitiveExportMode> for nookclip_core::exchange::SensitiveExportMode {
    fn from(m: SensitiveExportMode) -> Self {
        match m {
            SensitiveExportMode::Exclude => nookclip_core::exchange::SensitiveExportMode::Exclude,
            SensitiveExportMode::Masked => nookclip_core::exchange::SensitiveExportMode::Masked,
            SensitiveExportMode::Plaintext => nookclip_core::exchange::SensitiveExportMode::Plaintext,
        }
    }
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct ImportReport {
    pub imported_count: u32,
    pub skipped_duplicates: u32,
    /// Masked 备份中以掩码字面量为正文的敏感条目（无法还原，跳过导入）
    pub skipped_masked: u32,
}

impl From<nookclip_core::exchange::ImportReport> for ImportReport {
    fn from(r: nookclip_core::exchange::ImportReport) -> Self {
        Self {
            imported_count: r.imported_count,
            skipped_duplicates: r.skipped_duplicates,
            skipped_masked: r.skipped_masked,
        }
    }
}

#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct QueryFilter {
    /// 按 id 精确取单条：Swift 侧按需取回全文 summary（列表查询只载入前缀）
    #[uniffi(default = None)]
    pub id: Option<String>,
    pub search_query: Option<String>,
    pub item_type: Option<String>,
    pub kind: Option<String>,
    pub favorite_only: bool,
    pub include_deleted: bool,
    pub limit: u32,
    pub offset: u32,
}

impl From<QueryFilter> for core_model::QueryFilter {
    fn from(f: QueryFilter) -> Self {
        Self {
            id: f.id,
            search_query: f.search_query,
            item_type: f.item_type,
            kind: f.kind,
            favorite_only: f.favorite_only,
            include_deleted: f.include_deleted,
            limit: f.limit,
            offset: f.offset,
        }
    }
}

#[derive(uniffi::Record, Clone, Debug, Default, PartialEq, Eq)]
pub struct CategoryCounts {
    pub total: u64,
    pub favorite: u64,
    pub text: u64,
    pub image: u64,
    pub file: u64,
    pub url: u64,
    pub code: u64,
    pub color: u64,
    pub sensitive: u64,
}

impl From<core_model::CategoryCounts> for CategoryCounts {
    fn from(c: core_model::CategoryCounts) -> Self {
        Self {
            total: c.total,
            favorite: c.favorite,
            text: c.text,
            image: c.image,
            file: c.file,
            url: c.url,
            code: c.code,
            color: c.color,
            sensitive: c.sensitive,
        }
    }
}

#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct RetentionConfig {
    pub max_age_days: Option<u32>,
    pub max_item_count: Option<u32>,
}

impl From<RetentionConfig> for core_model::RetentionConfig {
    fn from(c: RetentionConfig) -> Self {
        Self {
            max_age_days: c.max_age_days,
            max_item_count: c.max_item_count,
        }
    }
}

#[derive(uniffi::Record, Clone, Debug, Default, PartialEq)]
pub struct DetectionResult {
    pub is_sensitive: bool,
    pub sensitive_type: Option<String>,
    pub detected_language: Option<String>,
    #[uniffi(default = false)]
    pub is_code: bool,
    pub detected_color_hex: Option<String>,
    pub has_email: bool,
    pub is_url: bool,
}

impl From<core_model::DetectionResult> for DetectionResult {
    fn from(d: core_model::DetectionResult) -> Self {
        Self {
            is_sensitive: d.is_sensitive,
            sensitive_type: d.sensitive_type,
            detected_language: d.detected_language,
            is_code: d.is_code,
            detected_color_hex: d.detected_color_hex,
            has_email: d.has_email,
            is_url: d.is_url,
        }
    }
}

#[derive(uniffi::Object)]
pub struct NookClipHistoryEngine {
    repo: Arc<StorageRepository>,
}

#[uniffi::export]
impl NookClipHistoryEngine {
    #[uniffi::constructor]
    pub fn new(db_path: String, master_key: Vec<u8>) -> Result<Self, NookClipError> {
        let repo = StorageRepository::new(&db_path, &master_key)?;
        Ok(Self {
            repo: Arc::new(repo),
        })
    }


    /// 批量写入：全部条目单事务提交（导入/初始化/迁移场景），
    /// 逐条语义与单条保存一致（内容去重、FTS 维护），任一失败整体回滚。
    /// 单条保存 = 传入单元素数组（ocr/metadata 随 ClipItemSummary 携带）
    pub fn save_items(&self, items: Vec<BatchSaveItem>) -> Result<Vec<ClipItemSummary>, NookClipError> {
        let entries = items
            .into_iter()
            .map(|batch| {
                (
                    core_model::ClipItemSummary::from(batch.item),
                    batch.raw_text,
                )
            })
            .collect::<Vec<_>>();
        let saved = self.repo.save_items_batch(&entries)?;
        Ok(saved.into_iter().map(Into::into).collect())
    }

    /// 全部条目载荷路径（孤儿对账用，单列轻量查询）
    pub fn payload_paths(&self) -> Result<Vec<String>, NookClipError> {
        Ok(self.repo.all_payload_paths()?)
    }

    pub fn query_items(&self, filter: QueryFilter) -> Result<Vec<ClipItemSummary>, NookClipError> {
        let core_filter = filter.into();
        let items = self.repo.query_items(&core_filter)?;
        Ok(items.into_iter().map(Into::into).collect())
    }

    pub fn get_item_detail(&self, id: String) -> Result<ClipItemDetail, NookClipError> {
        let detail = self.repo.get_item_detail(&id)?;
        Ok(detail.into())
    }

    pub fn toggle_favorite(&self, id: String) -> Result<ClipItemSummary, NookClipError> {
        let summary = self.repo.toggle_favorite(&id)?;
        Ok(summary.into())
    }

    pub fn toggle_sensitive(&self, id: String) -> Result<ClipItemSummary, NookClipError> {
        let summary = self.repo.toggle_sensitive(&id)?;
        Ok(summary.into())
    }

    pub fn mark_used(&self, id: String, used_at: f64) -> Result<ClipItemSummary, NookClipError> {
        let summary = self.repo.mark_used(&id, used_at)?;
        Ok(summary.into())
    }

    pub fn soft_delete(&self, id: String) -> Result<(), NookClipError> {
        self.repo.soft_delete(&id)?;
        Ok(())
    }

    pub fn restore_deleted(&self, id: String) -> Result<(), NookClipError> {
        self.repo.restore_deleted(&id)?;
        Ok(())
    }

    pub fn purge_item(&self, id: String) -> Result<(), NookClipError> {
        self.repo.purge_item(&id)?;
        Ok(())
    }

    pub fn clear_all_history(&self, keep_favorites: bool) -> Result<Vec<PrunedItemRecord>, NookClipError> {
        let records = self.repo.clear_all_history(keep_favorites)?;
        Ok(records.into_iter().map(Into::into).collect())
    }

    pub fn count_items(&self) -> Result<u64, NookClipError> {
        let count = self.repo.count_items()?;
        Ok(count)
    }

    pub fn count_favorites(&self) -> Result<u64, NookClipError> {
        let count = self.repo.count_favorites()?;
        Ok(count)
    }
    pub fn count_categories(&self, search_query: Option<String>) -> Result<CategoryCounts, NookClipError> {
        let counts = self.repo.count_categories(search_query.as_deref())?;
        Ok(counts.into())
    }
    pub fn time_group_timestamps(&self, filter: QueryFilter) -> Result<Vec<f64>, NookClipError> {
        let core_filter = filter.into();
        let timestamps = self.repo.time_group_timestamps(&core_filter)?;
        Ok(timestamps)
    }

    pub fn update_ocr_text(&self, id: String, ocr_text: String) -> Result<(), NookClipError> {
        self.repo.update_ocr_text(&id, &ocr_text)?;
        Ok(())
    }
    pub fn update_title(&self, id: String, title: String) -> Result<(), NookClipError> {
        self.repo.update_title(&id, &title)?;
        Ok(())
    }

    pub fn prune_expired(&self, config: RetentionConfig) -> Result<Vec<PrunedItemRecord>, NookClipError> {
        let core_config = config.into();
        let records = self.repo.prune_expired(&core_config)?;
        Ok(records.into_iter().map(Into::into).collect())
    }

    pub fn enforce_disk_limit(
        &self,
        managed_dir: String,
        limit_bytes: u64,
    ) -> Result<Vec<PrunedItemRecord>, NookClipError> {
        let records = self.repo.enforce_disk_limit(&managed_dir, limit_bytes)?;
        Ok(records.into_iter().map(Into::into).collect())
    }

    pub fn analyze_content(&self, text: String) -> DetectionResult {
        algorithms::analyze_content(&text).into()
    }
    pub fn sync_pull(
        &self,
        sync_dir: String,
        device_id: String,
        local_assets_dir: String,
    ) -> Result<SyncReport, NookClipError> {
        let engine =
            nookclip_core::sync::SyncEngine::new(&sync_dir, device_id, assets_dir_opt(&local_assets_dir))?;
        let report = engine.pull(&self.repo)?;
        Ok(report.into())
    }

    pub fn sync_push(
        &self,
        sync_dir: String,
        device_id: String,
        local_assets_dir: String,
    ) -> Result<SyncReport, NookClipError> {
        let engine =
            nookclip_core::sync::SyncEngine::new(&sync_dir, device_id, assets_dir_opt(&local_assets_dir))?;
        let report = engine.push(&self.repo)?;
        Ok(report.into())
    }

    pub fn sync_now(
        &self,
        sync_dir: String,
        device_id: String,
        local_assets_dir: String,
    ) -> Result<SyncReport, NookClipError> {
        let engine =
            nookclip_core::sync::SyncEngine::new(&sync_dir, device_id, assets_dir_opt(&local_assets_dir))?;
        let report = engine.sync_now(&self.repo)?;
        Ok(report.into())
    }

    /// 主密钥轮换（迁移场景）：见 StorageRepository::rekey
    pub fn rekey(&self, new_master_key: Vec<u8>) -> Result<u64, NookClipError> {
        let count = self.repo.rekey(&new_master_key)?;
        Ok(count as u64)
    }
    pub fn export_json(&self, mode: SensitiveExportMode) -> Result<String, NookClipError> {
        let json = nookclip_core::exchange::export_json(&self.repo, mode.into())?;
        Ok(json)
    }

    pub fn export_markdown(&self, mode: SensitiveExportMode) -> Result<String, NookClipError> {
        let md = nookclip_core::exchange::export_markdown(&self.repo, mode.into())?;
        Ok(md)
    }

    pub fn import_json(&self, json_content: String) -> Result<ImportReport, NookClipError> {
        let report = nookclip_core::exchange::import_json(&self.repo, &json_content)?;
        Ok(report.into())
    }
    /// Stores payload data with SHA-256 deduplication and returns its absolute path.
    pub fn save_payload_asset(
        &self,
        storage_dir: String,
        data: Vec<u8>,
        preferred_extension: String,
    ) -> Result<String, NookClipError> {
        let store = nookclip_core::storage::PayloadAssetStore::new(storage_dir)?;
        let path = store.save_payload_asset(&data, &preferred_extension)?;
        Ok(path)
    }

    pub fn sweep_orphans(
        &self,
        storage_dir: String,
        referenced_filenames: Vec<String>,
        older_than_seconds: f64,
    ) -> Result<u32, NookClipError> {
        let store = nookclip_core::storage::PayloadAssetStore::new(storage_dir)?;
        let count = store.sweep_orphans(&referenced_filenames, older_than_seconds)?;
        Ok(count)
    }
}

/// 同步附件池的本地目录参数：空串视为未提供（禁用附件池），避免可选参数歧义
fn assets_dir_opt(dir: &str) -> Option<std::path::PathBuf> {
    if dir.is_empty() {
        None
    } else {
        Some(std::path::PathBuf::from(dir))
    }
}

#[uniffi::export]
pub fn parse_color_hex(text: String) -> Option<String> {
    algorithms::color::parse_color_hex(&text)
}

#[uniffi::export]
pub fn classify_text_content(text: String) -> DetectionResult {
    algorithms::analyze_content(&text).into()
}

#[uniffi::export]
pub fn save_payload_asset_file(
    storage_dir: String,
    data: Vec<u8>,
    preferred_extension: String,
) -> Result<String, NookClipError> {
    let store = nookclip_core::storage::PayloadAssetStore::new(storage_dir)?;
    Ok(store.save_payload_asset(&data, &preferred_extension)?)
}

#[uniffi::export]
pub fn sweep_orphan_payload_assets(
    storage_dir: String,
    referenced_filenames: Vec<String>,
    older_than_seconds: f64,
) -> Result<u32, NookClipError> {
    let store = nookclip_core::storage::PayloadAssetStore::new(storage_dir)?;
    Ok(store.sweep_orphans(&referenced_filenames, older_than_seconds)?)
}
