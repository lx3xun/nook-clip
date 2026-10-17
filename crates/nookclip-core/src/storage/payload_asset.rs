use crate::error::CoreError;
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

/// Stores binary content and large text on disk separately from database metadata.
#[derive(Debug, Clone)]
pub struct PayloadAssetStore {
    root_dir: PathBuf,
}

impl PayloadAssetStore {
    pub fn new<P: AsRef<Path>>(root_dir: P) -> Result<Self, CoreError> {
        let path = root_dir.as_ref().to_path_buf();
        fs::create_dir_all(&path)?;
        Ok(Self { root_dir: path })
    }

    /// 提取受管载荷的相对文件名（若路径位于 `assets_dir` 下，或本身即为纯文件名）。
    /// 外部绝对路径（如用户复制的本地文件）返回原值。
    pub fn normalize_for_storage(
        item_type: &str,
        payload_path: Option<&str>,
        assets_dir: Option<&Path>,
    ) -> Option<String> {
        let raw = payload_path?;
        if raw.is_empty() || item_type == "file" {
            return Some(raw.to_string());
        }
        // 若本身不包含路径分隔符（已是纯文件名），直接返回
        if !raw.contains('/') && !raw.contains('\\') {
            return Some(raw.to_string());
        }
        let path = Path::new(raw);
        if let Some(dir) = assets_dir {
            if path.starts_with(dir) {
                if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
                    return Some(name.to_string());
                }
            }
        }
        // 对于受管载荷（image 或带 .rtf 伴生载荷的 text），若文件名符合 sha256 内容寻址格式，也归一化为纯文件名
        if item_type == "image" || raw.to_ascii_lowercase().ends_with(".rtf") {
            if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
                let stem = Path::new(name)
                    .file_stem()
                    .and_then(|s| s.to_str())
                    .unwrap_or(name);
                if stem.len() == 64 && stem.chars().all(|c| c.is_ascii_hexdigit()) {
                    return Some(name.to_string());
                }
            }
        }
        Some(raw.to_string())
    }

    /// 将数据库内存储的相对文件名（或历史遗留的旧容器绝对路径）解析为当前运行时的可用绝对路径。
    pub fn resolve_for_runtime(
        item_type: &str,
        stored_path: Option<&str>,
        assets_dir: Option<&Path>,
    ) -> Option<String> {
        let raw = stored_path?;
        if raw.is_empty() || item_type == "file" {
            return Some(raw.to_string());
        }
        let Some(dir) = assets_dir else {
            return Some(raw.to_string());
        };
        if !raw.contains('/') && !raw.contains('\\') {
            return Some(dir.join(raw).to_string_lossy().to_string());
        }
        let path = Path::new(raw);
        if path.starts_with(dir) || path.exists() {
            return Some(raw.to_string());
        }
        // 沙盒容器 UUID 漂移或目录迁移自愈：若原绝对路径不存在，但当前 assets_dir 下有同名文件，则重定向到新目录
        if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
            let candidate = dir.join(name);
            if candidate.exists() {
                return Some(candidate.to_string_lossy().to_string());
            }
        }
        Some(raw.to_string())
    }

    /// Computes SHA-256 of data and atomically writes to `<root_dir>/<sha256>.<ext>`.
    /// Returns the absolute path of the stored payload asset.
    pub fn save_payload_asset(
        &self,
        data: &[u8],
        preferred_extension: &str,
    ) -> Result<String, CoreError> {
        let hash = format!("{:x}", Sha256::digest(data));
        // Sanitize extension: remove leading dot and any path traversal or separator characters
        let raw_ext = preferred_extension.trim_start_matches('.');
        let sanitized_ext: String = raw_ext
            .chars()
            .filter(|c| c.is_alphanumeric())
            .collect();
        let filename = if sanitized_ext.is_empty() {
            hash
        } else {
            format!("{}.{}", hash, sanitized_ext)
        };
        let target_path = self.root_dir.join(&filename);

        if target_path.exists() {
            return Ok(target_path.to_string_lossy().to_string());
        }

        let temp_filename = format!("{}.tmp.{}", filename, uuid::Uuid::new_v4());
        let temp_path = self.root_dir.join(temp_filename);
        fs::write(&temp_path, data)?;
        fs::rename(&temp_path, &target_path)?;

        Ok(target_path.to_string_lossy().to_string())
    }

    /// Sweeps files in root_dir not in referenced_filenames that were modified before threshold.
    pub fn sweep_orphans(
        &self,
        referenced_filenames: &[String],
        older_than_seconds: f64,
    ) -> Result<u32, CoreError> {
        let mut swept = 0;
        let now = SystemTime::now();
        // Normalize referenced filenames by extracting file_name from absolute or relative paths
        let ref_set: std::collections::HashSet<String> = referenced_filenames
            .iter()
            .filter_map(|s| {
                s.trim_end_matches(&['/', '\\'][..])
                    .rsplit(&['/', '\\'][..])
                    .next()
                    .filter(|n| !n.is_empty())
                    .map(|n| n.to_string())
            })
            .collect();

        let entries = fs::read_dir(&self.root_dir)?;
        for entry in entries.flatten() {
            let path = entry.path();
            if !path.is_file() {
                continue;
            }
            let file_name = path
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or_default();
            if ref_set.contains(file_name) {
                continue;
            }
            if let Ok(metadata) = entry.metadata() {
                if let Ok(modified) = metadata.modified() {
                    if let Ok(age) = now.duration_since(modified) {
                        if age.as_secs_f64() >= older_than_seconds
                            && fs::remove_file(&path).is_ok()
                        {
                            swept += 1;
                        }
                    }
                }
            }
        }
        Ok(swept)
    }
}
