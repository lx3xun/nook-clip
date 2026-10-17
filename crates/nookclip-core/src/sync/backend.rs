use std::fs;
use std::path::{Path, PathBuf};

use crate::error::CoreError;

pub trait SyncStorageBackend: Send + Sync {
    fn ensure_layout(&self) -> Result<(), CoreError>;
    fn list_device_packs(&self) -> Result<Vec<String>, CoreError>;
    fn read_device_pack(&self, device_id: &str) -> Result<Vec<u8>, CoreError>;
    fn write_device_pack_atomic(&self, device_id: &str, data: &[u8]) -> Result<(), CoreError>;
    fn has_asset(&self, filename: &str) -> Result<bool, CoreError>;
    fn read_asset(&self, filename: &str) -> Result<Vec<u8>, CoreError>;
    fn write_asset_atomic(&self, filename: &str, data: &[u8]) -> Result<(), CoreError>;
}

// === 1. LocalFsBackend ===

pub struct LocalFsBackend {
    sync_dir: PathBuf,
}

impl LocalFsBackend {
    pub fn new<P: AsRef<Path>>(sync_dir: P) -> Self {
        Self {
            sync_dir: sync_dir.as_ref().to_path_buf(),
        }
    }
}

impl SyncStorageBackend for LocalFsBackend {
    fn ensure_layout(&self) -> Result<(), CoreError> {
        fs::create_dir_all(self.sync_dir.join("devices"))?;
        fs::create_dir_all(self.sync_dir.join("assets"))?;
        Ok(())
    }

    fn list_device_packs(&self) -> Result<Vec<String>, CoreError> {
        let devices_dir = self.sync_dir.join("devices");
        if !devices_dir.exists() {
            return Ok(Vec::new());
        }
        let mut ids = Vec::new();
        for entry in fs::read_dir(devices_dir)?.flatten() {
            let path = entry.path();
            if path.is_file() && path.extension().and_then(|e| e.to_str()) == Some("pack") {
                if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
                    ids.push(stem.to_string());
                }
            }
        }
        Ok(ids)
    }

    fn read_device_pack(&self, device_id: &str) -> Result<Vec<u8>, CoreError> {
        let path = self.sync_dir.join("devices").join(format!("{device_id}.pack"));
        let bytes = fs::read(&path)?;
        Ok(bytes)
    }

    fn write_device_pack_atomic(&self, device_id: &str, data: &[u8]) -> Result<(), CoreError> {
        let devices_dir = self.sync_dir.join("devices");
        fs::create_dir_all(&devices_dir)?;
        let target = devices_dir.join(format!("{device_id}.pack"));
        let temp = devices_dir.join(format!("{device_id}.tmp.{}", uuid::Uuid::new_v4()));
        fs::write(&temp, data)?;
        fs::rename(&temp, &target)?;
        Ok(())
    }

    fn has_asset(&self, filename: &str) -> Result<bool, CoreError> {
        Ok(self.sync_dir.join("assets").join(filename).exists())
    }

    fn read_asset(&self, filename: &str) -> Result<Vec<u8>, CoreError> {
        let path = self.sync_dir.join("assets").join(filename);
        let bytes = fs::read(&path)?;
        Ok(bytes)
    }

    fn write_asset_atomic(&self, filename: &str, data: &[u8]) -> Result<(), CoreError> {
        let assets_dir = self.sync_dir.join("assets");
        fs::create_dir_all(&assets_dir)?;
        let target = assets_dir.join(filename);
        if target.exists() {
            return Ok(());
        }
        let temp = assets_dir.join(format!("{filename}.tmp.{}", uuid::Uuid::new_v4()));
        fs::write(&temp, data)?;
        let _ = fs::rename(&temp, &target);
        Ok(())
    }
}

// === 2. WebDavBackend ===

pub struct WebDavBackend {
    base_url: String,
    username: String,
    password: String,
    agent: ureq::Agent,
}

impl WebDavBackend {
    pub fn new(base_url: String, username: String, password: String, timeout_secs: u64) -> Self {
        let agent = ureq::builder()
            .timeout(std::time::Duration::from_secs(timeout_secs))
            .build();
        let normalized_base = base_url.trim_end_matches('/').to_string();
        Self {
            base_url: normalized_base,
            username,
            password,
            agent,
        }
    }

    fn request(&self, method: &str, subpath: &str) -> ureq::Request {
        let url = format!("{}/{}", self.base_url, subpath.trim_start_matches('/'));
        let mut req = self.agent.request(method, &url);
        if !self.username.is_empty() {
            let creds = format!("{}:{}", self.username, self.password);
            let encoded = encode_base64(creds.as_bytes());
            req = req.set("Authorization", &format!("Basic {encoded}"));
        }
        req
    }
}

impl SyncStorageBackend for WebDavBackend {
    fn ensure_layout(&self) -> Result<(), CoreError> {
        let _ = self.request("MKCOL", "devices").call();
        let _ = self.request("MKCOL", "assets").call();
        Ok(())
    }

    fn list_device_packs(&self) -> Result<Vec<String>, CoreError> {
        let res = match self.request("PROPFIND", "devices")
            .set("Depth", "1")
            .call() {
            Ok(r) => r,
            Err(e) => return Err(CoreError::SyncTransport(e.to_string())),
        };

        let body = res.into_string().map_err(|e| CoreError::SyncTransport(e.to_string()))?;
        let mut ids = Vec::new();
        // 极简 XML/文本匹配 <d:href> 或 href 提取 .pack 结尾的条目
        for token in body.split(|c: char| c == '<' || c == '>' || c.is_whitespace()) {
            if token.ends_with(".pack") {
                if let Some(filename) = token.split('/').last() {
                    let stem = filename.trim_end_matches(".pack");
                    if !stem.is_empty() && !stem.contains(".tmp.") && !ids.contains(&stem.to_string()) {
                        ids.push(stem.to_string());
                    }
                }
            }
        }
        Ok(ids)
    }

    fn read_device_pack(&self, device_id: &str) -> Result<Vec<u8>, CoreError> {
        let path = format!("devices/{device_id}.pack");
        let res = self.request("GET", &path).call().map_err(|e| CoreError::SyncTransport(e.to_string()))?;
        let mut bytes = Vec::new();
        use std::io::Read;
        res.into_reader().read_to_end(&mut bytes)?;
        Ok(bytes)
    }

    fn write_device_pack_atomic(&self, device_id: &str, data: &[u8]) -> Result<(), CoreError> {
        let temp_name = format!("devices/{device_id}.tmp.{}", uuid::Uuid::new_v4());
        let target_url = format!("{}/devices/{device_id}.pack", self.base_url);

        self.request("PUT", &temp_name)
            .send_bytes(data)
            .map_err(|e| CoreError::SyncTransport(e.to_string()))?;

        // MOVE to target
        let move_res = self.request("MOVE", &temp_name)
            .set("Destination", &target_url)
            .set("Overwrite", "T")
            .call();

        if let Err(e) = move_res {
            return Err(CoreError::SyncTransport(e.to_string()));
        }

        Ok(())
    }

    fn has_asset(&self, filename: &str) -> Result<bool, CoreError> {
        let path = format!("assets/{filename}");
        let res = self.request("HEAD", &path).call();
        match res {
            Ok(r) => Ok(r.status() >= 200 && r.status() < 300),
            Err(ureq::Error::Status(code, _)) if code == 404 => Ok(false),
            Err(e) => Err(CoreError::SyncTransport(e.to_string())),
        }
    }

    fn read_asset(&self, filename: &str) -> Result<Vec<u8>, CoreError> {
        let path = format!("assets/{filename}");
        let res = self.request("GET", &path).call().map_err(|e| CoreError::SyncTransport(e.to_string()))?;
        let mut bytes = Vec::new();
        use std::io::Read;
        res.into_reader().read_to_end(&mut bytes)?;
        Ok(bytes)
    }

    fn write_asset_atomic(&self, filename: &str, data: &[u8]) -> Result<(), CoreError> {
        let temp_name = format!("assets/{filename}.tmp.{}", uuid::Uuid::new_v4());
        let target_url = format!("{}/assets/{filename}", self.base_url);

        self.request("PUT", &temp_name)
            .send_bytes(data)
            .map_err(|e| CoreError::SyncTransport(e.to_string()))?;

        match self.request("MOVE", &temp_name)
            .set("Destination", &target_url)
            .set("Overwrite", "F")
            .call()
        {
            Ok(_) => Ok(()),
            Err(ureq::Error::Status(412, _)) => Ok(()),
            Err(e) => Err(CoreError::SyncTransport(e.to_string())),
        }
    }
}
fn encode_base64(input: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity((input.len() + 2) / 3 * 4);
    for chunk in input.chunks(3) {
        let b0 = chunk[0];
        let b1 = chunk.get(1).copied().unwrap_or(0);
        let b2 = chunk.get(2).copied().unwrap_or(0);

        let n = ((b0 as u32) << 16) | ((b1 as u32) << 8) | (b2 as u32);

        out.push(TABLE[((n >> 18) & 63) as usize] as char);
        out.push(TABLE[((n >> 12) & 63) as usize] as char);

        if chunk.len() > 1 {
            out.push(TABLE[((n >> 6) & 63) as usize] as char);
        } else {
            out.push('=');
        }

        if chunk.len() > 2 {
            out.push(TABLE[(n & 63) as usize] as char);
        } else {
            out.push('=');
        }
    }
    out
}
