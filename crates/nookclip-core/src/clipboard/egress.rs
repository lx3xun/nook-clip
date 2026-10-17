use std::fs;
use std::path::Path;

use crate::{
    crypto::CryptoEngine,
    error::{CoreError, Result},
    model::{PreparedPastePayload, QueryFilter},
    storage::repository::StorageRepository,
};

pub fn prepare_paste_payload(
    repo: &StorageRepository,
    _crypto: Option<&CryptoEngine>,
    id: &str,
    plain_text_only: bool,
) -> Result<PreparedPastePayload> {
    let filter = QueryFilter {
        id: Some(id.to_string()),
        limit: 1,
        include_deleted: false,
        ..Default::default()
    };
    let items = repo.query_items(&filter)?;
    let item = items.into_iter().next().ok_or_else(|| CoreError::NotFound(id.to_string()))?;

    // 1. 文件条目：校验本地文件存在性
    if item.item_type == "file" {
        let plain = if item.is_sensitive {
            match repo.get_item_detail(id) {
                Ok(detail) if detail.raw_text.is_some() => detail.raw_text.unwrap(),
                _ => return Err(CoreError::DecryptionFailed),
            }
        } else if let Some(p) = &item.payload_path {
            p.clone()
        } else {
            item.summary.clone()
        };

        let paths: Vec<String> = plain.lines().map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect();
        if paths.is_empty() {
            return Err(CoreError::StaleFiles { missing_paths: vec!["<empty>".to_string()] });
        }
        let missing: Vec<String> = paths.iter().filter(|p| !Path::new(p).exists()).cloned().collect();
        if !missing.is_empty() {
            return Err(CoreError::StaleFiles { missing_paths: missing });
        }

        let is_single_image = paths.len() == 1 && is_image_path(&paths[0]);
        let joined = paths.join("\n");

        return Ok(PreparedPastePayload {
            item_id: id.to_string(),
            item_type: "file".to_string(),
            plain_text: Some(joined),
            rtf_data: None,
            image_data: None,
            image_format: None,
            file_paths: paths,
            is_single_image_file: is_single_image,
            is_sensitive: item.is_sensitive,
        });
    }

    // 2. 图片条目：校验本地资产文件可读
    if item.item_type == "image" {
        let path = item.payload_path.as_deref().ok_or(CoreError::CorruptedImagePayload)?;
        let data = fs::read(path).map_err(|_| CoreError::CorruptedImagePayload)?;
        let format = Path::new(path)
            .extension()
            .and_then(|e| e.to_str())
            .map(|s| s.to_ascii_lowercase())
            .unwrap_or_else(|| "png".to_string());

        return Ok(PreparedPastePayload {
            item_id: id.to_string(),
            item_type: "image".to_string(),
            plain_text: None,
            rtf_data: None,
            image_data: Some(data),
            image_format: Some(format),
            file_paths: Vec::new(),
            is_single_image_file: false,
            is_sensitive: false,
        });
    }

    // 3. 敏感条目（文本 / URL）：必须先解密
    let sensitive_plain = if item.is_sensitive {
        match repo.get_item_detail(id) {
            Ok(detail) if detail.raw_text.is_some() => detail.raw_text,
            _ => return Err(CoreError::DecryptionFailed),
        }
    } else {
        None
    };
    let effective_text = sensitive_plain.unwrap_or(item.summary.clone());

    // 4. RTF 伴生载荷（非敏感且非纯文本模式）
    let rtf_data = if !item.is_sensitive && !plain_text_only {
        if let Some(path) = &item.payload_path {
            if path.to_ascii_lowercase().ends_with(".rtf") {
                fs::read(path).ok()
            } else {
                None
            }
        } else {
            None
        }
    } else {
        None
    };

    Ok(PreparedPastePayload {
        item_id: id.to_string(),
        item_type: item.item_type,
        plain_text: Some(effective_text),
        rtf_data,
        image_data: None,
        image_format: None,
        file_paths: Vec::new(),
        is_single_image_file: false,
        is_sensitive: item.is_sensitive,
    })
}

pub fn prepare_batch_paste_payload(
    repo: &StorageRepository,
    crypto: Option<&CryptoEngine>,
    ids: &[String],
    separator: &str,
) -> Result<PreparedPastePayload> {
    if ids.is_empty() {
        return Err(CoreError::InvalidArgument("ids cannot be empty".to_string()));
    }

    let mut texts = Vec::with_capacity(ids.len());
    let mut any_sensitive = false;

    for id in ids {
        let single = prepare_paste_payload(repo, crypto, id, true)?;
        if single.is_sensitive {
            any_sensitive = true;
        }
        if let Some(txt) = single.plain_text {
            texts.push(txt);
        }
    }

    Ok(PreparedPastePayload {
        item_id: format!("batch-{}", uuid::Uuid::new_v4()),
        item_type: "text".to_string(),
        plain_text: Some(texts.join(separator)),
        rtf_data: None,
        image_data: None,
        image_format: None,
        file_paths: Vec::new(),
        is_single_image_file: false,
        is_sensitive: any_sensitive, // BUG-052: 传染敏感标记
    })
}

fn is_image_path(path: &str) -> bool {
    let lower = path.to_ascii_lowercase();
    lower.ends_with(".png")
        || lower.ends_with(".jpg")
        || lower.ends_with(".jpeg")
        || lower.ends_with(".tiff")
        || lower.ends_with(".tif")
        || lower.ends_with(".gif")
        || lower.ends_with(".bmp")
        || lower.ends_with(".webp")
}
