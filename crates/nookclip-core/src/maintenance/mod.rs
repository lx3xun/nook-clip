use std::path::Path;

use crate::{
    error::Result,
    model::{MaintenanceConfig, MaintenanceReport},
    storage::{payload_asset::PayloadAssetStore, repository::StorageRepository},
};

pub fn commit_ocr_result(
    repo: &StorageRepository,
    id: &str,
    raw_ocr_text: &str,
) -> Result<Option<String>> {
    repo.update_ocr_text_masked(id, raw_ocr_text)
}

pub fn run_maintenance(
    repo: &StorageRepository,
    config: &MaintenanceConfig,
) -> Result<MaintenanceReport> {
    if let Some(assets_dir) = &config.local_assets_dir {
        if !assets_dir.is_empty() {
            repo.set_assets_dir(Some(assets_dir));
        }
    }
    let mut report = MaintenanceReport::default();
    // 1. 保留期与条数清理
    let pruned_records = repo.prune_expired(&config.retention)?;
    report.pruned_expired_count = pruned_records.len() as u32;
    for r in &pruned_records {
        if let Some(p) = &r.payload_path {
            report.pruned_payload_paths.push(p.clone());
        }
    }

    // 2. 磁盘限额淘汰
    if let (Some(max_bytes), Some(assets_dir)) = (config.max_disk_bytes, &config.local_assets_dir) {
        if max_bytes > 0 && !assets_dir.is_empty() {
            let pruned_disk = repo.enforce_disk_limit(assets_dir, max_bytes)?;
            report.pruned_disk_limit_count = pruned_disk.len() as u32;
            for r in &pruned_disk {
                if let Some(p) = &r.payload_path {
                    report.pruned_payload_paths.push(p.clone());
                }
            }
        }
    }

    // 4. 孤儿文件清扫
    if let Some(assets_dir) = &config.local_assets_dir {
        if !assets_dir.is_empty() && Path::new(assets_dir).exists() {
            let asset_store = PayloadAssetStore::new(assets_dir)?;
            let referenced = repo.all_payload_paths()?;
            let swept = asset_store.sweep_orphans(&referenced, config.orphan_min_age_secs)?;
            report.swept_orphan_files = swept;
        }
    }

    Ok(report)
}
