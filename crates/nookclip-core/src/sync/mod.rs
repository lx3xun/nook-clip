pub mod backend;
pub mod crypto;
pub mod engine;
pub mod pack;

pub use backend::{LocalFsBackend, RemotePackMeta, SyncStorageBackend, WebDavBackend};
pub use crypto::{
    create_manifest, decrypt_envelope, derive_sync_key, encrypt_envelope, is_encrypted_envelope,
    verify_manifest, SyncManifest, ENVELOPE_MAGIC,
};
pub use engine::{SyncEngine, SyncReport};
pub use pack::{DeviceSyncPack, SyncItemRecord, SYNC_PACK_SCHEMA_VERSION};

/// 墓碑保留期（秒）：删除事件在 pack 中携带 7 天，超期不再推送
pub const TOMBSTONE_RETENTION_SECS: f64 = 7.0 * 24.0 * 3600.0;

/// 跨设备单张同步图片/载荷体积上限（5 MB）：超限载荷仅保留本机，避免阻塞网络
pub const MAX_SYNC_ASSET_BYTES: u64 = 5 * 1024 * 1024;
