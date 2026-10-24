use sha2::{Digest, Sha256};

use crate::{
    algorithms,
    clipboard::html_anchor::extract_first_anchor_text,
    clipboard::image_header::parse_image_dimensions,
    crypto::CryptoEngine,
    error::Result,
    model::{ClipItemSummary, IngestConfig, IngestOutcome, RawClipboardSnapshot},
    storage::{payload_asset::PayloadAssetStore, repository::StorageRepository},
};

/// NookClip 跨平台确定性 ID 根命名空间 (UUIDv5)
pub const NOOK_CLIP_NAMESPACE: uuid::Uuid = uuid::uuid!("5fa6b780-6ea7-4b4d-9e12-c249a5b3901a");

pub fn ingest_clipboard_snapshot(
    repo: &StorageRepository,
    crypto: Option<&CryptoEngine>,
    snapshot: &RawClipboardSnapshot,
    config: &IngestConfig,
    last_pasted_summary: Option<&str>,
    last_pasted_time: Option<f64>,
    now_ts: f64,
) -> Result<IngestOutcome> {
    if !config.local_assets_dir.is_empty() {
        repo.set_assets_dir(Some(&config.local_assets_dir));
    }
    // 1. 过滤密码管理器敏感标记
    if snapshot.has_concealed_marker {
        return Ok(IngestOutcome::SkippedConcealed);
    }

    // 2. 过滤排除应用黑名单
    if let Some(bundle_id) = &snapshot.source_bundle_id {
        if config.excluded_bundle_ids.iter().any(|b| b == bundle_id) {
            return Ok(IngestOutcome::SkippedExcludedApp);
        }
    }

    // 3. 过滤 1.5s 内部粘贴保护窗口重入
    if let (Some(last_pasted), Some(last_time)) = (last_pasted_summary, last_pasted_time) {
        if now_ts - last_time < 1.5 {
            if let Some(text) = &snapshot.plain_text {
                if text == last_pasted {
                    return Ok(IngestOutcome::SkippedInternalPaste);
                }
            }
        }
    }

    // 4. 优先级裁决: File > URL > Text > Image
    // 分支 A: 本地文件
    let has_file_urls = !snapshot.file_paths.is_empty();
    if has_file_urls {
        return ingest_file_item(repo, crypto, snapshot, config, now_ts);
    }

    // 分支 B: 文本 / URL
    if let Some(text) = &snapshot.plain_text {
        let trimmed = text.trim();
        if !trimmed.is_empty() {
            return ingest_text_or_url_item(repo, crypto, snapshot, config, text, now_ts);
        }
    }

    // 分支 C: 图片
    if let Some(image_data) = &snapshot.image_data {
        if !image_data.is_empty() {
            return ingest_image_item(repo, snapshot, config, image_data, now_ts);
        }
    }

    Ok(IngestOutcome::SkippedEmpty)
}

fn ingest_file_item(
    repo: &StorageRepository,
    crypto: Option<&CryptoEngine>,
    snapshot: &RawClipboardSnapshot,
    config: &IngestConfig,
    now_ts: f64,
) -> Result<IngestOutcome> {
    let joined = snapshot.file_paths.join("\n");
    let detection = algorithms::sensitive::detect_sensitive(&joined);

    let (title, summary, payload_path, is_sensitive, raw_text) = if detection.is_sensitive {
        if !config.sensitive_protection_enabled {
            return Ok(IngestOutcome::SkippedSensitiveProtectionDisabled);
        }
        if crypto.is_none() {
            return Ok(IngestOutcome::DroppedEncryptionUnavailable);
        }
        // 敏感文件：不存明文路径，仅存掩码
        (String::new(), detection.masked_text, None, true, Some(joined))
    } else {
        let first_file_name = snapshot
            .file_paths
            .first()
            .and_then(|p| {
                p.trim_end_matches(&['/', '\\'][..])
                    .rsplit(&['/', '\\'][..])
                    .next()
                    .filter(|s| !s.is_empty())
            })
            .unwrap_or("File");
        let title = if snapshot.file_paths.len() == 1 {
            first_file_name.to_string()
        } else if let Some(template) = &config.file_multi_title_template {
            template
                .replace("%1$@", first_file_name)
                .replace("%2$d", &snapshot.file_paths.len().to_string())
        } else {
            format!("{} ({} items)", first_file_name, snapshot.file_paths.len())
        };
        (title, joined.clone(), Some(joined.clone()), false, Some(joined))
    };

    let source_device_id = snapshot.source_device_id.clone().or_else(|| config.source_device_id.clone());
    let source_device_name = snapshot.source_device_name.clone().or_else(|| config.source_device_name.clone());
    let source_platform = snapshot.source_platform.clone().or_else(|| config.source_platform.clone());

    let item_summary = ClipItemSummary {
        id: uuid::Uuid::new_v4().to_string().to_uppercase(),
        item_type: "file".to_string(),
        title,
        summary,
        created_at: now_ts,
        last_used_at: now_ts,
        copy_count: 1,
        favorite: false,
        source_app_bundle_id: snapshot.source_bundle_id.clone(),
        source_app_name: snapshot.source_app_name.clone(),
        source_device_id,
        source_device_name,
        source_platform,
        is_sensitive,
        deleted_at: None,
        payload_path,
        ocr_text: None,
        metadata_json: None,
        kind: "file".to_string(),
        tags: Vec::new(),
    };
    let item = repo.save_item(&item_summary, raw_text.as_deref())?;
    Ok(IngestOutcome::Saved { item })
}

fn ingest_text_or_url_item(
    repo: &StorageRepository,
    crypto: Option<&CryptoEngine>,
    snapshot: &RawClipboardSnapshot,
    config: &IngestConfig,
    text: &str,
    now_ts: f64,
) -> Result<IngestOutcome> {
    let is_url = is_web_url(text);
    let item_type = if is_url { "url" } else { "text" };
    let detection = algorithms::sensitive::detect_sensitive(text);

    let (title, summary, payload_path, is_sensitive, raw_text, metadata_json) = if detection.is_sensitive {
        if !config.sensitive_protection_enabled {
            return Ok(IngestOutcome::SkippedSensitiveProtectionDisabled);
        }
        if crypto.is_none() {
            return Ok(IngestOutcome::DroppedEncryptionUnavailable);
        }
        (String::new(), detection.masked_text, None, true, Some(text.to_string()), None)
    } else {
        // 复用上方 detect_sensitive 的结论：非敏感时跳过第二次全量 PATTERNS 扫描
        let feature = algorithms::analyze_content_with_sensitivity(text, Some(false));
        let title = snapshot
            .url_title
            .as_ref()
            .filter(|t| !t.trim().is_empty())
            .cloned()
            .or_else(|| {
                if is_url {
                    snapshot.html.as_deref().and_then(extract_first_anchor_text)
                } else {
                    None
                }
            })
            .unwrap_or_default();

        let mut meta_obj = serde_json::Map::new();
        if is_url {
            meta_obj.insert("url".to_string(), serde_json::Value::String(text.trim().to_string()));
        } else {
            if let Some(lang) = feature.detected_language {
                meta_obj.insert("language".to_string(), serde_json::Value::String(lang));
            }
            if feature.has_email {
                meta_obj.insert("hasEmail".to_string(), serde_json::Value::Bool(true));
            }
            if let Some(hex) = feature.detected_color_hex {
                meta_obj.insert("colorHex".to_string(), serde_json::Value::String(hex));
            }
        }
        let metadata_str = if meta_obj.is_empty() {
            None
        } else {
            Some(serde_json::Value::Object(meta_obj).to_string())
        };

        let mut rtf_path = None;
        if !is_url {
            if let Some(rtf_bytes) = &snapshot.rtf_data {
                if !config.local_assets_dir.is_empty() {
                    let asset_store = PayloadAssetStore::new(&config.local_assets_dir);
                    if let Ok(store) = asset_store {
                        if let Ok(path) = store.save_payload_asset(rtf_bytes, "rtf") {
                            rtf_path = Some(path);
                        }
                    }
                }
            }
        }

        (title, text.to_string(), rtf_path, false, Some(text.to_string()), metadata_str)
    };

    let source_device_id = snapshot.source_device_id.clone().or_else(|| config.source_device_id.clone());
    let source_device_name = snapshot.source_device_name.clone().or_else(|| config.source_device_name.clone());
    let source_platform = snapshot.source_platform.clone().or_else(|| config.source_platform.clone());

    // 非敏感条目使用换行符归一化后的内容哈希确定性 ID (UUIDv5)，实现跨端同内容自然置顶；敏感条目保持随机 UUID 防碰撞
    let id = if is_sensitive {
        uuid::Uuid::new_v4().to_string().to_uppercase()
    } else {
        let normalized = text.replace("\r\n", "\n");
        let payload = format!("{}\0{}", item_type, normalized);
        uuid::Uuid::new_v5(&NOOK_CLIP_NAMESPACE, payload.as_bytes())
            .to_string()
            .to_uppercase()
    };

    let item_summary = ClipItemSummary {
        id,
        item_type: item_type.to_string(),
        title,
        summary,
        created_at: now_ts,
        last_used_at: now_ts,
        copy_count: 1,
        favorite: false,
        source_app_bundle_id: snapshot.source_bundle_id.clone(),
        source_app_name: snapshot.source_app_name.clone(),
        source_device_id,
        source_device_name,
        source_platform,
        is_sensitive,
        deleted_at: None,
        payload_path,
        ocr_text: None,
        metadata_json,
        kind: item_type.to_string(),
        tags: Vec::new(),
    };
    let item = repo.save_item(&item_summary, raw_text.as_deref())?;
    Ok(IngestOutcome::Saved { item })
}
fn ingest_image_item(
    repo: &StorageRepository,
    snapshot: &RawClipboardSnapshot,
    config: &IngestConfig,
    image_data: &[u8],
    now_ts: f64,
) -> Result<IngestOutcome> {
    if config.local_assets_dir.is_empty() {
        return Ok(IngestOutcome::DroppedPayloadSaveFailed);
    }
    let asset_store = match PayloadAssetStore::new(&config.local_assets_dir) {
        Ok(s) => s,
        Err(_) => return Ok(IngestOutcome::DroppedPayloadSaveFailed),
    };

    let ext = snapshot.image_extension.as_deref().unwrap_or("png");
    let payload_path = match asset_store.save_payload_asset(image_data, ext) {
        Ok(p) => p,
        Err(_) => return Ok(IngestOutcome::DroppedPayloadSaveFailed),
    };

    let hash_hex = format!("{:x}", Sha256::digest(image_data));
    let hash_prefix = &hash_hex[..8];
    let dimensions = parse_image_dimensions(image_data);
    let size_bytes = image_data.len();
    let size_desc = format_byte_size(size_bytes);

    let summary = if let Some((w, h)) = dimensions {
        format!("{w} × {h} px · {size_desc} #{hash_prefix}")
    } else {
        format!("{size_desc} #{hash_prefix}")
    };

    let title = snapshot
        .url_title
        .as_ref()
        .filter(|t| !t.trim().is_empty())
        .cloned()
        .or_else(|| {
            for url in &snapshot.url_candidates {
                let decoded = percent_decode(url);
                let path_part = decoded.split('?').next().unwrap_or(&decoded);
                if let Some(filename) = path_part.split('/').last() {
                    let trimmed_name = filename.trim();
                    if let Some(dot) = trimmed_name.rfind('.') {
                        if dot > 0 && dot < trimmed_name.len() - 1 {
                            return Some(trimmed_name.chars().take(48).collect());
                        }
                    }
                }
            }
            None
        })
        .unwrap_or_else(|| config.default_image_title.clone());

    let source_device_id = snapshot.source_device_id.clone().or_else(|| config.source_device_id.clone());
    let source_device_name = snapshot.source_device_name.clone().or_else(|| config.source_device_name.clone());
    let source_platform = snapshot.source_platform.clone().or_else(|| config.source_platform.clone());

    // 图片按二进制 SHA-256 哈希计算跨设备确定性 ID (UUIDv5)
    let id = {
        let payload = format!("image\0{}", hash_hex);
        uuid::Uuid::new_v5(&NOOK_CLIP_NAMESPACE, payload.as_bytes())
            .to_string()
            .to_uppercase()
    };

    let item_summary = ClipItemSummary {
        id,
        item_type: "image".to_string(),
        title,
        summary,
        created_at: now_ts,
        last_used_at: now_ts,
        copy_count: 1,
        favorite: false,
        source_app_bundle_id: snapshot.source_bundle_id.clone(),
        source_app_name: snapshot.source_app_name.clone(),
        source_device_id,
        source_device_name,
        source_platform,
        is_sensitive: false,
        deleted_at: None,
        payload_path: Some(payload_path),
        ocr_text: None,
        metadata_json: None,
        kind: "image".to_string(),
        tags: Vec::new(),
    };
    let item = repo.save_item(&item_summary, None)?;
    Ok(IngestOutcome::Saved { item })
}
fn percent_decode(s: &str) -> String {
    let mut bytes = Vec::with_capacity(s.len());
    let s_bytes = s.as_bytes();
    let mut i = 0;
    while i < s_bytes.len() {
        if s_bytes[i] == b'%' && i + 2 < s_bytes.len() {
            let h1 = (s_bytes[i + 1] as char).to_digit(16);
            let h2 = (s_bytes[i + 2] as char).to_digit(16);
            if let (Some(v1), Some(v2)) = (h1, h2) {
                bytes.push(((v1 << 4) | v2) as u8);
                i += 3;
                continue;
            }
        }
        bytes.push(s_bytes[i]);
        i += 1;
    }
    String::from_utf8(bytes).unwrap_or_else(|_| s.to_string())
}
fn is_web_url(text: &str) -> bool {
    let trimmed = text.trim();
    if (trimmed.starts_with("http://") || trimmed.starts_with("https://")) && trimmed.len() > 8 {
        let without_proto = if trimmed.starts_with("https://") {
            &trimmed[8..]
        } else {
            &trimmed[7..]
        };
        !without_proto.is_empty() && without_proto.contains('.') && !without_proto.starts_with('.')
    } else {
        false
    }
}

fn format_byte_size(bytes: usize) -> String {
    if bytes < 1024 {
        format!("{bytes} B")
    } else if bytes < 1024 * 1024 {
        format!("{:.1} KB", bytes as f64 / 1024.0)
    } else {
        format!("{:.1} MB", bytes as f64 / (1024.0 * 1024.0))
    }
}
