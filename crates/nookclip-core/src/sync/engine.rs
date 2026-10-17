use crate::error::CoreError;
use crate::storage::payload_asset::PayloadAssetStore;
use crate::storage::repository::StorageRepository;
use crate::sync::backend::{LocalFsBackend, SyncStorageBackend};
use crate::sync::pack::{DeviceSyncPack, SyncItemRecord};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

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
}

impl SyncEngine {
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
        })
    }

    pub fn pull(&self, repo: &StorageRepository) -> Result<SyncReport, CoreError> {
        let mut report = SyncReport::default();
        let pack_ids = self.backend.list_device_packs()?;

        for file_stem in pack_ids {
            if file_stem == self.device_id {
                continue; // Do not pull own pack
            }

            let data = match self.backend.read_device_pack(&file_stem) {
                Ok(bytes) => bytes,
                Err(e) => {
                    report.failed_packs.push(format!("{}: {}", file_stem, e));
                    continue;
                }
            };
            let pack = match DeviceSyncPack::deserialize_compressed(&data) {
                Ok(p) => p,
                Err(e) => {
                    report.failed_packs.push(format!("{}: {}", file_stem, e));
                    continue;
                }
            };

            let asset_paths = self.import_pack_assets(&pack.items, &mut report)?;
            match repo.reconcile_sync_items(&pack.items, &asset_paths) {
                Ok(pulled) => {
                    report.pulled_count += pulled;
                    report.tombstoned_count +=
                        pack.items.iter().filter(|i| i.deleted_at.is_some()).count() as u32;
                }
                Err(e) => {
                    report.failed_packs.push(format!("{}: {}", file_stem, e));
                }
            }
        }

        Ok(report)
    }

    pub fn push(&self, repo: &StorageRepository) -> Result<SyncReport, CoreError> {
        let items: Vec<SyncItemRecord> =
            repo.export_sync_items(self.local_assets_dir.as_deref().and_then(|p| p.to_str()))?;
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

        self.backend.write_device_pack_atomic(&self.device_id, &compressed)?;

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

    pub const MAX_SYNC_ASSET_BYTES: u64 = 2 * 1024 * 1024;

    fn upload_pack_assets(
        &self,
        items: &[SyncItemRecord],
        report: &mut SyncReport,
    ) -> Result<(), CoreError> {
        let Some(assets_dir) = self.local_assets_dir.as_deref() else {
            return Ok(());
        };
        for item in items {
            let Some(name) = safe_asset_name(item.asset_file_name.as_deref()) else {
                continue;
            };
            let source = assets_dir.join(&name);
            let Ok(meta) = fs::metadata(&source) else {
                continue;
            };
            if meta.len() > Self::MAX_SYNC_ASSET_BYTES {
                continue;
            }
            if self.backend.has_asset(&name)? {
                continue;
            }
            let data = match fs::read(&source) {
                Ok(d) => d,
                Err(_) => continue,
            };
            self.backend.write_asset_atomic(&name, &data)?;
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
            let data = match self.backend.read_asset(&name) {
                Ok(d) => d,
                Err(_) => continue,
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
