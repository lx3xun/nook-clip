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
