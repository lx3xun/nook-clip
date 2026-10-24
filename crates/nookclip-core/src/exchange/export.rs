use crate::error::CoreError;
use crate::storage::repository::StorageRepository;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SensitiveExportMode {
    Exclude,
    Masked,
    Plaintext,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BackupExportItem {
    pub id: String,
    pub item_type: String,
    pub title: String,
    pub summary: String,
    pub raw_text: Option<String>,
    pub is_sensitive: bool,
    pub is_favorite: bool,
    pub created_at: f64,
    pub last_used_at: f64,
    pub copy_count: i64,
    #[serde(default)]
    pub tags: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BackupExportRoot {
    pub version: u32,
    pub exported_at: f64,
    pub total_count: usize,
    pub items: Vec<BackupExportItem>,
}

pub fn export_json(
    repo: &StorageRepository,
    mode: SensitiveExportMode,
) -> Result<String, CoreError> {
    let items = repo.export_backup_items(mode)?;
    let root = BackupExportRoot {
        version: 1,
        exported_at: chrono::Utc::now().timestamp_millis() as f64 / 1000.0,
        total_count: items.len(),
        items,
    };
    serde_json::to_string_pretty(&root)
        .map_err(|e| CoreError::InvalidData(format!("JSON export failed: {}", e)))
}

pub fn export_markdown(
    repo: &StorageRepository,
    mode: SensitiveExportMode,
) -> Result<String, CoreError> {
    let items = repo.export_backup_items(mode)?;
    let mut md = String::new();
    md.push_str("# NookClip Clipboard History Export\n\n");
    md.push_str(&format!(
        "Exported at: {}\nTotal items: {}\n\n---\n\n",
        chrono::Utc::now().to_rfc3339(),
        items.len()
    ));

    for item in items {
        md.push_str(&format!("## {}\n", item.title));
        md.push_str(&format!("- **Type**: {}\n", item.item_type));
        md.push_str(&format!("- **Created**: {}\n", item.created_at));
        if item.is_favorite {
            md.push_str("- **Favorite**: yes\n");
        }
        if item.is_sensitive {
            md.push_str("- **Sensitive**: protected\n");
        }
        if !item.tags.is_empty() {
            md.push_str(&format!("  Tags: {}\n", item.tags.join(", ")));
        }
        md.push_str("\n```\n");
        match &item.raw_text {
            Some(text) => md.push_str(text),
            None => md.push_str(&item.summary),
        }
        md.push_str("\n```\n\n---\n\n");
    }

    Ok(md)
}
