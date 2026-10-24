use tempfile::tempdir;

use nookclip_core::{
    model::ClipItemSummary,
    storage::repository::StorageRepository,
    sync::{
        backend::{LocalFsBackend, SyncStorageBackend},
        engine::SyncEngine,
    },
};

#[test]
fn test_local_fs_backend_roundtrip_and_assets() {
    let dir = tempdir().unwrap();
    let sync_dir = dir.path().join("sync");
    let backend = LocalFsBackend::new(&sync_dir);
    backend.ensure_layout().unwrap();

    // 1. Pack read/write atomic
    let pack_data = b"compressed-pack-bytes-12345";
    backend.write_device_pack_atomic("device-a", pack_data).unwrap();

    let list = backend.list_device_packs().unwrap();
    let ids: Vec<&str> = list.iter().map(|m| m.device_id.as_str()).collect();
    assert_eq!(ids, vec!["device-a"]);

    let read_back = backend.read_device_pack("device-a").unwrap();
    assert_eq!(read_back, pack_data);

    // 2. Asset read/write atomic
    let asset_data = b"image-png-binary";
    assert!(!backend.has_asset("img1.png").unwrap());
    backend.write_asset_atomic("img1.png", asset_data).unwrap();
    assert!(backend.has_asset("img1.png").unwrap());
    assert_eq!(backend.read_asset("img1.png").unwrap(), asset_data);
}

#[test]
fn test_sync_engine_two_devices_local_backend() {
    let dir = tempdir().unwrap();
    let sync_dir = dir.path().join("cloud_sync");
    let key = [0x42u8; 32];

    let db_a = dir.path().join("dev_a.db");
    let repo_a = StorageRepository::new(db_a.to_str().unwrap(), &key).unwrap();
    let engine_a = SyncEngine::new(&sync_dir, "device-A".to_string(), None).unwrap();

    let db_b = dir.path().join("dev_b.db");
    let repo_b = StorageRepository::new(db_b.to_str().unwrap(), &key).unwrap();
    let engine_b = SyncEngine::new(&sync_dir, "device-B".to_string(), None).unwrap();

    // Device A saves an item
    let item = ClipItemSummary {
        id: "item-sync-1".to_string(),
        item_type: "text".to_string(),
        title: "Sync Test".to_string(),
        summary: "Sync payload".to_string(),
        created_at: 100.0,
        last_used_at: 100.0,
        copy_count: 1,
        favorite: false,
        source_app_bundle_id: None,
        source_app_name: None,
        source_device_id: None,
        source_device_name: None,
        source_platform: None,
        is_sensitive: false,
        deleted_at: None,
        payload_path: None,
        ocr_text: None,
        metadata_json: None,
        kind: "text".to_string(),
        tags: Vec::new(),
    };
    repo_a.save_item(&item, Some("Sync payload")).unwrap();

    // Device A pushes
    let push_rep = engine_a.push(&repo_a).unwrap();
    assert_eq!(push_rep.pushed_count, 1);

    // Device B pulls
    let pull_rep = engine_b.pull(&repo_b).unwrap();
    assert_eq!(pull_rep.pulled_count, 1);

    let detail_b = repo_b.get_item_detail("item-sync-1").unwrap();
    assert_eq!(detail_b.raw_text, Some("Sync payload".to_string()));
}

#[test]
fn test_webdav_backend_mock_server_flow() {
    use std::io::{BufRead, BufReader, Write};
    use std::net::TcpListener;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use nookclip_core::sync::WebDavBackend;

    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let running = Arc::new(AtomicBool::new(true));
    let r_clone = running.clone();

    let server_thread = std::thread::spawn(move || {
        listener.set_nonblocking(true).unwrap();
        let mut files: std::collections::HashMap<String, Vec<u8>> = std::collections::HashMap::new();

        while r_clone.load(Ordering::Relaxed) {
            match listener.accept() {
                Ok((mut stream, _)) => {
                    let mut reader = BufReader::new(stream.try_clone().unwrap());
                    let mut req_line = String::new();
                    if reader.read_line(&mut req_line).is_err() || req_line.is_empty() {
                        continue;
                    }
                    let parts: Vec<&str> = req_line.split_whitespace().collect();
                    if parts.len() < 2 {
                        continue;
                    }
                    let method = parts[0];
                    let path = parts[1].to_string();

                    let mut content_length = 0;
                    loop {
                        let mut line = String::new();
                        if reader.read_line(&mut line).is_err() || line == "\r\n" || line.is_empty() {
                            break;
                        }
                        if line.to_lowercase().starts_with("content-length:") {
                            if let Some(val) = line.split(':').nth(1) {
                                content_length = val.trim().parse::<usize>().unwrap_or(0);
                            }
                        }
                    }

                    let mut body = vec![0u8; content_length];
                    if content_length > 0 {
                        use std::io::Read;
                        let _ = reader.read_exact(&mut body);
                    }

                    match method {
                        "MKCOL" => {
                            let _ = stream.write_all(b"HTTP/1.1 201 Created\r\nContent-Length: 0\r\n\r\n");
                        }
                        "PROPFIND" => {
                            if path.contains("devices") && !files.keys().any(|k| k.starts_with("/devices")) {
                                // 首次同步时远程没有设备，返回 404
                                let _ = stream.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
                            } else if path.contains("devices") {
                                let mut xml = String::from("<?xml version=\"1.0\" encoding=\"utf-8\"?><d:multistatus xmlns:d=\"DAV:\">");
                                for (f_path, f_data) in &files {
                                    if f_path.starts_with("/devices") && f_path.ends_with(".pack") {
                                        xml.push_str(&format!(
                                            "<d:response><d:href>{}</d:href><d:propstat><d:prop><d:getetag>\"test-tag\"</d:getetag><d:getcontentlength>{}</d:getcontentlength></d:prop></d:propstat></d:response>",
                                            f_path, f_data.len()
                                        ));
                                    }
                                }
                                xml.push_str("</d:multistatus>");
                                let resp = format!("HTTP/1.1 207 Multi-Status\r\nContent-Length: {}\r\nContent-Type: application/xml\r\n\r\n{}", xml.len(), xml);
                                let _ = stream.write_all(resp.as_bytes());
                            } else if path.contains("assets") {
                                let mut xml = String::from("<?xml version=\"1.0\" encoding=\"utf-8\"?><d:multistatus xmlns:d=\"DAV:\"><d:response><d:href>/assets/</d:href><d:propstat><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>");
                                for f_path in files.keys() {
                                    if f_path.starts_with("/assets/") {
                                        xml.push_str(&format!(
                                            "<d:response><d:href>{}</d:href><d:propstat><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>",
                                            f_path
                                        ));
                                    }
                                }
                                xml.push_str("</d:multistatus>");
                                let resp = format!("HTTP/1.1 207 Multi-Status\r\nContent-Length: {}\r\nContent-Type: application/xml\r\n\r\n{}", xml.len(), xml);
                                let _ = stream.write_all(resp.as_bytes());
                            } else {
                                let _ = stream.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
                            }
                        }
                        "PUT" => {
                            files.insert(path, body);
                            let _ = stream.write_all(b"HTTP/1.1 201 Created\r\nContent-Length: 0\r\n\r\n");
                        }
                        "GET" => {
                            if let Some(data) = files.get(&path) {
                                let resp = format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n", data.len());
                                let _ = stream.write_all(resp.as_bytes());
                                let _ = stream.write_all(data);
                            } else {
                                let _ = stream.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
                            }
                        }
                        "HEAD" => {
                            if files.contains_key(&path) {
                                let _ = stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n");
                            } else {
                                let _ = stream.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
                            }
                        }
                        _ => {
                            let _ = stream.write_all(b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n");
                        }
                    }
                }
                Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(std::time::Duration::from_millis(5));
                }
                Err(_) => break,
            }
        }
    });

    let base_url = format!("http://127.0.0.1:{}", port);
    let backend = WebDavBackend::new(base_url, "user".into(), "pass".into(), 5);

    // 1. Layout initialization
    assert!(backend.ensure_layout().is_ok());

    // 2. Initial empty packs check (should not fail with 404!)
    let packs = backend.list_device_packs().unwrap();
    assert!(packs.is_empty());

    // 3. Direct write pack
    let pack_payload = b"test-device-pack-bytes";
    backend.write_device_pack_atomic("phone-ios", pack_payload).unwrap();

    // 4. Read back pack
    let read_back = backend.read_device_pack("phone-ios").unwrap();
    assert_eq!(read_back, pack_payload);

    // 5. Pack list now includes phone-ios
    let packs_after = backend.list_device_packs().unwrap();
    assert_eq!(packs_after.len(), 1);
    assert_eq!(packs_after[0].device_id, "phone-ios");

    // 6. Write & read asset
    let asset_bytes = b"image-payload-data";
    backend.write_asset_atomic("test-asset.png", asset_bytes).unwrap();
    assert!(backend.has_asset("test-asset.png").unwrap());
    let read_asset = backend.read_asset("test-asset.png").unwrap();
    assert_eq!(read_asset, asset_bytes);
    let asset_list = backend.list_assets().unwrap();
    assert_eq!(asset_list.len(), 1);
    assert!(asset_list.contains("test-asset.png"));

    // 7. Write & read manifest
    let manifest_bytes = b"manifest-binary-data";
    backend.write_manifest_atomic(manifest_bytes).unwrap();
    let read_manifest = backend.read_manifest().unwrap();
    assert_eq!(read_manifest, Some(manifest_bytes.to_vec()));

    running.store(false, Ordering::Relaxed);
    let _ = server_thread.join();
}

#[test]
fn test_webdav_backend_error_handling_and_recovery() {
    use std::io::{BufRead, BufReader, Write};
    use std::net::TcpListener;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use nookclip_core::CoreError;
    use nookclip_core::sync::WebDavBackend;
    use nookclip_core::sync::backend::SyncStorageBackend;

    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let running = Arc::new(AtomicBool::new(true));
    let r_clone = running.clone();

    let server_thread = std::thread::spawn(move || {
        listener.set_nonblocking(true).unwrap();

        while r_clone.load(Ordering::Relaxed) {
            match listener.accept() {
                Ok((mut stream, _)) => {
                    let mut reader = BufReader::new(stream.try_clone().unwrap());
                    let mut req_line = String::new();
                    if reader.read_line(&mut req_line).is_err() || req_line.is_empty() {
                        continue;
                    }
                    let parts: Vec<&str> = req_line.split_whitespace().collect();
                    if parts.len() < 2 {
                        continue;
                    }
                    let path = parts[1].to_string();

                    if path.contains("/error401") {
                        let _ = stream.write_all(b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n");
                    } else if path.contains("/error500") {
                        let _ = stream.write_all(b"HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n");
                    } else if path.contains("/drop") {
                        // 突然断开网络连接模拟
                        drop(stream);
                    } else {
                        let _ = stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n");
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(std::time::Duration::from_millis(5));
                }
                Err(_) => break,
            }
        }
    });

    // 1. 验证 401 Unauthorized 明确返回 SyncTransport 错误，且错误信息包含 401
    let backend_401 = WebDavBackend::new(
        format!("http://127.0.0.1:{port}/error401"),
        "bad_user".into(),
        "bad_pass".into(),
        2,
    );
    let res_401 = backend_401.list_device_packs();
    assert!(res_401.is_err());
    if let Err(CoreError::SyncTransport(msg)) = res_401 {
        assert!(msg.contains("401"), "错误信息必须指明 401: {}", msg);
    } else {
        panic!("Expected SyncTransport error for 401");
    }

    // 2. 验证 500 Internal Server Error 明确返回 SyncTransport 错误
    let backend_500 = WebDavBackend::new(
        format!("http://127.0.0.1:{port}/error500"),
        "user".into(),
        "pass".into(),
        2,
    );
    let res_500 = backend_500.read_device_pack("dev-crash");
    assert!(res_500.is_err());
    if let Err(CoreError::SyncTransport(msg)) = res_500 {
        assert!(msg.contains("500"), "错误信息必须指明 500: {}", msg);
    } else {
        panic!("Expected SyncTransport error for 500");
    }

    // 3. 验证连接中断 / 网络超时防御
    let backend_drop = WebDavBackend::new(
        format!("http://127.0.0.1:{port}/drop"),
        "user".into(),
        "pass".into(),
        1,
    );
    let res_drop = backend_drop.list_device_packs();
    assert!(res_drop.is_err());
    assert!(matches!(res_drop, Err(CoreError::SyncTransport(_))));

    running.store(false, Ordering::Relaxed);
    let _ = server_thread.join();
}
