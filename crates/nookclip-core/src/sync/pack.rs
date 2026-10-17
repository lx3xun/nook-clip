use crate::error::CoreError;
use serde::{Deserialize, Serialize};

/// pack 格式版本：v2 引入 updated_at/copy_count/asset_file_name；
/// v3 引入 source_app_bundle_id/source_app_name/source_device_id/source_device_name/source_platform。
/// 兼容 v2 与 v3 包反序列化。
pub const SYNC_PACK_SCHEMA_VERSION: u32 = 3;
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SyncItemRecord {
    pub id: String,
    pub item_type: String,
    pub title: String,
    pub summary: String,
    pub raw_text: Option<String>,
    pub is_sensitive: bool,
    pub is_favorite: bool,
    pub created_at: f64,
    pub last_used_at: f64,
    /// 元数据 LWW 判新时间戳（data-model §3）：收藏/标题等以它为准
    pub updated_at: f64,
    /// 合并规则 copy_count = max(local, remote)
    pub copy_count: i64,
    /// 云端附件池文件名（content-addressed，<sha256>.<ext>）；
    /// None 表示无二进制载荷（纯文本或载荷不随同步）
    pub asset_file_name: Option<String>,
    pub deleted_at: Option<f64>,
    #[serde(default)]
    pub source_app_bundle_id: Option<String>,
    #[serde(default)]
    pub source_app_name: Option<String>,
    #[serde(default)]
    pub source_device_id: Option<String>,
    #[serde(default)]
    pub source_device_name: Option<String>,
    #[serde(default)]
    pub source_platform: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DeviceSyncPack {
    pub schema_version: u32,
    pub device_id: String,
    pub generated_at: f64,
    pub items: Vec<SyncItemRecord>,
}

impl DeviceSyncPack {
    pub fn new(device_id: String, items: Vec<SyncItemRecord>) -> Self {
        let now = chrono::Utc::now().timestamp_millis() as f64 / 1000.0;
        Self {
            schema_version: SYNC_PACK_SCHEMA_VERSION,
            device_id,
            generated_at: now,
            items,
        }
    }

    pub fn serialize_compressed(&self) -> Result<Vec<u8>, CoreError> {
        let packed = rmp_serde::to_vec_named(self)
            .map_err(|e| CoreError::InvalidData(format!("MsgPack pack failed: {}", e)))?;
        zstd::encode_all(&packed[..], 3)
            .map_err(|e| CoreError::InvalidData(format!("Zstd compression failed: {}", e)))
    }

    pub fn deserialize_compressed(data: &[u8]) -> Result<Self, CoreError> {
        // Enforce 64 MB maximum decompressed size limit against decompression bombs
        const MAX_DECOMPRESSED_SIZE: u64 = 64 * 1024 * 1024;
        let mut decoder = zstd::Decoder::new(data)
            .map_err(|e| CoreError::InvalidData(format!("Zstd decoder init failed: {}", e)))?;
        let mut limited = std::io::Read::take(&mut decoder, MAX_DECOMPRESSED_SIZE + 1);
        let mut decompressed = Vec::new();
        std::io::Read::read_to_end(&mut limited, &mut decompressed)
            .map_err(|e| CoreError::InvalidData(format!("Zstd decompression failed: {}", e)))?;

        if decompressed.len() as u64 > MAX_DECOMPRESSED_SIZE {
            return Err(CoreError::InvalidData("Decompressed sync pack exceeds 64MB limit".to_string()));
        }

        let pack: Self = rmp_serde::from_slice(&decompressed)
            .map_err(|e| CoreError::InvalidData(format!("MsgPack unpack failed: {}", e)))?;
        if pack.schema_version != SYNC_PACK_SCHEMA_VERSION && pack.schema_version != 2 {
            return Err(CoreError::InvalidData(format!("Unsupported sync pack schema version: {}", pack.schema_version)));
        }
        Ok(pack)
    }
}
