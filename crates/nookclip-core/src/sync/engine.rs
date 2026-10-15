use crate::error::CoreError;
use crate::storage::payload_asset::PayloadAssetStore;
use crate::storage::repository::StorageRepository;
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
    sync_dir: PathBuf,
    device_id: String,
    /// 本地受管载荷目录（content-addressed）：push 时上传到云端 assets/，
    /// pull 时导入云端资产。None 时禁用附件池（纯元数据同步）。
    local_assets_dir: Option<PathBuf>,
}

impl SyncEngine {
    pub fn new<P: AsRef<Path>>(
        sync_dir: P,
        device_id: String,
        local_assets_dir: Option<PathBuf>,
    ) -> Result<Self, CoreError> {
        let path = sync_dir.as_ref().to_path_buf();
        fs::create_dir_all(path.join("devices"))?;
        fs::create_dir_all(path.join("assets"))?;
        Ok(Self {
            sync_dir: path,
            device_id,
            local_assets_dir,
        })
    }

    pub fn pull(&self, repo: &StorageRepository) -> Result<SyncReport, CoreError> {
        let mut report = SyncReport::default();
        let devices_dir = self.sync_dir.join("devices");
        if !devices_dir.exists() {
            return Ok(report);
        }

        let entries = fs::read_dir(devices_dir)?;
        for entry in entries.flatten() {
            let path = entry.path();
            if let Ok(file_type) = entry.file_type() {
                if !file_type.is_file() {
                    continue;
                }
            }
            if path.extension().and_then(|e| e.to_str()) != Some("pack") {
                continue;
            }
            let file_stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("");
            if file_stem == self.device_id {
                continue; // Do not pull own pack
            }

            let data = match fs::read(&path) {
                Ok(bytes) => bytes,
                Err(e) => {
                    report.failed_packs.push(format!("{}: {}", file_stem, e));
                    continue;
                }
            };
            let pack = match DeviceSyncPack::deserialize_compressed(&data) {
                Ok(p) => p,
                Err(e) => {
                    report
                        .failed_packs
                        .push(format!("{}: {}", file_stem, e));
                    continue;
                }
            };
            // 附件池：先导入云端资产得到「条目 id → 本地载荷路径」映射，再落库
            let asset_paths = self.import_pack_assets(&pack.items, &mut report)?;
            match repo.reconcile_sync_items(&pack.items, &asset_paths) {
                Ok(pulled) => {
                    report.pulled_count += pulled;
                    report.tombstoned_count +=
                        pack.items.iter().filter(|i| i.deleted_at.is_some()).count() as u32;
                }
                Err(e) => {
                    report
                        .failed_packs
                        .push(format!("{}: {}", file_stem, e));
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

        let target_filename = format!("{}.pack", self.device_id);
        let target_path = self.sync_dir.join("devices").join(&target_filename);
        let temp_filename = format!("{}.tmp.{}", target_filename, uuid::Uuid::new_v4());
        let temp_path = self.sync_dir.join("devices").join(temp_filename);

        fs::write(&temp_path, compressed)?;
        fs::rename(&temp_path, &target_path)?;

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

    /// 单附件云端同步体积上限（PRD §4.6 / 设置页承诺：单张图片 ≤ 2MB）
    pub const MAX_SYNC_ASSET_BYTES: u64 = 2 * 1024 * 1024;

    /// 把本地受管载荷上传到云端 assets/ 池（content-addressed，已存在即跳过，单张 ≤ 2MB）。
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
            let target = self.sync_dir.join("assets").join(&name);
            if target.exists() {
                continue; // content-addressed：同名即同内容
            }
            let Ok(meta) = fs::metadata(&source) else {
                continue; // 本地载荷缺失（被孤儿清理等）不阻塞 pack 推送
            };
            if meta.len() > Self::MAX_SYNC_ASSET_BYTES {
                continue; // 超过 2MB 上限的本地资产不同步上云
            }
            let data = match fs::read(&source) {
                Ok(d) => d,
                Err(_) => continue,
            };
            let temp = self
                .sync_dir
                .join("assets")
                .join(format!("{}.tmp.{}", name, uuid::Uuid::new_v4()));
            fs::write(&temp, data)?;
            fs::rename(&temp, &target)?;
            report.assets_transferred += 1;
        }
        Ok(())
    }

    /// 从云端 assets/ 池导入远端载荷到本地受管目录（SHA-256 校验去重），
    /// 返回「条目 id → 本地载荷绝对路径」。云端资产缺失的条目跳过导入。
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
            let cloud_path = self.sync_dir.join("assets").join(&name);
            let data = match fs::read(&cloud_path) {
                Ok(d) => d,
                Err(_) => continue, // 云端资产缺失：仅同步元数据，不阻塞
            };
            let ext = Path::new(&name)
                .extension()
                .and_then(|e| e.to_str())
                .unwrap_or("");
            // 重新按内容寻址落盘：云端文件名与内容哈希不符时以内容为准
            let local_path = store.save_payload_asset(&data, ext)?;
            paths.insert(item.id.clone(), local_path);
            report.assets_transferred += 1;
        }
        Ok(paths)
    }
}

/// 云端文件名防路径穿越：只允许纯文件名（无分隔符、无 ..）。
/// 内容寻址格式为 <sha256>.<ext>，全部由本地 PayloadAssetStore 生成。
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
