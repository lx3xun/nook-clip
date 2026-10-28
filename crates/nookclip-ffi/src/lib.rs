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
    #[uniffi(default = None)]
    pub source_device_id: Option<String>,
    #[uniffi(default = None)]
    pub source_device_name: Option<String>,
    #[uniffi(default = None)]
    pub source_platform: Option<String>,
    #[uniffi(default = [])]
    pub tags: Vec<String>,
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
            source_device_id: m.source_device_id,
            source_device_name: m.source_device_name,
            source_platform: m.source_platform,
            tags: m.tags,
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
            source_device_id: m.source_device_id,
            source_device_name: m.source_device_name,
            source_platform: m.source_platform,
            tags: m.tags,
        }
    }
}

/// 单个标签的统计信息（用于筛选条）。
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct TagStat {
    pub name: String,
    pub count: u32,
}

impl From<core_model::TagStat> for TagStat {
    fn from(t: core_model::TagStat) -> Self {
        Self {
            name: t.name,
            count: t.count,
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
#[derive(uniffi::Record, Clone, Debug)]
pub struct SyncOptions {
    pub backend: SyncBackendConfig,
    pub device_id: String,
    pub local_assets_dir: String,
    #[uniffi(default = None)]
    pub passphrase: Option<String>,
    #[uniffi(default = false)]
    pub allow_sensitive: bool,
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
    /// 只看回收站（deleted_at IS NOT NULL，按删除时间倒序）
    #[uniffi(default = false)]
    pub only_deleted: bool,
    pub limit: u32,
    pub offset: u32,
    #[uniffi(default = None)]
    pub summary_max_chars: Option<u32>,
    /// 单标签等值过滤（大小写不敏感）；None/空 = 不过滤。
    #[uniffi(default = None)]
    pub tag: Option<String>,
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
            only_deleted: f.only_deleted,
            limit: f.limit,
            offset: f.offset,
            summary_max_chars: f.summary_max_chars,
            tag: f.tag,
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
    #[uniffi(default = None)]
    pub source_device_id: Option<String>,
    #[uniffi(default = None)]
    pub source_device_name: Option<String>,
    #[uniffi(default = None)]
    pub source_platform: Option<String>,
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
            source_device_id: s.source_device_id,
            source_device_name: s.source_device_name,
            source_platform: s.source_platform,
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
    #[uniffi(default = None)]
    pub source_device_id: Option<String>,
    #[uniffi(default = None)]
    pub source_device_name: Option<String>,
    #[uniffi(default = None)]
    pub source_platform: Option<String>,
}

impl From<IngestConfig> for core_model::IngestConfig {
    fn from(c: IngestConfig) -> Self {
        Self {
            sensitive_protection_enabled: c.sensitive_protection_enabled,
            excluded_bundle_ids: c.excluded_bundle_ids,
            local_assets_dir: c.local_assets_dir,
            file_multi_title_template: c.file_multi_title_template,
            default_image_title: c.default_image_title,
            source_device_id: c.source_device_id,
            source_device_name: c.source_device_name,
            source_platform: c.source_platform,
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

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct OcrTextBlock {
    pub text: String,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl From<OcrTextBlock> for algorithms::ocr_layout::OcrTextBlock {
    fn from(b: OcrTextBlock) -> Self {
        Self {
            text: b.text,
            x: b.x,
            y: b.y,
            width: b.width,
            height: b.height,
        }
    }
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct HighlightRange {
    pub start_byte: u32,
    pub end_byte: u32,
    pub start_char: u32,
    pub end_char: u32,
}

impl From<algorithms::highlight::HighlightRange> for HighlightRange {
    fn from(r: algorithms::highlight::HighlightRange) -> Self {
        Self {
            start_byte: r.start_byte,
            end_byte: r.end_byte,
            start_char: r.start_char,
            end_char: r.end_char,
        }
    }
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct AppActivationRecord {
    pub bundle_id: Option<String>,
    pub name: Option<String>,
    pub is_self: bool,
    pub activated_at: f64,
}

impl From<AppActivationRecord> for algorithms::source_resolver::AppActivationRecord {
    fn from(r: AppActivationRecord) -> Self {
        Self {
            bundle_id: r.bundle_id,
            name: r.name,
            is_self: r.is_self,
            activated_at: r.activated_at,
        }
    }
}

impl From<algorithms::source_resolver::AppActivationRecord> for AppActivationRecord {
    fn from(r: algorithms::source_resolver::AppActivationRecord) -> Self {
        Self {
            bundle_id: r.bundle_id,
            name: r.name,
            is_self: r.is_self,
            activated_at: r.activated_at,
        }
    }
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
    /// 已弃用：「上周」档不再出现在任何分组结果中，保留仅为跨端枚举兼容
    LastWeek,
    /// 月归档。`last_day` = 本月桶实际覆盖到的最后一天（本地日），
    /// 展示层渲染成「10月 1–15日」，避免与按天归档的近档重叠歧义。
    Month { year: i32, month: u32, last_day: u32 },
    Year { year: i32 },
}

impl From<core_model::TimeBucketKey> for TimeBucketKey {
    fn from(k: core_model::TimeBucketKey) -> Self {
        match k {
            core_model::TimeBucketKey::Today => TimeBucketKey::Today,
            core_model::TimeBucketKey::Yesterday => TimeBucketKey::Yesterday,
            core_model::TimeBucketKey::ThisWeek => TimeBucketKey::ThisWeek,
            core_model::TimeBucketKey::LastWeek => TimeBucketKey::LastWeek,
            core_model::TimeBucketKey::Month { year, month, last_day } => {
                TimeBucketKey::Month { year, month, last_day }
            }
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

    /// 配置当前运行时的受管载荷目录（使相对文件名 payload_path 在查询/淘汰时自动解析为当前容器绝对路径）
    pub fn set_assets_dir(&self, assets_dir: String) {
        self.repo.set_assets_dir(assets_dir_opt(&assets_dir));
    }

    /// 读取数据库原始 payload_path 字段（不做运行时目录拼接，供迁移/诊断/测试断言使用）
    pub fn raw_stored_payload_path(&self, id: String) -> Result<Option<String>, NookClipError> {
        Ok(self.repo.raw_stored_payload_path(&id)?)
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

    /// 这批 id 中实际存在的那些（导入去重用，单次 IN 查询，不做实体映射）
    pub fn existing_item_ids(&self, ids: Vec<String>) -> Result<Vec<String>, NookClipError> {
        Ok(self.repo.existing_item_ids(&ids)?)
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
    pub fn count_categories(
        &self,
        search_query: Option<String>,
        tag: Option<String>,
    ) -> Result<CategoryCounts, NookClipError> {
        let counts = self
            .repo
            .count_categories(search_query.as_deref(), tag.as_deref())?;
        Ok(counts.into())
    }
    pub fn time_group_timestamps(&self, filter: QueryFilter) -> Result<Vec<f64>, NookClipError> {
        let core_filter = filter.into();
        let timestamps = self.repo.time_group_timestamps(&core_filter)?;
        Ok(timestamps)
    }

    // ---- 标签（Tag）能力：全部委托 StorageRepository ----

    /// 全量替换某条目的标签，返回带 tags 的最新摘要。
    pub fn set_tags(&self, id: String, tags: Vec<String>) -> Result<ClipItemSummary, NookClipError> {
        let summary = self.repo.set_tags(&id, &tags)?;
        Ok(summary.into())
    }

    /// 追加单个标签（已存在则无变化），返回带 tags 的最新摘要。
    pub fn add_tag(&self, id: String, tag: String) -> Result<ClipItemSummary, NookClipError> {
        let summary = self.repo.add_tag(&id, &tag)?;
        Ok(summary.into())
    }

    /// 移除单个标签（大小写不敏感），返回带 tags 的最新摘要。
    pub fn remove_tag(&self, id: String, tag: String) -> Result<ClipItemSummary, NookClipError> {
        let summary = self.repo.remove_tag(&id, &tag)?;
        Ok(summary.into())
    }

    /// 统计全部未删除条目使用的标签（count DESC, name ASC）。
    pub fn list_tags(&self) -> Result<Vec<TagStat>, NookClipError> {
        let stats = self.repo.list_tags()?;
        Ok(stats.into_iter().map(Into::into).collect())
    }

    /// 全库重命名标签（大小写不敏感，合并到已有同名标签），返回受影响条目数。
    pub fn rename_tag(&self, old: String, new: String) -> Result<u32, NookClipError> {
        let n = self.repo.rename_tag(&old, &new)?;
        Ok(n)
    }

    /// 删除某标签（解除所有关联），返回受影响条目数。
    pub fn delete_tag(&self, name: String) -> Result<u32, NookClipError> {
        let n = self.repo.delete_tag(&name)?;
        Ok(n)
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
    pub fn sync_with_options(
        &self,
        options: SyncOptions,
    ) -> Result<SyncReport, NookClipError> {
        let storage_backend = make_storage_backend(options.backend)?;
        let sync_key = if let Some(passphrase) = options.passphrase.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
            resolve_sync_key(storage_backend.as_ref(), passphrase, true)?
        } else {
            None
        };

        let mut engine = nookclip_core::sync::SyncEngine::with_backend(
            storage_backend,
            options.device_id,
            assets_dir_opt(&options.local_assets_dir),
        )?;
        engine.set_sync_key(sync_key);
        engine.set_allow_sensitive(options.allow_sensitive);
        let report = engine.sync_now(&self.repo)?;
        Ok(report.into())
    }

    pub fn sync_pull_with_options(
        &self,
        options: SyncOptions,
    ) -> Result<SyncReport, NookClipError> {
        let storage_backend = make_storage_backend(options.backend)?;
        let sync_key = if let Some(passphrase) = options.passphrase.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
            resolve_sync_key(storage_backend.as_ref(), passphrase, false)?
        } else {
            None
        };

        let mut engine = nookclip_core::sync::SyncEngine::with_backend(
            storage_backend,
            options.device_id,
            assets_dir_opt(&options.local_assets_dir),
        )?;
        engine.set_sync_key(sync_key);
        engine.set_allow_sensitive(options.allow_sensitive);
        let report = engine.pull(&self.repo)?;
        Ok(report.into())
    }

    pub fn sync_push_with_options(
        &self,
        options: SyncOptions,
    ) -> Result<SyncReport, NookClipError> {
        let storage_backend = make_storage_backend(options.backend)?;
        let sync_key = if let Some(passphrase) = options.passphrase.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
            resolve_sync_key(storage_backend.as_ref(), passphrase, true)?
        } else {
            None
        };

        let mut engine = nookclip_core::sync::SyncEngine::with_backend(
            storage_backend,
            options.device_id,
            assets_dir_opt(&options.local_assets_dir),
        )?;
        engine.set_sync_key(sync_key);
        engine.set_allow_sensitive(options.allow_sensitive);
        let report = engine.push(&self.repo)?;
        Ok(report.into())
    }
    pub fn reset_sync_passphrase(
        &self,
        options: SyncOptions,
    ) -> Result<SyncReport, NookClipError> {
        let passphrase = options.passphrase.as_deref().unwrap_or("").trim();
        if passphrase.is_empty() {
            return Err(NookClipError::InvalidArgument("Passphrase cannot be empty".to_string()));
        }

        let storage_backend = make_storage_backend(options.backend)?;
        storage_backend.ensure_layout()?;

        // 1. 用新口令重新生成并覆盖云端的 sync.manifest
        let (manifest, key) = nookclip_core::sync::create_manifest(passphrase)?;
        storage_backend.write_manifest_atomic(&manifest.to_bytes()?)?;

        // 2. 使用新 key 将本地完整数据重新打包加密并强制推送到云端覆盖旧 pack
        let mut engine = nookclip_core::sync::SyncEngine::with_backend(
            storage_backend,
            options.device_id,
            assets_dir_opt(&options.local_assets_dir),
        )?;
        engine.set_sync_key(Some(key));
        engine.set_allow_sensitive(options.allow_sensitive);

        let report = engine.push(&self.repo)?;
        Ok(report.into())
    }

    pub fn sync_with_backend(
        &self,
        backend: SyncBackendConfig,
        device_id: String,
        local_assets_dir: String,
    ) -> Result<SyncReport, NookClipError> {
        self.sync_with_options(SyncOptions {
            backend,
            device_id,
            local_assets_dir,
            passphrase: None,
            allow_sensitive: false,
        })
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

fn make_storage_backend(
    config: SyncBackendConfig,
) -> Result<Box<dyn nookclip_core::sync::SyncStorageBackend>, NookClipError> {
    let b: Box<dyn nookclip_core::sync::SyncStorageBackend> = match config {
        SyncBackendConfig::LocalDirectory { sync_dir } => {
            Box::new(nookclip_core::sync::LocalFsBackend::new(&sync_dir))
        }
        SyncBackendConfig::WebDav {
            base_url,
            username,
            password,
            timeout_secs,
        } => Box::new(nookclip_core::sync::WebDavBackend::new(
            base_url,
            username,
            password,
            timeout_secs,
        )),
    };
    Ok(b)
}

fn resolve_sync_key(
    backend: &dyn nookclip_core::sync::SyncStorageBackend,
    passphrase: &str,
    create_if_missing: bool,
) -> Result<Option<[u8; 32]>, CoreError> {
    backend.ensure_layout()?;
    let manifest_bytes = backend.read_manifest()?;
    match manifest_bytes {
        Some(bytes) => {
            let manifest = nookclip_core::sync::SyncManifest::from_bytes(&bytes)?;
            let key = nookclip_core::sync::verify_manifest(&manifest, passphrase)?;
            Ok(Some(key))
        }
        None if create_if_missing => {
            let (manifest, key) = nookclip_core::sync::create_manifest(passphrase)?;
            let manifest_bytes = manifest.to_bytes()?;
            backend.write_manifest_atomic(&manifest_bytes)?;
            Ok(Some(key))
        }
        None => Ok(None),
    }
}

#[uniffi::export]
pub fn test_webdav_connection(
    base_url: String,
    username: String,
    password: String,
    timeout_secs: u64,
) -> Result<bool, NookClipError> {
    let backend = nookclip_core::sync::WebDavBackend::new(base_url, username, password, timeout_secs);
    use nookclip_core::sync::SyncStorageBackend;
    // 发送真实读请求校验网络与认证状态（认证失败抛 401 错误，文件不存在返回 Ok(None)）
    backend.read_manifest()?;
    backend.ensure_layout()?;
    Ok(true)
}

#[uniffi::export]
pub fn test_sync_passphrase(
    backend: SyncBackendConfig,
    passphrase: String,
) -> Result<bool, NookClipError> {
    let passphrase = passphrase.trim();
    if passphrase.is_empty() {
        return Err(NookClipError::InvalidArgument("Passphrase cannot be empty".to_string()));
    }
    let storage_backend = make_storage_backend(backend)?;
    resolve_sync_key(storage_backend.as_ref(), passphrase, true)?;
    Ok(true)
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

#[uniffi::export]
pub fn format_ocr_layout_blocks(blocks: Vec<OcrTextBlock>) -> String {
    let core_blocks: Vec<algorithms::ocr_layout::OcrTextBlock> =
        blocks.into_iter().map(Into::into).collect();
    algorithms::ocr_layout::format_ocr_layout(&core_blocks)
}

#[uniffi::export]
pub fn match_search_highlight_ranges(text: String, keywords: Vec<String>) -> Vec<HighlightRange> {
    algorithms::highlight::match_search_ranges(&text, &keywords)
        .into_iter()
        .map(Into::into)
        .collect()
}

#[uniffi::export]
pub fn resolve_clipboard_source_app(
    history: Vec<AppActivationRecord>,
    now_ts: f64,
    poll_interval: f64,
) -> Option<AppActivationRecord> {
    let core_history: Vec<algorithms::source_resolver::AppActivationRecord> =
        history.into_iter().map(Into::into).collect();
    algorithms::source_resolver::resolve_source_app(&core_history, now_ts, poll_interval)
        .map(Into::into)
}

// ---------------------------------------------------------------------------
// 终端安全粘贴护栏（Terminal Safe-Paste / P0）
// ---------------------------------------------------------------------------

/// 终端粘贴风险评估结果（与 Rust `TerminalPasteAssessment` 一一对应）。
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct FfiTerminalPasteAssessment {
    /// 目标应用是否已知终端；false 时其余字段无意义，客户端走原有粘贴路径
    pub is_terminal: bool,
    /// 是否需要弹窗确认（多行命令或命中高危词）
    pub requires_confirmation: bool,
    /// 命中的高危分类稳定标识（如 "multiline" / "sudo" / "rm_rf"），
    /// 由客户端翻译成用户文案
    pub hazards: Vec<String>,
    /// 去掉末尾回车后剩余的非空行数（1 = 单行）
    pub line_count: u32,
    /// 建议粘贴的文本：已去掉末尾所有换行/回车
    pub safe_text: String,
    /// 可安全串联时给出的单行形态（`cmd1 && cmd2`）；不可串联时等于 `safe_text`
    pub single_line_text: String,
    /// 多行能否安全合并为一行（false 时调用方不要提供「合并为一行」选项）
    pub can_merge_single_line: bool,
    /// 原文末尾确有换行（静默档据此给一句轻提示）
    pub strips_trailing_newline: bool,
}

impl From<algorithms::terminal_guard::TerminalPasteAssessment> for FfiTerminalPasteAssessment {
    fn from(a: algorithms::terminal_guard::TerminalPasteAssessment) -> Self {
        Self {
            is_terminal: a.is_terminal,
            requires_confirmation: a.requires_confirmation,
            hazards: a.hazards.into_iter().map(|h| h.key().to_string()).collect(),
            line_count: a.line_count,
            safe_text: a.safe_text,
            single_line_text: a.single_line_text,
            can_merge_single_line: a.can_merge_single_line,
            strips_trailing_newline: a.strips_trailing_newline,
        }
    }
}

/// 判定一次粘贴要不要按「终端安全」处理。
///
/// - `bundle_id` 为空或不是已知终端：`is_terminal = false`，调用方原样粘贴；
/// - 终端 + 单行普通命令带末尾回车：`strips_trailing_newline = true`，
///   调用方粘贴 `safe_text` 并给一句轻提示，不弹窗；
/// - 终端 + 多行 / 高危：`requires_confirmation = true`，调用方必须弹窗确认。
#[uniffi::export]
pub fn assess_terminal_paste_risk(
    bundle_id: String,
    text: String,
) -> FfiTerminalPasteAssessment {
    algorithms::terminal_guard::assess_terminal_paste(&bundle_id, &text).into()
}

/// 带应用显示名称与「是否保护编辑器内置终端」开关的终端粘贴风险评估。
#[uniffi::export]
pub fn assess_terminal_paste_risk_with_context(
    bundle_id: String,
    app_name: String,
    text: String,
    include_ide_terminals: bool,
) -> FfiTerminalPasteAssessment {
    algorithms::terminal_guard::assess_terminal_paste_with_context(
        &bundle_id,
        &app_name,
        &text,
        include_ide_terminals,
    )
    .into()
}

/// 目标应用是否是已知终端（设置页预览 / 测试用）。
#[uniffi::export]
pub fn is_terminal_bundle_id(bundle_id: String) -> bool {
    algorithms::terminal_guard::is_terminal_bundle_id(&bundle_id)
}

/// 综合 Bundle ID、应用显示名称与 IDE 开关判断目标是否受终端护栏保护。
#[uniffi::export]
pub fn is_terminal_target_app(
    bundle_id: String,
    app_name: String,
    include_ide_terminals: bool,
) -> bool {
    algorithms::terminal_guard::is_terminal_target(&bundle_id, &app_name, include_ide_terminals)
}

#[uniffi::export]
pub fn resolve_or_create_master_key(
    key_file_path: String,
    legacy_initialized: bool,
    has_encrypted_payloads: bool,
    vault_provider: Box<dyn KeyVaultBackupProvider>,
) -> Result<Vec<u8>, NookClipError> {
    let manager = nookclip_core::crypto::MasterKeyManager::new(&key_file_path);
    let adapter = CoreKeyVaultAdapter {
        provider: vault_provider,
    };
    let key = manager.resolve_or_create_key(&adapter, legacy_initialized, has_encrypted_payloads)?;
    Ok(key.to_vec())
}

// ---------------------------------------------------------------------------
// 隐私脱敏（Phase 1 / specs/012-scrub-stack-pin US1）
// ---------------------------------------------------------------------------

/// 用户自定义脱敏规则（与 Rust 侧 `CustomScrubRule` 一一对应）。
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct FfiCustomScrubRule {
    pub id: String,
    pub name: String,
    /// false = 字面量关键词匹配，true = 正则表达式
    pub is_regex: bool,
    pub pattern: String,
    /// 占位符标签前缀，如 "COMPANY" 生成 `<COMPANY_1>`
    pub placeholder_tag: String,
    pub enabled: bool,
}

/// 脱敏引擎配置。
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct FfiScrubConfig {
    /// 启用的内置规则 key 列表（严格白名单，空 = 全部停用；`default()` 给全集）
    pub enabled_builtin_rules: Vec<String>,
    pub custom_rules: Vec<FfiCustomScrubRule>,
    /// 会话映射表闲置过期秒数（0 = 每次调用后立即销毁）
    pub session_ttl_seconds: u64,
}

impl Default for FfiScrubConfig {
    fn default() -> Self {
        Self {
            enabled_builtin_rules: nookclip_core::algorithms::scrub::default_enabled_rule_keys()
                .into_iter()
                .map(str::to_string)
                .collect(),
            custom_rules: Vec::new(),
            session_ttl_seconds: nookclip_core::algorithms::scrub::DEFAULT_SESSION_TTL_SECONDS,
        }
    }
}

impl From<FfiCustomScrubRule> for algorithms::scrub::CustomScrubRule {
    fn from(r: FfiCustomScrubRule) -> Self {
        Self {
            id: r.id,
            name: r.name,
            is_regex: r.is_regex,
            pattern: r.pattern,
            placeholder_tag: r.placeholder_tag,
            enabled: r.enabled,
        }
    }
}

impl From<FfiScrubConfig> for algorithms::scrub::ScrubConfig {
    fn from(c: FfiScrubConfig) -> Self {
        Self {
            enabled_builtin_rules: c.enabled_builtin_rules,
            custom_rules: c.custom_rules.into_iter().map(Into::into).collect(),
            session_ttl_seconds: c.session_ttl_seconds,
        }
    }
}

/// 外部 NLP 识别出的实体区间（UTF-8 字节偏移）。
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct FfiExternalEntitySpan {
    pub start_byte: u32,
    pub end_byte: u32,
    /// "person_name" 或 "address"
    pub rule_key: String,
}

/// 单个占位符的替换统计。
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct FfiScrubReplacement {
    pub placeholder: String,
    pub rule_key: String,
    pub count: u32,
}

/// 脱敏结果。
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct FfiScrubResult {
    pub scrubbed_text: String,
    pub has_replacements: bool,
    pub replacements: Vec<FfiScrubReplacement>,
    /// 当前会话池活跃映射数（用于设置页展示）
    pub active_vault_count: u32,
}

/// 还原结果。
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct FfiRestoreResult {
    pub restored_text: String,
    pub restored_count: u32,
}

impl From<algorithms::scrub::ScrubResult> for FfiScrubResult {
    fn from(r: algorithms::scrub::ScrubResult) -> Self {
        Self {
            scrubbed_text: r.scrubbed_text,
            has_replacements: r.has_replacements,
            replacements: r
                .replacements
                .into_iter()
                .map(|item| FfiScrubReplacement {
                    placeholder: item.placeholder,
                    rule_key: item.rule_key,
                    count: item.count,
                })
                .collect(),
            active_vault_count: r.active_vault_count,
        }
    }
}

impl From<algorithms::scrub::RestoreResult> for FfiRestoreResult {
    fn from(r: algorithms::scrub::RestoreResult) -> Self {
        Self {
            restored_text: r.restored_text,
            restored_count: r.restored_count,
        }
    }
}

/// 默认启用的内置规则 key 列表（设置页初始化用）。
#[uniffi::export]
pub fn default_enabled_scrub_rules() -> Vec<String> {
    algorithms::scrub::default_enabled_rule_keys()
        .into_iter()
        .map(str::to_string)
        .collect()
}

/// 脱敏：把敏感片段替换为可逆占位符（如 `<EMAIL_1>`）。
///
/// `external_spans` 由 Swift 侧 NLTagger 提供人名 / 地址区间。
#[uniffi::export]
pub fn scrub_sensitive_text(
    text: String,
    config: FfiScrubConfig,
    external_spans: Vec<FfiExternalEntitySpan>,
) -> FfiScrubResult {
    let core_spans: Vec<algorithms::scrub::ExternalEntitySpan> = external_spans
        .into_iter()
        .map(|s| algorithms::scrub::ExternalEntitySpan {
            start_byte: s.start_byte,
            end_byte: s.end_byte,
            rule_key: s.rule_key,
        })
        .collect();
    algorithms::scrub::scrub_text(&text, &config.into(), &core_spans).into()
}

/// 预检结果：命中处数与命中的规则 key。
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct FfiScrubScanResult {
    pub hit_count: u32,
    pub rule_keys: Vec<String>,
}

/// 预检：扫描文本里有多少处敏感片段，**不分配占位符、不写会话池**。
///
/// 供预览区「这条含敏感信息，可按 ⌃⏎ 脱敏粘贴」的提示使用。
#[uniffi::export]
pub fn scan_scrub_text(
    text: String,
    config: FfiScrubConfig,
    external_spans: Vec<FfiExternalEntitySpan>,
) -> FfiScrubScanResult {
    let core_spans: Vec<algorithms::scrub::ExternalEntitySpan> = external_spans
        .into_iter()
        .map(|s| algorithms::scrub::ExternalEntitySpan {
            start_byte: s.start_byte,
            end_byte: s.end_byte,
            rule_key: s.rule_key,
        })
        .collect();
    let result = algorithms::scrub::scan_text(&text, &config.into(), &core_spans);
    FfiScrubScanResult {
        hit_count: result.hit_count,
        rule_keys: result.rule_keys,
    }
}

/// 统计文本中当前仍可还原的占位符个数（会话池未过期）。
#[uniffi::export]
pub fn count_restorable_placeholders(text: String) -> u32 {
    algorithms::scrub::count_restorable_placeholders(&text)
}

/// 还原：把占位符换回真实值；池中不存在的占位符原样保留。
#[uniffi::export]
pub fn restore_scrubbed_text(text: String) -> FfiRestoreResult {
    algorithms::scrub::restore_text(&text).into()
}

/// 清空进程内存中的映射表（设置页「一键清空」）。
#[uniffi::export]
pub fn clear_scrub_session_vault() {
    algorithms::scrub::clear_vault();
}

/// 当前映射表活跃条目数。
#[uniffi::export]
pub fn active_scrub_vault_count() -> u32 {
    algorithms::scrub::active_vault_count()
}

// ---------------------------------------------------------------------------
// 智能表单拆解（Smart Form / Table Bursting）
// ---------------------------------------------------------------------------

/// 智能拆解混合文本为独立表单子项列表（直接供顺序粘贴栈使用）
#[uniffi::export]
pub fn burst_form_text(text: String) -> Vec<String> {
    algorithms::form_burst::burst_form_text(&text)
}

#[uniffi::export]
pub fn should_suggest_form_burst(text: String) -> bool {
    algorithms::form_burst::should_suggest_form_burst(&text)
}

#[uniffi::export]
pub fn detect_form_burst_kind(text: String) -> String {
    algorithms::form_burst::detect_form_burst_kind(&text).to_string()
}
// ---------------------------------------------------------------------------
// 文本差异对比（Inline Diff / `⌘D` 一键对比）
// ---------------------------------------------------------------------------

/// 差异片段类型（与 Rust `DiffTag` 一一对应）
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum FfiDiffTag {
    /// 两侧都有（未改动）
    Equal,
    /// 仅旧版有（会被删除）
    Delete,
    /// 仅新版有（新增）
    Insert,
}

impl From<algorithms::diff::DiffTag> for FfiDiffTag {
    fn from(tag: algorithms::diff::DiffTag) -> Self {
        match tag {
            algorithms::diff::DiffTag::Equal => FfiDiffTag::Equal,
            algorithms::diff::DiffTag::Delete => FfiDiffTag::Delete,
            algorithms::diff::DiffTag::Insert => FfiDiffTag::Insert,
        }
    }
}

/// 行内片段：一段连续同类型的文本
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct FfiDiffSpan {
    pub tag: FfiDiffTag,
    /// 片段原文（拼接全部片段 = 该行原文）
    pub text: String,
    /// true = 行内精确改动的字词（高亮强调）；
    /// false = 未改动的上下文，或整行新增/删除（弱化显示）
    pub emphasized: bool,
}

impl From<algorithms::diff::DiffSpan> for FfiDiffSpan {
    fn from(span: algorithms::diff::DiffSpan) -> Self {
        Self {
            tag: span.tag.into(),
            text: span.text,
            emphasized: span.emphasized,
        }
    }
}

/// 一行差异的渲染数据
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct FfiDiffLine {
    pub tag: FfiDiffTag,
    /// 旧版行号（1 起），0 表示该行不在旧版中
    pub old_line_no: u32,
    /// 新版行号（1 起），0 表示该行不在新版中
    pub new_line_no: u32,
    pub spans: Vec<FfiDiffSpan>,
}

impl From<algorithms::diff::DiffLine> for FfiDiffLine {
    fn from(line: algorithms::diff::DiffLine) -> Self {
        Self {
            tag: line.tag.into(),
            old_line_no: line.old_line_no,
            new_line_no: line.new_line_no,
            spans: line.spans.into_iter().map(Into::into).collect(),
        }
    }
}

/// 差异块（Hunk）：连续的改动，或一段未改动的上下文
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct FfiDiffHunk {
    /// 块序号，从 0 起（合并时按此顺序取选择）
    pub id: u32,
    /// true = 有改动（可选择保留旧版/新版/双方）；false = 未改动的上下文块
    pub is_change: bool,
    /// 旧版起始行号（1 起），0 表示旧版没有对应行
    pub old_line_start: u32,
    /// 新版起始行号（1 起），0 表示新版没有对应行
    pub new_line_start: u32,
    pub old_lines: Vec<String>,
    pub new_lines: Vec<String>,
    /// 逐行渲染数据。契约：改动块填充此字段，未改动上下文块为空数组
    /// （调用方直接用 `new_lines` 平铺渲染，可自行折叠长上下文）
    pub lines: Vec<FfiDiffLine>,
}

impl From<algorithms::diff::DiffHunk> for FfiDiffHunk {
    fn from(hunk: algorithms::diff::DiffHunk) -> Self {
        Self {
            id: hunk.id,
            is_change: hunk.is_change,
            old_line_start: hunk.old_line_start,
            new_line_start: hunk.new_line_start,
            old_lines: hunk.old_lines,
            new_lines: hunk.new_lines,
            lines: hunk.lines.into_iter().map(Into::into).collect(),
        }
    }
}

/// 差异统计摘要（预览区顶部胶囊显示）
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct FfiDiffStats {
    pub added_lines: u32,
    pub removed_lines: u32,
    pub changed_hunks: u32,
    pub added_words: u32,
    pub removed_words: u32,
    /// 相似度千分比（1000 = 完全相同）
    pub similarity_permille: u16,
    /// 两侧文本逐字节相同
    pub is_identical: bool,
    /// 因超出 max_lines 而截断，只对比了前 N 行
    pub is_truncated: bool,
}

impl From<algorithms::diff::DiffStats> for FfiDiffStats {
    fn from(stats: algorithms::diff::DiffStats) -> Self {
        Self {
            added_lines: stats.added_lines,
            removed_lines: stats.removed_lines,
            changed_hunks: stats.changed_hunks,
            added_words: stats.added_words,
            removed_words: stats.removed_words,
            similarity_permille: stats.similarity_permille,
            is_identical: stats.is_identical,
            is_truncated: stats.is_truncated,
        }
    }
}

/// 对比结果
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct FfiTextDiffResult {
    pub hunks: Vec<FfiDiffHunk>,
    pub stats: FfiDiffStats,
}

/// 对比两段文本，返回「差异块 → 行 → 行内片段」三级结构。
///
/// - `ignore_whitespace`：忽略空白差异（缩进、行内多空格、行尾空格都不算改动）
/// - `ignore_case`：忽略大小写差异
/// - `max_lines`：参与对比的最大行数，0 = 用默认值 1500
/// - `max_inline_tokens`：单行内 token 上限，0 = 用默认值 2000
///
/// 返回的 `hunks` 中，未改动上下文块的 `lines` 为空数组（用 `new_lines` 渲染即可）。
#[uniffi::export]
pub fn compute_text_diff(
    old_text: String,
    new_text: String,
    ignore_whitespace: bool,
    ignore_case: bool,
    max_lines: u32,
    max_inline_tokens: u32,
) -> FfiTextDiffResult {
    let options = algorithms::diff::DiffOptions {
        ignore_whitespace,
        ignore_case,
        max_lines,
        max_inline_tokens,
    };
    let result = algorithms::diff::diff_texts(&old_text, &new_text, options);
    FfiTextDiffResult {
        hunks: result.hunks.into_iter().map(Into::into).collect(),
        stats: result.stats.into(),
    }
}

/// 按每个差异块的合并选择拼出完整文本（「一键复制合并版」）。
///
/// `choices` 与 `hunks` 按序号对应：`0` = 保留新版（默认），`1` = 保留旧版，
/// `2` = 两者都保留（旧版在前）；缺省或越界的块按「保留新版」处理。
/// 传空数组即得到纯新版文本，传全 `1` 即得到纯旧版文本。
#[uniffi::export]
pub fn merge_text_diff(
    old_text: String,
    new_text: String,
    ignore_whitespace: bool,
    ignore_case: bool,
    max_lines: u32,
    max_inline_tokens: u32,
    choices: Vec<u8>,
) -> String {
    let options = algorithms::diff::DiffOptions {
        ignore_whitespace,
        ignore_case,
        max_lines,
        max_inline_tokens,
    };
    let result = algorithms::diff::diff_texts(&old_text, &new_text, options);
    algorithms::diff::merge_diff_text(&result.hunks, &choices)
}

// ---------------------------------------------------------------------------
// 粘完即焚（Auto-Burn Clipboard）
// ---------------------------------------------------------------------------

/// 粘完即焚的判定档位（与 Rust `AutoBurnKind` 一一对应）。
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum FfiAutoBurnKind { None, Otp, Secret }

/// 一次「要不要焚」的判定结果（与 Rust `AutoBurnSignal` 一一对应）。
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct FfiAutoBurnSignal {
    /// 判定档位；`None` 时客户端原样粘贴，不做任何焚毁处理
    pub kind: FfiAutoBurnKind,
    /// Otp 时为应写入剪贴板的提纯验证码（如 "482910"）；Secret / None 时为空串
    pub extracted_code: String,
    /// 稳定标识：Otp 固定为 "otp_code"，Secret 为命中规则名（如 "mnemonic_phrase" /
    /// "openai_key"），None 为空。客户端拿它查本地化文案，**不要随意改名**
    pub sensitive_type: Option<String>,
}

impl From<algorithms::auto_burn::AutoBurnSignal> for FfiAutoBurnSignal {
    fn from(signal: algorithms::auto_burn::AutoBurnSignal) -> Self {
        Self {
            kind: match signal.kind {
                algorithms::auto_burn::AutoBurnKind::None => FfiAutoBurnKind::None,
                algorithms::auto_burn::AutoBurnKind::Otp => FfiAutoBurnKind::Otp,
                algorithms::auto_burn::AutoBurnKind::Secret => FfiAutoBurnKind::Secret,
            },
            extracted_code: signal.extracted_code,
            sensitive_type: signal.sensitive_type,
        }
    }
}

/// 判定一段文本要不要「粘完即焚」，并给出粘贴用的提纯验证码。
///
/// 纯判定：不碰剪贴板、不写盘。客户端按 `kind` 决定后续动作：
/// - `None`：原样粘贴，走原有路径；
/// - `Otp`：把 `extracted_code` 写进剪贴板后粘贴，原文不进历史；
/// - `Secret`：原样粘贴后立刻焚掉历史与剪贴板。
#[uniffi::export]
pub fn detect_auto_burn(text: String) -> FfiAutoBurnSignal {
    algorithms::auto_burn::detect_auto_burn(&text).into()
}
