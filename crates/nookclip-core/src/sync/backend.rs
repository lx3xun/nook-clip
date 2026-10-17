use std::fs;
use std::path::{Path, PathBuf};

use crate::error::CoreError;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RemotePackMeta {
    pub device_id: String,
    pub fingerprint: Option<String>,
    pub size_bytes: u64,
}

pub trait SyncStorageBackend: Send + Sync {
    fn ensure_layout(&self) -> Result<(), CoreError>;
    fn read_manifest(&self) -> Result<Option<Vec<u8>>, CoreError>;
    fn write_manifest_atomic(&self, data: &[u8]) -> Result<(), CoreError>;
    fn list_device_packs(&self) -> Result<Vec<RemotePackMeta>, CoreError>;
    fn read_device_pack(&self, device_id: &str) -> Result<Vec<u8>, CoreError>;
    fn write_device_pack_atomic(&self, device_id: &str, data: &[u8]) -> Result<(), CoreError>;
    fn list_assets(&self) -> Result<std::collections::HashSet<String>, CoreError>;
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

    fn read_manifest(&self) -> Result<Option<Vec<u8>>, CoreError> {
        let path = self.sync_dir.join("sync.manifest");
        if path.exists() {
            Ok(Some(fs::read(path)?))
        } else {
            Ok(None)
        }
    }

    fn write_manifest_atomic(&self, data: &[u8]) -> Result<(), CoreError> {
        let target = self.sync_dir.join("sync.manifest");
        let temp = self.sync_dir.join(format!("sync.manifest.tmp.{}", uuid::Uuid::new_v4()));
        fs::write(&temp, data)?;
        fs::rename(&temp, &target)?;
        Ok(())
    }

    fn list_device_packs(&self) -> Result<Vec<RemotePackMeta>, CoreError> {
        let devices_dir = self.sync_dir.join("devices");
        if !devices_dir.exists() {
            return Ok(Vec::new());
        }
        let mut metas = Vec::new();
        for entry in fs::read_dir(devices_dir)?.flatten() {
            let path = entry.path();
            if path.is_file() && path.extension().and_then(|e| e.to_str()) == Some("pack") {
                if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
                    if !stem.contains(".tmp.") {
                        let md = entry.metadata().ok();
                        let size_bytes = md.as_ref().map(|m| m.len()).unwrap_or(0);
                        let fingerprint = md.and_then(|m| m.modified().ok()).map(|mtime| {
                            let dur = mtime.duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
                            format!("{}:{}:{}", dur.as_secs(), dur.subsec_nanos(), size_bytes)
                        });
                        metas.push(RemotePackMeta {
                            device_id: stem.to_string(),
                            fingerprint,
                            size_bytes,
                        });
                    }
                }
            }
        }
        Ok(metas)
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

    fn list_assets(&self) -> Result<std::collections::HashSet<String>, CoreError> {
        let assets_dir = self.sync_dir.join("assets");
        let mut set = std::collections::HashSet::new();
        if assets_dir.exists() {
            for entry in fs::read_dir(assets_dir)?.flatten() {
                if entry.path().is_file() {
                    if let Some(name) = entry.file_name().to_str() {
                        if !name.contains(".tmp.") {
                            set.insert(name.to_string());
                        }
                    }
                }
            }
        }
        Ok(set)
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
        if let Err(e) = fs::rename(&temp, &target) {
            let _ = fs::remove_file(&temp);
            if !target.exists() {
                return Err(e.into());
            }
        }
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
        let _ = self.request("MKCOL", "devices/").call();
        let _ = self.request("MKCOL", "assets/").call();
        Ok(())
    }

    fn read_manifest(&self) -> Result<Option<Vec<u8>>, CoreError> {
        let res = self.request("GET", "sync.manifest").call();
        match res {
            Ok(r) => {
                let mut bytes = Vec::new();
                use std::io::Read;
                r.into_reader().read_to_end(&mut bytes)?;
                Ok(Some(bytes))
            }
            Err(ureq::Error::Status(404, _)) => Ok(None),
            Err(e) => Err(CoreError::SyncTransport(e.to_string())),
        }
    }

    fn write_manifest_atomic(&self, data: &[u8]) -> Result<(), CoreError> {
        self.request("PUT", "sync.manifest")
            .send_bytes(data)
            .map_err(|e| CoreError::SyncTransport(e.to_string()))?;
        Ok(())
    }

    fn list_device_packs(&self) -> Result<Vec<RemotePackMeta>, CoreError> {
        let res = match self.request("PROPFIND", "devices/")
            .set("Depth", "1")
            .call() {
            Ok(r) => r,
            Err(ureq::Error::Status(404, _)) => return Ok(Vec::new()),
            Err(e) => return Err(CoreError::SyncTransport(e.to_string())),
        };

        let body = res.into_string().map_err(|e| CoreError::SyncTransport(e.to_string()))?;
        Ok(parse_webdav_pack_metas(&body))
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
        let path = format!("devices/{device_id}.pack");
        let res = self.request("PUT", &path).send_bytes(data);
        match res {
            Ok(_) => Ok(()),
            Err(ureq::Error::Status(404, _)) | Err(ureq::Error::Status(409, _)) => {
                let _ = self.request("MKCOL", "devices/").call();
                self.request("PUT", &path)
                    .send_bytes(data)
                    .map_err(|e| CoreError::SyncTransport(e.to_string()))?;
                Ok(())
            }
            Err(e) => Err(CoreError::SyncTransport(e.to_string())),
        }
    }

    fn list_assets(&self) -> Result<std::collections::HashSet<String>, CoreError> {
        let res = match self.request("PROPFIND", "assets/")
            .set("Depth", "1")
            .call() {
            Ok(r) => r,
            Err(ureq::Error::Status(404, _)) => return Ok(std::collections::HashSet::new()),
            Err(e) => return Err(CoreError::SyncTransport(e.to_string())),
        };
        let body = res.into_string().map_err(|e| CoreError::SyncTransport(e.to_string()))?;
        let mut set = std::collections::HashSet::new();
        for chunk in split_webdav_response_chunks(&body) {
            if let Some(href) = extract_xml_tag(chunk, "href")
                .or_else(|| extract_xml_tag(chunk, "d:href"))
                .or_else(|| extract_xml_tag(chunk, "D:href"))
            {
                if href.ends_with('/') {
                    continue;
                }
                if let Some(filename) = href.split('/').last() {
                    let filename = filename.trim();
                    if !filename.is_empty() && !filename.contains(".tmp.") && filename.contains('.') {
                        set.insert(filename.to_string());
                    }
                }
            }
        }
        Ok(set)
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
        let path = format!("assets/{filename}");
        let res = self.request("PUT", &path).send_bytes(data);
        match res {
            Ok(_) => Ok(()),
            Err(ureq::Error::Status(404, _)) | Err(ureq::Error::Status(409, _)) => {
                let _ = self.request("MKCOL", "assets/").call();
                self.request("PUT", &path)
                    .send_bytes(data)
                    .map_err(|e| CoreError::SyncTransport(e.to_string()))?;
                Ok(())
            }
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

fn split_webdav_response_chunks(xml: &str) -> Vec<&str> {
    let delimiters = ["</d:response>", "</D:response>", "</response>"];
    let mut chunks = Vec::new();
    let mut remaining = xml;
    while !remaining.is_empty() {
        let mut earliest_split = None;
        for delim in &delimiters {
            if let Some(idx) = remaining.find(delim) {
                if earliest_split.map_or(true, |(earliest, _)| idx < earliest) {
                    earliest_split = Some((idx, *delim));
                }
            }
        }
        if let Some((idx, delim)) = earliest_split {
            chunks.push(&remaining[..idx]);
            remaining = &remaining[idx + delim.len()..];
        } else {
            chunks.push(remaining);
            break;
        }
    }
    chunks
}

fn parse_webdav_pack_metas(xml: &str) -> Vec<RemotePackMeta> {
    let mut metas = Vec::new();
    for chunk in split_webdav_response_chunks(xml) {
        let href = extract_xml_tag(chunk, "href")
            .or_else(|| extract_xml_tag(chunk, "d:href"))
            .or_else(|| extract_xml_tag(chunk, "D:href"));
        let Some(href_val) = href else { continue };
        if !href_val.ends_with(".pack") { continue };
        let filename = href_val.split('/').last().unwrap_or(&href_val);
        let stem = filename.trim_end_matches(".pack");
        if stem.is_empty() || stem.contains(".tmp.") { continue };

        let etag = extract_xml_tag(chunk, "getetag")
            .or_else(|| extract_xml_tag(chunk, "d:getetag"))
            .or_else(|| extract_xml_tag(chunk, "D:getetag"))
            .map(|s| s.trim_matches('"').to_string());

        let last_modified = extract_xml_tag(chunk, "getlastmodified")
            .or_else(|| extract_xml_tag(chunk, "d:getlastmodified"))
            .or_else(|| extract_xml_tag(chunk, "D:getlastmodified"));

        let content_length = extract_xml_tag(chunk, "getcontentlength")
            .or_else(|| extract_xml_tag(chunk, "d:getcontentlength"))
            .or_else(|| extract_xml_tag(chunk, "D:getcontentlength"))
            .and_then(|s| s.trim().parse::<u64>().ok())
            .unwrap_or(0);

        let fingerprint = etag.or(last_modified);

        if !metas.iter().any(|m: &RemotePackMeta| m.device_id == stem) {
            metas.push(RemotePackMeta {
                device_id: stem.to_string(),
                fingerprint,
                size_bytes: content_length,
            });
        }
    }
    if metas.is_empty() {
        for token in xml.split(|c: char| c == '<' || c == '>' || c.is_whitespace()) {
            if token.ends_with(".pack") {
                if let Some(filename) = token.split('/').last() {
                    let stem = filename.trim_end_matches(".pack");
                    if !stem.is_empty() && !stem.contains(".tmp.") && !metas.iter().any(|m| m.device_id == stem) {
                        metas.push(RemotePackMeta {
                            device_id: stem.to_string(),
                            fingerprint: None,
                            size_bytes: 0,
                        });
                    }
                }
            }
        }
    }
    metas
}

fn extract_xml_tag(text: &str, tag_name: &str) -> Option<String> {
    let lower_tag = tag_name.to_ascii_lowercase();
    let close_tag = format!("</{lower_tag}>");

    let mut search_from = 0;
    while let Some(rel_start) = text[search_from..].find('<') {
        let start_idx = search_from + rel_start;
        let rest = &text[start_idx + 1..];
        if rest.len() >= lower_tag.len() && rest[..lower_tag.len()].eq_ignore_ascii_case(&lower_tag) {
            let next_char = rest[lower_tag.len()..].chars().next();
            if matches!(next_char, Some('>' | ' ' | '\t' | '\n' | '\r')) {
                if let Some(tag_end_rel) = text[start_idx..].find('>') {
                    let content_start = start_idx + tag_end_rel + 1;
                    let remaining = &text[content_start..];
                    let mut close_search = 0;
                    while let Some(close_rel) = remaining[close_search..].find("</") {
                        let cand_idx = close_search + close_rel;
                        let cand = &remaining[cand_idx..];
                        if cand.len() >= close_tag.len()
                            && cand[..close_tag.len()].eq_ignore_ascii_case(&close_tag)
                        {
                            return Some(remaining[..cand_idx].trim().to_string());
                        }
                        close_search = cand_idx + 2;
                    }
                }
            }
        }
        search_from = start_idx + 1;
    }
    None
}
