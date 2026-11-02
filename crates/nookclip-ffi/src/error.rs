//! FFI 错误枚举与 CoreError 转换。
//! 独立模块仅做物理拆分；类型仍是 crate 根导出（pub use），
//! uniffi 的宏注册按类型名进行，位置无关。

use nookclip_core::CoreError;

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
