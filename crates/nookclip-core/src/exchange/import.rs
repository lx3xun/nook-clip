use crate::error::CoreError;
use crate::exchange::export::BackupExportRoot;
use crate::storage::repository::StorageRepository;

#[derive(Debug, Clone, Default)]
pub struct ImportReport {
    pub imported_count: u32,
    pub skipped_duplicates: u32,
    /// Masked 备份中以掩码字面量为正文的敏感条目（无法还原，跳过导入）
    pub skipped_masked: u32,
}

pub fn import_json(
    repo: &StorageRepository,
    json_content: &str,
) -> Result<ImportReport, CoreError> {
    let root: BackupExportRoot = serde_json::from_str(json_content)
        .map_err(|e| CoreError::InvalidData(format!("Invalid JSON backup: {}", e)))?;

    repo.import_backup_items(&root.items)
}
