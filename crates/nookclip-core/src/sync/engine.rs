use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use crate::error::CoreError;
use crate::storage::payload_asset::PayloadAssetStore;
use crate::storage::repository::StorageRepository;
use crate::sync::backend::{LocalFsBackend, SyncStorageBackend};
use crate::sync::crypto::{decrypt_envelope, encrypt_envelope, is_encrypted_envelope};
use crate::sync::pack::{DeviceSyncPack, SyncItemRecord};
#[derive(Debug, Clone, Default)]
pub struct SyncReport {
    pub pulled_count: u32,
    pub pushed_count: u32,
    pub tombstoned_count: u32,
    pub assets_transferred: u32,
    /// 拉取失败但未中断其余设备的 pack（设备名 + 错误摘要）
    pub failed_packs: Vec<String>,
}

pub struct SyncEngine {
    backend: Box<dyn SyncStorageBackend>,
    device_id: String,
    local_assets_dir: Option<PathBuf>,
    sync_key: Option<[u8; 32]>,
    allow_sensitive: bool,
}

impl SyncEngine {
    pub const MAX_SYNC_ASSET_BYTES: u64 = crate::sync::MAX_SYNC_ASSET_BYTES;

    pub fn new<P: AsRef<Path>>(
        sync_dir: P,
        device_id: String,
        local_assets_dir: Option<PathBuf>,
    ) -> Result<Self, CoreError> {
        let backend = Box::new(LocalFsBackend::new(sync_dir));
        backend.ensure_layout()?;
        Ok(Self {
            backend,
            device_id,
            local_assets_dir,
            sync_key: None,
            allow_sensitive: false,
        })
    }

    pub fn with_backend(
        backend: Box<dyn SyncStorageBackend>,
        device_id: String,
        local_assets_dir: Option<PathBuf>,
    ) -> Result<Self, CoreError> {
        backend.ensure_layout()?;
        Ok(Self {
            backend,
            device_id,
            local_assets_dir,
            sync_key: None,
            allow_sensitive: false,
        })
    }

    pub fn with_encryption(mut self, sync_key: Option<[u8; 32]>, allow_sensitive: bool) -> Self {
        self.sync_key = sync_key;
        self.allow_sensitive = allow_sensitive;
        self
    }

    pub fn set_sync_key(&mut self, sync_key: Option<[u8; 32]>) {
        self.sync_key = sync_key;
    }

    pub fn set_allow_sensitive(&mut self, allow: bool) {
        self.allow_sensitive = allow;
    }

    pub fn pull(&self, repo: &StorageRepository) -> Result<SyncReport, CoreError> {
        if let Some(dir) = &self.local_assets_dir {
            repo.set_assets_dir(Some(dir));
        }
        let mut report = SyncReport::default();
        let pack_metas = self.backend.list_device_packs()?;

        for meta in pack_metas {
            if meta.device_id == self.device_id {
                continue; // Do not pull own pack
            }

            // 增量游标指纹比对：若远端 pack 指纹与本地游标一致，直接跳过下载（0 字节网络传输）
            if let Some(fp) = &meta.fingerprint {
                if let Ok(Some(last_fp)) = repo.get_sync_cursor(&meta.device_id) {
                    if &last_fp == fp {
                        continue;
                    }
                }
            }

            let raw_data = match self.backend.read_device_pack(&meta.device_id) {
                Ok(bytes) => bytes,
                Err(e) => {
                    report.failed_packs.push(format!("{}: {}", meta.device_id, e));
                    continue;
                }
            };

            // 若包含 NCENC1 加密信封，先解密为明文 Zstd 载荷；未设口令时安全报错
            let decompressed_bytes = match decrypt_envelope(&raw_data, self.sync_key.as_ref()) {
                Ok(b) => b,
                Err(e) => {
                    report.failed_packs.push(format!("{}: {}", meta.device_id, e));
                    continue;
                }
            };

            let pack = match DeviceSyncPack::deserialize_compressed(&decompressed_bytes) {
                Ok(p) => p,
                Err(e) => {
                    report.failed_packs.push(format!("{}: {}", meta.device_id, e));
                    continue;
                }
            };
            let items_to_import: Vec<SyncItemRecord> = if self.allow_sensitive {
                pack.items
            } else {
                pack.items.into_iter().filter(|i| !i.is_sensitive).collect()
            };
            let asset_paths = match self.import_pack_assets(&items_to_import, &mut report) {
                Ok(p) => p,
                Err(e) => {
                    report.failed_packs.push(format!("{}: asset import failed: {}", meta.device_id, e));
                    continue;
                }
            };
            match repo.reconcile_sync_items(&items_to_import, &asset_paths) {
                Ok(pulled) => {
                    report.pulled_count += pulled;
                    report.tombstoned_count +=
                        items_to_import.iter().filter(|i| i.deleted_at.is_some()).count() as u32;
                    if let Some(fp) = &meta.fingerprint {
                        let _ = repo.set_sync_cursor(&meta.device_id, fp);
                    }
                }
                Err(e) => {
                    report.failed_packs.push(format!("{}: {}", meta.device_id, e));
                }
            }
        }

        Ok(report)
    }

    pub fn push(&self, repo: &StorageRepository) -> Result<SyncReport, CoreError> {
        if self.allow_sensitive && self.sync_key.is_none() {
            return Err(CoreError::Crypto("Cannot sync sensitive items without encryption key".into()));
        }
        if let Some(dir) = &self.local_assets_dir {
            repo.set_assets_dir(Some(dir));
        }
        let items: Vec<SyncItemRecord> = repo.export_sync_items_ext(
            self.local_assets_dir.as_deref().and_then(|p| p.to_str()),
            self.allow_sensitive,
            Some(500),
        )?;
        let count = items.len() as u32;
        let tombstoned = items.iter().filter(|i| i.deleted_at.is_some()).count() as u32;
        let mut report = SyncReport {
            pushed_count: count,
            tombstoned_count: tombstoned,
            ..Default::default()
        };
        self.upload_pack_assets(&items, &mut report)?;
        let pack = DeviceSyncPack::new(self.device_id.clone(), items);
        let compressed = pack.serialize_compressed()?;
        let final_payload = if let Some(key) = &self.sync_key {
            encrypt_envelope(&compressed, key)?
        } else {
            compressed
        };

        self.backend.write_device_pack_atomic(&self.device_id, &final_payload)?;
        Ok(report)
    }

    pub fn sync_now(&self, repo: &StorageRepository) -> Result<SyncReport, CoreError> {
        let pull_report = self.pull(repo)?;
        let push_report = self.push(repo)?;
        Ok(SyncReport {
            pulled_count: pull_report.pulled_count,
            pushed_count: push_report.pushed_count,
            tombstoned_count: pull_report.tombstoned_count + push_report.tombstoned_count,
            assets_transferred: pull_report.assets_transferred + push_report.assets_transferred,
            failed_packs: pull_report.failed_packs,
        })
    }

    fn upload_pack_assets(
        &self,
        items: &[SyncItemRecord],
        report: &mut SyncReport,
    ) -> Result<(), CoreError> {
        let Some(assets_dir) = self.local_assets_dir.as_deref() else {
            return Ok(());
        };
        let mut remote_assets = self.backend.list_assets()?;
        for item in items {
            let Some(name) = safe_asset_name(item.asset_file_name.as_deref()) else {
                continue;
            };
            if remote_assets.contains(&name) {
                continue;
            }
            let source = assets_dir.join(&name);
            let Ok(meta) = fs::metadata(&source) else {
                continue;
            };
            if meta.len() > crate::sync::MAX_SYNC_ASSET_BYTES {
                continue;
            }
            let data = match fs::read(&source) {
                Ok(d) => d,
                Err(_) => continue,
            };
            let payload_to_upload = if let Some(key) = &self.sync_key {
                encrypt_envelope(&data, key)?
            } else {
                data
            };
            self.backend.write_asset_atomic(&name, &payload_to_upload)?;
            remote_assets.insert(name);
            report.assets_transferred += 1;
        }
        Ok(())
    }

    fn import_pack_assets(
        &self,
        items: &[SyncItemRecord],
        report: &mut SyncReport,
    ) -> Result<HashMap<String, String>, CoreError> {
        let mut paths = HashMap::new();
        let Some(assets_dir) = self.local_assets_dir.as_deref() else {
            return Ok(paths);
        };
        let store = PayloadAssetStore::new(assets_dir)?;
        for item in items {
            let Some(name) = safe_asset_name(item.asset_file_name.as_deref()) else {
                continue;
            };
            let existing = assets_dir.join(&name);
            if existing.exists() {
                paths.insert(item.id.clone(), existing.to_string_lossy().to_string());
                continue;
            }
            let raw_data = self.backend.read_asset(&name)?;
            let data = if is_encrypted_envelope(&raw_data) {
                decrypt_envelope(&raw_data, self.sync_key.as_ref())?
            } else {
                raw_data
            };
            let ext = Path::new(&name)
                .extension()
                .and_then(|e| e.to_str())
                .unwrap_or("");
            let local_path = store.save_payload_asset(&data, ext)?;
            paths.insert(item.id.clone(), local_path);
            report.assets_transferred += 1;
        }
        Ok(paths)
    }
}

fn safe_asset_name(name: Option<&str>) -> Option<String> {
    let name = name?;
    if name.is_empty()
        || name.contains('/')
        || name.contains('\\')
        || name.contains("..")
        || name.starts_with('.')
    {
        return None;
    }
    Some(name.to_string())
}
