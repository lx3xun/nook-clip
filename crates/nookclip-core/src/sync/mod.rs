pub mod engine;
pub mod pack;
pub mod backend;

pub use engine::SyncEngine;
pub use pack::{DeviceSyncPack, SyncItemRecord};

/// 墓碑保留期（秒）：删除事件在 pack 中携带 7 天，超期不再推送
pub const TOMBSTONE_RETENTION_SECS: f64 = 7.0 * 24.0 * 3600.0;
