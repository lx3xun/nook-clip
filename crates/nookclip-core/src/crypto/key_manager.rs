use crate::error::{CoreError, Result};
use rand::RngCore;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum KeyVaultReadStatus {
    Found { key_bytes: Vec<u8> },
    Missing,
    Unavailable { error_code: i32 },
}

pub trait KeyVaultBackupProvider: Send + Sync {
    fn read_backup_key(&self) -> KeyVaultReadStatus;
    fn write_backup_key(&self, key_bytes: Vec<u8>) -> bool;
}

pub struct MasterKeyManager {
    key_file_path: PathBuf,
    initialized_marker_path: PathBuf,
}

impl MasterKeyManager {
    pub fn new<P: AsRef<Path>>(key_file_path: P) -> Self {
        let key_path = key_file_path.as_ref().to_path_buf();
        let parent = key_path.parent().unwrap_or_else(|| Path::new("."));
        let marker = parent.join(".master_key.initialized");
        Self {
            key_file_path: key_path,
            initialized_marker_path: marker,
        }
    }

    pub fn key_file_path(&self) -> &Path {
        &self.key_file_path
    }

    pub fn is_marked_initialized(&self) -> bool {
        self.initialized_marker_path.exists()
    }

    pub fn mark_initialized(&self) -> Result<()> {
        if let Some(parent) = self.initialized_marker_path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(&self.initialized_marker_path, b"initialized\n")?;
        Ok(())
    }

    fn read_key_from_file(&self) -> Option<[u8; 32]> {
        let data = fs::read(&self.key_file_path).ok()?;
        if data.len() == 32 {
            let mut key = [0u8; 32];
            key.copy_from_slice(&data);
            Some(key)
        } else {
            None
        }
    }

    fn write_key_to_file(&self, key: &[u8; 32]) -> Result<()> {
        if let Some(parent) = self.key_file_path.parent() {
            fs::create_dir_all(parent)?;
        }
        let temp_path = self.key_file_path.with_extension(format!("tmp.{}", uuid::Uuid::new_v4()));

        #[cfg(unix)]
        {
            use std::io::Write;
            use std::os::unix::fs::OpenOptionsExt;
            let mut file = fs::OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(true)
                .mode(0o600)
                .open(&temp_path)?;
            file.write_all(key)?;
            file.sync_all()?;
        }

        #[cfg(not(unix))]
        {
            fs::write(&temp_path, key)?;
        }

        fs::rename(&temp_path, &self.key_file_path)?;
        Ok(())
    }

    pub fn resolve_or_create_key(
        &self,
        vault_provider: &dyn KeyVaultBackupProvider,
        legacy_initialized: bool,
        has_encrypted_payloads: bool,
    ) -> Result<[u8; 32]> {
        // 1. 本地受控文件存在即用：零弹窗
        if let Some(key) = self.read_key_from_file() {
            let _ = self.mark_initialized();
            return Ok(key);
        }

        // 判定历史是否已初始化（包含本地密钥文件已存在但异常损坏的情况）
        let was_initialized = legacy_initialized
            || self.is_marked_initialized()
            || has_encrypted_payloads
            || self.key_file_path.exists();

        // 2. 本地文件缺失或损坏，尝试从钥匙串读取
        match vault_provider.read_backup_key() {
            KeyVaultReadStatus::Found { key_bytes } => {
                if key_bytes.len() != 32 {
                    return Err(CoreError::Crypto(format!(
                        "KeyVault backup key invalid length: expected 32, got {}",
                        key_bytes.len()
                    )));
                }
                let mut key = [0u8; 32];
                key.copy_from_slice(&key_bytes);
                self.write_key_to_file(&key)?;
                let _ = self.mark_initialized();
                Ok(key)
            }
            KeyVaultReadStatus::Unavailable { error_code } => {
                Err(CoreError::Crypto(format!(
                    "KeyVault backup unavailable (status {error_code}); refusing to replace master key"
                )))
            }
            KeyVaultReadStatus::Missing => {
                if was_initialized {
                    return Err(CoreError::Crypto(
                        "Previously initialized master key missing from both file and KeyVault; refusing to regenerate".to_string(),
                    ));
                }

                // 全新安装：生成新密钥
                let mut new_key = [0u8; 32];
                rand::thread_rng().fill_bytes(&mut new_key);
                self.write_key_to_file(&new_key)?;
                let _ = vault_provider.write_backup_key(new_key.to_vec());
                let _ = self.mark_initialized();
                Ok(new_key)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use parking_lot::Mutex;
    use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
    use tempfile::tempdir;

    struct MockKeyVault {
        read_status: KeyVaultReadStatus,
        read_count: AtomicU32,
        written_key: Mutex<Option<Vec<u8>>>,
        write_success: AtomicBool,
    }

    impl MockKeyVault {
        fn new(read_status: KeyVaultReadStatus) -> Self {
            Self {
                read_status,
                read_count: AtomicU32::new(0),
                written_key: Mutex::new(None),
                write_success: AtomicBool::new(true),
            }
        }
    }

    impl KeyVaultBackupProvider for MockKeyVault {
        fn read_backup_key(&self) -> KeyVaultReadStatus {
            self.read_count.fetch_add(1, Ordering::SeqCst);
            self.read_status.clone()
        }

        fn write_backup_key(&self, key_bytes: Vec<u8>) -> bool {
            *self.written_key.lock() = Some(key_bytes);
            self.write_success.load(Ordering::SeqCst)
        }
    }

    #[test]
    fn test_valid_file_exists_zero_keyvault_read() {
        let dir = tempdir().unwrap();
        let key_file = dir.path().join("master.key");
        let expected_key = [7u8; 32];
        fs::write(&key_file, expected_key).unwrap();

        let manager = MasterKeyManager::new(&key_file);
        let vault = MockKeyVault::new(KeyVaultReadStatus::Missing);

        let resolved = manager.resolve_or_create_key(&vault, false, false).unwrap();
        assert_eq!(resolved, expected_key);
        assert_eq!(vault.read_count.load(Ordering::SeqCst), 0, "本地文件存在时不触碰钥匙串");
        assert!(manager.is_marked_initialized());
    }

    #[test]
    fn test_file_missing_restored_from_vault_backup() {
        let dir = tempdir().unwrap();
        let key_file = dir.path().join("master.key");
        let backup_key = [9u8; 32];
        let manager = MasterKeyManager::new(&key_file);
        let vault = MockKeyVault::new(KeyVaultReadStatus::Found { key_bytes: backup_key.to_vec() });

        let resolved = manager.resolve_or_create_key(&vault, false, false).unwrap();
        assert_eq!(resolved, backup_key);
        assert_eq!(vault.read_count.load(Ordering::SeqCst), 1);
        assert_eq!(fs::read(&key_file).unwrap(), backup_key);
        assert!(manager.is_marked_initialized());
    }

    #[test]
    fn test_file_missing_vault_unavailable_refuses_to_replace() {
        let dir = tempdir().unwrap();
        let key_file = dir.path().join("master.key");
        let manager = MasterKeyManager::new(&key_file);
        let vault = MockKeyVault::new(KeyVaultReadStatus::Unavailable { error_code: -25308 });

        let res = manager.resolve_or_create_key(&vault, false, false);
        assert!(res.is_err());
        assert!(!key_file.exists(), "钥匙串异常时绝不生成新文件");
    }

    #[test]
    fn test_previously_initialized_missing_from_both_refuses_regeneration() {
        let dir = tempdir().unwrap();
        let key_file = dir.path().join("master.key");
        let manager = MasterKeyManager::new(&key_file);
        let vault = MockKeyVault::new(KeyVaultReadStatus::Missing);

        // Case A: legacy_initialized == true
        let res_legacy = manager.resolve_or_create_key(&vault, true, false);
        assert!(res_legacy.is_err());

        // Case B: has_encrypted_payloads == true
        let res_payloads = manager.resolve_or_create_key(&vault, false, true);
        assert!(res_payloads.is_err());

        // Case C: marker exists
        manager.mark_initialized().unwrap();
        let res_marker = manager.resolve_or_create_key(&vault, false, false);
        assert!(res_marker.is_err());
    }

    #[test]
    fn test_fresh_install_generates_new_key_and_backs_up() {
        let dir = tempdir().unwrap();
        let key_file = dir.path().join("master.key");
        let manager = MasterKeyManager::new(&key_file);
        let vault = MockKeyVault::new(KeyVaultReadStatus::Missing);

        let resolved = manager.resolve_or_create_key(&vault, false, false).unwrap();
        assert_eq!(fs::read(&key_file).unwrap(), resolved);
        assert_eq!(vault.written_key.lock().as_ref().unwrap(), &resolved.to_vec());
        assert!(manager.is_marked_initialized());
    }
}
