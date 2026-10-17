#[derive(Clone, Debug, PartialEq, Default)]
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
    pub kind: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ClipItemDetail {
    pub id: String,
    pub raw_text: Option<String>,
    pub ocr_text: Option<String>,
    pub metadata_json: Option<String>,
    pub is_sensitive: bool,
}

#[derive(Clone, Debug, Default)]
pub struct QueryFilter {
    /// 按 id 精确取单条（主键索引）：内存列表只载入 summary 前缀时，
    /// 粘贴/预览/回存经此取回全文
    pub id: Option<String>,
    pub search_query: Option<String>,
    pub item_type: Option<String>,
    pub kind: Option<String>,
    pub favorite_only: bool,
    pub include_deleted: bool,
    pub limit: u32,
    pub offset: u32,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
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

#[derive(Clone, Debug, Default)]
pub struct RetentionConfig {
    pub max_age_days: Option<u32>,
    pub max_item_count: Option<u32>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct PrunedItemRecord {
    pub id: String,
    pub payload_path: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct DetectionResult {
    pub is_sensitive: bool,
    pub sensitive_type: Option<String>,
    pub detected_language: Option<String>,
    pub is_code: bool,
    pub detected_color_hex: Option<String>,
    pub has_email: bool,
    pub is_url: bool,
}
// === 1. Pipeline & Timeline ===

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum TimeBucketKey {
    Today,
    Yesterday,
    ThisWeek,
    LastWeek,
    Month { year: i32, month: u32 },
    Year { year: i32 },
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CalendarContext {
    pub now_ts: f64,
    pub tz_offset_secs: i32,
    pub first_weekday: u8,
}

impl Default for CalendarContext {
    fn default() -> Self {
        Self {
            now_ts: 0.0,
            tz_offset_secs: 0,
            first_weekday: 1,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TimeGroupSummary {
    pub id: String,
    pub bucket: TimeBucketKey,
    pub count: u32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct TimeGroupSection {
    pub id: String,
    pub bucket: TimeBucketKey,
    pub items: Vec<ClipItemSummary>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct QueryViewSnapshot {
    pub items: Vec<ClipItemSummary>,
    pub groups: Vec<TimeGroupSection>,
    pub timeline_anchors: Vec<TimeGroupSummary>,
    pub category_counts: CategoryCounts,
    pub search_keywords: Vec<String>,
    pub has_more: bool,
}

// === 2. Maintenance ===

#[derive(Clone, Debug, Default)]
pub struct MaintenanceConfig {
    pub retention: RetentionConfig,
    pub max_disk_bytes: Option<u64>,
    pub orphan_min_age_secs: f64,
    pub local_assets_dir: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct MaintenanceReport {
    pub pruned_expired_count: u32,
    pub pruned_disk_limit_count: u32,
    pub swept_orphan_files: u32,
    pub purged_blank_count: u32,
    pub pruned_payload_paths: Vec<String>,
}

// === 3. Clipboard Ingest & Egress ===

#[derive(Clone, Debug, Default, PartialEq)]
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

#[derive(Clone, Debug)]
pub struct IngestConfig {
    pub sensitive_protection_enabled: bool,
    pub excluded_bundle_ids: Vec<String>,
    pub local_assets_dir: String,
    pub file_multi_title_template: Option<String>,
    pub default_image_title: String,
}

#[derive(Clone, Debug, PartialEq)]
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

#[derive(Clone, Debug, PartialEq)]
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

// === 4. Sync Backend ===

#[derive(Clone, Debug, PartialEq, Eq)]
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
