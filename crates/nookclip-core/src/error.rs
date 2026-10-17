use thiserror::Error;

#[derive(Error, Debug)]
pub enum CoreError {
    #[error("Database error: {0}")]
    Database(#[from] rusqlite::Error),
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Item not found: {0}")]
    NotFound(String),

    #[error("Crypto error: {0}")]
    Crypto(String),

    #[error("Serialization error: {0}")]
    Serialization(String),
    #[error("Invalid data: {0}")]
    InvalidData(String),

    #[error("Invalid argument: {0}")]
    InvalidArgument(String),
    #[error("Missing referenced files: {missing_paths:?}")]
    StaleFiles { missing_paths: Vec<String> },
    #[error("Image payload is missing or unreadable")]
    CorruptedImagePayload,
    #[error("Failed to decrypt sensitive content")]
    DecryptionFailed,
    #[error("Sync transport error: {0}")]
    SyncTransport(String),
}
pub type Result<T, E = CoreError> = std::result::Result<T, E>;
