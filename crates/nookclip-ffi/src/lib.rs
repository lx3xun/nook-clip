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
    #[error("Missing referenced files: {missing_paths:?}")]
    StaleFiles { missing_paths: Vec<String> },
    #[error("Image payload is missing or unreadable")]
    CorruptedImagePayload,
    #[error("Failed to decrypt sensitive content")]
    DecryptionFailed,
    #[error("Sync transport error: {0}")]
    SyncTransportError(String),
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
            CoreError::StaleFiles { missing_paths } => NookClipError::StaleFiles { missing_paths },
            CoreError::CorruptedImagePayload => NookClipError::CorruptedImagePayload,
            CoreError::DecryptionFailed => NookClipError::DecryptionFailed,
            CoreError::SyncTransport(e) => NookClipError::SyncTransportError(e),
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
#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq)]
pub enum SyncBackendConfig {
    LocalDirectory {
        sync_dir: String,
    },
    WebDav {
        base_url: String,
        username: String,
        password: String,
        timeout_secs: u64,
    },
}

impl From<SyncBackendConfig> for core_model::SyncBackendConfig {
    fn from(c: SyncBackendConfig) -> Self {
        match c {
            SyncBackendConfig::LocalDirectory { sync_dir } => {
                core_model::SyncBackendConfig::LocalDirectory { sync_dir }
            }
            SyncBackendConfig::WebDav {
                base_url,
                username,
                password,
                timeout_secs,
            } => core_model::SyncBackendConfig::WebDav {
                base_url,
                username,
                password,
                timeout_secs,
            },
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

#[derive(uniffi::Record, Clone, Debug, Default, PartialEq)]
pub struct RawClipboardSnapshot {
    pub plain_text: Option<String>,
    pub html: Option<String>,
    pub rtf_data: Option<Vec<u8>>,
    pub image_data: Option<Vec<u8>>,
    pub image_extension: Option<String>,
    pub file_paths: Vec<String>,
    pub url_candidates: Vec<String>,
    pub url_title: Option<String>,
    pub source_bundle_id: Option<String>,
    pub source_app_name: Option<String>,
    pub has_concealed_marker: bool,
}

impl From<RawClipboardSnapshot> for core_model::RawClipboardSnapshot {
    fn from(s: RawClipboardSnapshot) -> Self {
        Self {
            plain_text: s.plain_text,
            html: s.html,
            rtf_data: s.rtf_data,
            image_data: s.image_data,
            image_extension: s.image_extension,
            file_paths: s.file_paths,
            url_candidates: s.url_candidates,
            url_title: s.url_title,
            source_bundle_id: s.source_bundle_id,
            source_app_name: s.source_app_name,
            has_concealed_marker: s.has_concealed_marker,
        }
    }
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct IngestConfig {
    pub sensitive_protection_enabled: bool,
    pub excluded_bundle_ids: Vec<String>,
    pub local_assets_dir: String,
    pub file_multi_title_template: Option<String>,
    pub default_image_title: String,
}

impl From<IngestConfig> for core_model::IngestConfig {
    fn from(c: IngestConfig) -> Self {
        Self {
            sensitive_protection_enabled: c.sensitive_protection_enabled,
            excluded_bundle_ids: c.excluded_bundle_ids,
            local_assets_dir: c.local_assets_dir,
            file_multi_title_template: c.file_multi_title_template,
            default_image_title: c.default_image_title,
        }
    }
}

#[derive(uniffi::Enum, Clone, Debug, PartialEq)]
pub enum IngestOutcome {
    Saved { item: ClipItemSummary },
    SkippedInternalPaste,
    SkippedConcealed,
    SkippedExcludedApp,
    SkippedEmpty,
    SkippedSensitiveProtectionDisabled,
    DroppedEncryptionUnavailable,
    DroppedPayloadSaveFailed,
}

impl From<core_model::IngestOutcome> for IngestOutcome {
    fn from(o: core_model::IngestOutcome) -> Self {
        match o {
            core_model::IngestOutcome::Saved { item } => IngestOutcome::Saved {
                item: item.into(),
            },
            core_model::IngestOutcome::SkippedInternalPaste => IngestOutcome::SkippedInternalPaste,
            core_model::IngestOutcome::SkippedConcealed => IngestOutcome::SkippedConcealed,
            core_model::IngestOutcome::SkippedExcludedApp => IngestOutcome::SkippedExcludedApp,
            core_model::IngestOutcome::SkippedEmpty => IngestOutcome::SkippedEmpty,
            core_model::IngestOutcome::SkippedSensitiveProtectionDisabled => {
                IngestOutcome::SkippedSensitiveProtectionDisabled
            }
            core_model::IngestOutcome::DroppedEncryptionUnavailable => {
                IngestOutcome::DroppedEncryptionUnavailable
            }
            core_model::IngestOutcome::DroppedPayloadSaveFailed => {
                IngestOutcome::DroppedPayloadSaveFailed
            }
        }
    }
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PreparedPastePayload {
    pub item_id: String,
    pub item_type: String,
    pub plain_text: Option<String>,
    pub rtf_data: Option<Vec<u8>>,
    pub image_data: Option<Vec<u8>>,
    pub image_format: Option<String>,
    pub file_paths: Vec<String>,
    pub is_single_image_file: bool,
    pub is_sensitive: bool,
}

impl From<core_model::PreparedPastePayload> for PreparedPastePayload {
    fn from(p: core_model::PreparedPastePayload) -> Self {
        Self {
            item_id: p.item_id,
            item_type: p.item_type,
            plain_text: p.plain_text,
            rtf_data: p.rtf_data,
            image_data: p.image_data,
            image_format: p.image_format,
            file_paths: p.file_paths,
            is_single_image_file: p.is_single_image_file,
            is_sensitive: p.is_sensitive,
        }
    }
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct ImageDimensions {
    pub width: u32,
    pub height: u32,
}
#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq)]
pub enum KeyVaultReadStatus {
    Found { key_bytes: Vec<u8> },
    Missing,
    Unavailable { error_code: i32 },
}

impl From<KeyVaultReadStatus> for nookclip_core::crypto::KeyVaultReadStatus {
    fn from(s: KeyVaultReadStatus) -> Self {
        match s {
            KeyVaultReadStatus::Found { key_bytes } => {
                nookclip_core::crypto::KeyVaultReadStatus::Found { key_bytes }
            }
            KeyVaultReadStatus::Missing => nookclip_core::crypto::KeyVaultReadStatus::Missing,
            KeyVaultReadStatus::Unavailable { error_code } => {
                nookclip_core::crypto::KeyVaultReadStatus::Unavailable { error_code }
            }
        }
    }
}

#[uniffi::export(callback_interface)]
pub trait KeyVaultBackupProvider: Send + Sync {
    fn read_backup_key(&self) -> KeyVaultReadStatus;
    fn write_backup_key(&self, key_bytes: Vec<u8>) -> bool;
}

struct CoreKeyVaultAdapter {
    provider: Box<dyn KeyVaultBackupProvider>,
}

impl nookclip_core::crypto::KeyVaultBackupProvider for CoreKeyVaultAdapter {
    fn read_backup_key(&self) -> nookclip_core::crypto::KeyVaultReadStatus {
        self.provider.read_backup_key().into()
    }

    fn write_backup_key(&self, key_bytes: Vec<u8>) -> bool {
        self.provider.write_backup_key(key_bytes)
    }
}

#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct MaintenanceConfig {
    pub retention: RetentionConfig,
    pub max_disk_bytes: Option<u64>,
    pub orphan_min_age_secs: f64,
    pub local_assets_dir: String,
}

impl From<MaintenanceConfig> for core_model::MaintenanceConfig {
    fn from(c: MaintenanceConfig) -> Self {
        Self {
            retention: c.retention.into(),
            max_disk_bytes: c.max_disk_bytes,
            orphan_min_age_secs: c.orphan_min_age_secs,
            local_assets_dir: if c.local_assets_dir.is_empty() {
                None
            } else {
                Some(c.local_assets_dir)
            },
        }
    }
}

#[derive(uniffi::Record, Clone, Debug, Default, PartialEq, Eq)]
pub struct MaintenanceReport {
    pub pruned_expired_count: u32,
    pub pruned_disk_limit_count: u32,
    pub swept_orphan_files: u32,
    pub purged_blank_count: u32,
    pub pruned_payload_paths: Vec<String>,
}

impl From<core_model::MaintenanceReport> for MaintenanceReport {
    fn from(r: core_model::MaintenanceReport) -> Self {
        Self {
            pruned_expired_count: r.pruned_expired_count,
            pruned_disk_limit_count: r.pruned_disk_limit_count,
            swept_orphan_files: r.swept_orphan_files,
            purged_blank_count: r.purged_blank_count,
            pruned_payload_paths: r.pruned_payload_paths,
        }
    }
}
#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq)]
pub enum TimeBucketKey {
    Today,
    Yesterday,
    ThisWeek,
    LastWeek,
    Month { year: i32, month: u32 },
    Year { year: i32 },
}

impl From<core_model::TimeBucketKey> for TimeBucketKey {
    fn from(k: core_model::TimeBucketKey) -> Self {
        match k {
            core_model::TimeBucketKey::Today => TimeBucketKey::Today,
            core_model::TimeBucketKey::Yesterday => TimeBucketKey::Yesterday,
            core_model::TimeBucketKey::ThisWeek => TimeBucketKey::ThisWeek,
            core_model::TimeBucketKey::LastWeek => TimeBucketKey::LastWeek,
            core_model::TimeBucketKey::Month { year, month } => TimeBucketKey::Month { year, month },
            core_model::TimeBucketKey::Year { year } => TimeBucketKey::Year { year },
        }
    }
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct CalendarContext {
    pub now_ts: f64,
    pub tz_offset_secs: i32,
    pub first_weekday: u8,
}

impl From<CalendarContext> for core_model::CalendarContext {
    fn from(c: CalendarContext) -> Self {
        Self {
            now_ts: c.now_ts,
            tz_offset_secs: c.tz_offset_secs,
            first_weekday: c.first_weekday,
        }
    }
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct TimeGroupSummary {
    pub id: String,
    pub bucket: TimeBucketKey,
    pub count: u32,
}

impl From<core_model::TimeGroupSummary> for TimeGroupSummary {
    fn from(s: core_model::TimeGroupSummary) -> Self {
        Self {
            id: s.id,
            bucket: s.bucket.into(),
            count: s.count,
        }
    }
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct TimeGroupSection {
    pub id: String,
    pub bucket: TimeBucketKey,
    pub items: Vec<ClipItemSummary>,
}

impl From<core_model::TimeGroupSection> for TimeGroupSection {
    fn from(s: core_model::TimeGroupSection) -> Self {
        Self {
            id: s.id,
            bucket: s.bucket.into(),
            items: s.items.into_iter().map(Into::into).collect(),
        }
    }
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct QueryViewSnapshot {
    pub items: Vec<ClipItemSummary>,
    pub groups: Vec<TimeGroupSection>,
    pub timeline_anchors: Vec<TimeGroupSummary>,
    pub category_counts: CategoryCounts,
    pub search_keywords: Vec<String>,
    pub has_more: bool,
}

impl From<core_model::QueryViewSnapshot> for QueryViewSnapshot {
    fn from(s: core_model::QueryViewSnapshot) -> Self {
        Self {
            items: s.items.into_iter().map(Into::into).collect(),
            groups: s.groups.into_iter().map(Into::into).collect(),
            timeline_anchors: s.timeline_anchors.into_iter().map(Into::into).collect(),
            category_counts: s.category_counts.into(),
            search_keywords: s.search_keywords,
            has_more: s.has_more,
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
    #[uniffi::constructor]
    pub fn open_with_key_manager(
        db_path: String,
        key_file_path: String,
        legacy_initialized: bool,
        vault_provider: Box<dyn KeyVaultBackupProvider>,
    ) -> Result<Self, NookClipError> {
        let manager = nookclip_core::crypto::MasterKeyManager::new(&key_file_path);
        let adapter = CoreKeyVaultAdapter {
            provider: vault_provider,
        };

        // 先尝试检查现有数据库是否已有密文
        let has_encrypted = nookclip_core::storage::schema::database_has_encrypted_payloads(&db_path);

        let master_key = manager.resolve_or_create_key(&adapter, legacy_initialized, has_encrypted)?;
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
    pub fn ingest_clipboard_snapshot(
        &self,
        snapshot: RawClipboardSnapshot,
        config: IngestConfig,
        last_pasted_summary: Option<String>,
        last_pasted_time: Option<f64>,
        now_ts: f64,
    ) -> Result<IngestOutcome, NookClipError> {
        let core_snapshot = snapshot.into();
        let core_config = config.into();
        let outcome = nookclip_core::clipboard::ingest::ingest_clipboard_snapshot(
            &self.repo,
            Some(self.repo.crypto()),
            &core_snapshot,
            &core_config,
            last_pasted_summary.as_deref(),
            last_pasted_time,
            now_ts,
        )?;
        Ok(outcome.into())
    }

    pub fn prepare_paste_payload(
        &self,
        id: String,
        plain_text_only: bool,
    ) -> Result<PreparedPastePayload, NookClipError> {
        let payload = nookclip_core::clipboard::egress::prepare_paste_payload(
            &self.repo,
            Some(self.repo.crypto()),
            &id,
            plain_text_only,
        )?;
        Ok(payload.into())
    }

    pub fn prepare_batch_paste_payload(
        &self,
        ids: Vec<String>,
        separator: String,
    ) -> Result<PreparedPastePayload, NookClipError> {
        let payload = nookclip_core::clipboard::egress::prepare_batch_paste_payload(
            &self.repo,
            Some(self.repo.crypto()),
            &ids,
            &separator,
        )?;
        Ok(payload.into())
    }
    pub fn commit_ocr_result(
        &self,
        id: String,
        raw_ocr_text: String,
    ) -> Result<Option<String>, NookClipError> {
        let result = nookclip_core::maintenance::commit_ocr_result(&self.repo, &id, &raw_ocr_text)?;
        Ok(result)
    }

    pub fn run_maintenance(
        &self,
        config: MaintenanceConfig,
    ) -> Result<MaintenanceReport, NookClipError> {
        let report = nookclip_core::maintenance::run_maintenance(&self.repo, &config.into())?;
        Ok(report.into())
    }
    pub fn query_view_snapshot(
        &self,
        filter: QueryFilter,
        calendar: CalendarContext,
    ) -> Result<QueryViewSnapshot, NookClipError> {
        let snapshot = nookclip_core::pipeline::query_snapshot::query_view_snapshot(
            &self.repo,
            &filter.into(),
            &calendar.into(),
        )?;
        Ok(snapshot.into())
    }

    pub fn group_timestamps(
        &self,
        timestamps: Vec<f64>,
        calendar: CalendarContext,
    ) -> Vec<TimeGroupSummary> {
        nookclip_core::pipeline::timeline::group_timestamps(&timestamps, &calendar.into())
            .into_iter()
            .map(Into::into)
            .collect()
    }
    pub fn sync_with_backend(
        &self,
        backend: SyncBackendConfig,
        device_id: String,
        local_assets_dir: String,
    ) -> Result<SyncReport, NookClipError> {
        let storage_backend: Box<dyn nookclip_core::sync::backend::SyncStorageBackend> = match backend {
            SyncBackendConfig::LocalDirectory { sync_dir } => {
                Box::new(nookclip_core::sync::backend::LocalFsBackend::new(&sync_dir))
            }
            SyncBackendConfig::WebDav {
                base_url,
                username,
                password,
                timeout_secs,
            } => Box::new(nookclip_core::sync::backend::WebDavBackend::new(
                base_url,
                username,
                password,
                timeout_secs,
            )),
        };

        let engine = nookclip_core::sync::SyncEngine::with_backend(
            storage_backend,
            device_id,
            assets_dir_opt(&local_assets_dir),
        )?;
        let report = engine.sync_now(&self.repo)?;
        Ok(report.into())
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
pub fn mask_sensitive_text(text: String) -> String {
    algorithms::sensitive::mask_sensitive_text(&text)
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
#[uniffi::export]
pub fn parse_image_dimensions(data: Vec<u8>) -> Option<ImageDimensions> {
    nookclip_core::clipboard::image_header::parse_image_dimensions(&data)
        .map(|(width, height)| ImageDimensions { width, height })
}
#[uniffi::export]
pub fn tokenize_search_keywords(query: String) -> Vec<String> {
    nookclip_core::search::tokenize_search_query(&query)
}
