use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
static SYNC_RUNNING: AtomicBool = AtomicBool::new(false);
use std::time::Duration;
use futures::StreamExt;
use tauri::{AppHandle, Manager, Emitter};
use crate::{AppState, device};
use crate::arrow::{upload_meta_to_ipc, UploadMeta};
use crate::sync::stream_sync::StreamSyncWriter;
use serde_json::{json, Value as JsonValue};
use arrow::record_batch::RecordBatch;
use arrow_array::StringArray;

// Either stream from a vault file (no RAM for file bytes) or use in-memory bytes (legacy blobs).
enum FileSource {
    VaultFile(String),
    Bytes(Vec<u8>),
}

// ── XRPC MsgPack upload envelope ─────────────────────────────────────────
#[derive(serde::Serialize)]
struct XrpcUpload<'a> {
    doc_id:             &'a str,
    filename:           &'a str,
    content_type:       &'a str,
    #[serde(with = "serde_bytes")]
    file_content:       &'a [u8],
    #[serde(with = "serde_bytes")]
    automerge_state:    &'a [u8],
    epoch_id:           Option<u32>,
    text_content:       &'a str,
    last_modified_at:   &'a str,
    device_id:          &'a str,
    #[serde(with = "serde_bytes")]
    pub arrow_metadata_ipc: &'a [u8],
    pub vault_category:     &'a str,
}


// ══════════════════════════════════════════════════════════════════════════
// Background Sync Engine
// ══════════════════════════════════════════════════════════════════════════

pub async fn start(app: AppHandle) {
    log::info!("🔄 [CRDT Sync] Background sync engine started");
    
    // Start SSE listener for instant sync
    let app_clone = app.clone();
    tokio::spawn(async move {
        let _ = start_listener(app_clone).await;
    });

    tokio::time::sleep(Duration::from_secs(3)).await;

    loop {
        match run_sync_cycle(&app).await {
            Ok((pushed, pulled)) => {
                if pushed > 0 || pulled > 0 {
                    log::info!("[CRDT Sync] ✅ Pushed: {}, Pulled: {}", pushed, pulled);
                }
            }
            Err(e) => log::warn!("[CRDT Sync] ❌ Sync error: {}", e),
        }
        tokio::time::sleep(Duration::from_secs(30)).await;
    }
}

async fn start_listener(app: AppHandle) -> Result<(), String> {
    log::info!("📡 [SSE] Starting real-time sync listener...");
    
    loop {
        let (server_url, access_token) = {
            let state = app.state::<AppState>();
            match state.lancedb.get_identity().await {
                Ok(Some(batch)) if batch.num_rows() > 0 => {
                    let s_url = batch.column(5).as_any().downcast_ref::<arrow_array::StringArray>().unwrap().value(0).to_string();
                    let token = crate::vault::load_token_from_keyring().ok().flatten().unwrap_or_default();
                    (s_url, token)
                }
                _ => {
                    tokio::time::sleep(Duration::from_secs(5)).await;
                    continue;
                }
            }
        };

        if access_token.is_empty() {
            tokio::time::sleep(Duration::from_secs(5)).await;
            continue;
        }

        let client = reqwest::Client::new();
        let stream_url = format!("{}/api/v1/sync/stream", server_url);
        
        match client.get(&stream_url)
            .header("Authorization", format!("Bearer {}", access_token))
            .send().await {
            Ok(response) => {
                let mut stream = response.bytes_stream();
                log::info!("✅ [SSE] Connected to {}", stream_url);
                
                while let Some(item) = stream.next().await {
                    match item {
                        Ok(bytes) => {
                            let text = String::from_utf8_lossy(&bytes);
                            if text.contains("event: sync_nudge") {
                                log::info!("🔔 [SSE] Received sync nudge! Triggering instant cycle...");
                                let _ = run_sync_cycle(&app).await;
                            }
                        }
                        Err(e) => {
                            log::warn!("⚠️ [SSE] Stream error: {}", e);
                            break;
                        }
                    }
                }
            }
            Err(e) => {
                log::warn!("⚠️ [SSE] Connection failed: {}. Retrying in 10s...", e);
            }
        }
        
        tokio::time::sleep(Duration::from_secs(10)).await;
    }
}

// ══════════════════════════════════════════════════════════════════════════
// Main Sync Cycle
// ══════════════════════════════════════════════════════════════════════════

pub async fn run_sync_cycle(app: &AppHandle) -> Result<(usize, usize), String> {
    if SYNC_RUNNING.swap(true, Ordering::SeqCst) {
        log::warn!("[Sync] Sync already in progress, skipping loop");
        return Ok((0, 0));
    }

    let result = async {
        let state = app.state::<AppState>();
        
        log::info!("═══════════════════════════════════════════");
        log::info!("[Sync] Starting sync cycle via LanceDB...");

        let identity_batch_opt = match state.lancedb.get_identity().await {
            Ok(opt) => opt,
            Err(e) => {
                log::error!("[Sync] ❌ Identity read failed: {}", e);
                return Err(e.to_string());
            }
        };

        let (server_url, user_id) = match identity_batch_opt {
            Some(batch) if batch.num_rows() > 0 => {
                let s_url = batch.column(5).as_any().downcast_ref::<arrow::array::StringArray>().unwrap().value(0).to_string();
                let uid = batch.column(2).as_any().downcast_ref::<arrow::array::StringArray>().unwrap().value(0).to_string();
                (s_url, uid)
            }
            _ => {
                log::warn!("[Sync] ❌ No identity found");
                return Ok((0, 0));
            }
        };

        let access_token = match crate::vault::load_token_from_keyring() {
            Ok(Some(token)) => token,
            _ => {
                log::warn!("[Sync] ❌ No access token found in keychain");
                return Ok((0, 0));
            }
        };

        let device_id = device::get_or_create_device_id(&state.lancedb).await?;

        let pushed = push_documents(&state.lancedb, &server_url, &access_token, &device_id, app).await?;
        let pulled = pull_documents(&state.lancedb, &server_url, &access_token, &device_id).await?;

        let _ = state.lancedb.update_last_sync_at().await;
        emit_sync_status(&state.lancedb, app).await;

        log::info!("[Sync] Cycle complete: pushed={}, pulled={}", pushed, pulled);
        log::info!("═══════════════════════════════════════════");

        Ok((pushed, pulled))
    }.await;

    SYNC_RUNNING.store(false, Ordering::SeqCst);
    result
}

// ══════════════════════════════════════════════════════════════════════════
// PUSH
// ══════════════════════════════════════════════════════════════════════════

struct PendingDoc {
    doc_id:           String,
    filename:         String,
    automerge_state:  Vec<u8>,
    text_content:     String,
    binary_content:   Option<Vec<u8>>,
    content_type:     String,
    last_modified_at: String,
    status:           String,
    vault_path:       Option<String>,
    epoch_id:         Option<i64>,
    vault_category:   String,
    version:          i64,
    created_at:       String,
    file_size:        i64,
}

async fn push_documents(
    ldb: &crate::db::lancedb::LanceDBManager,
    server_url: &str,
    access_token: &str,
    device_id: &str,
    app: &AppHandle,
) -> Result<usize, String> {
    log::info!("[Push] Checking for pending documents in LanceDB...");

    let mut pending: Vec<PendingDoc> = Vec::new();
    let table = ldb.open_table("documents").await.map_err(|e| e.to_string())?;
    let mut stream = table.query().filter("status = 'pending'").execute().await.map_err(|e| e.to_string())?;

    while let Some(batch_res) = stream.next().await {
        let batch = batch_res.map_err(|e| e.to_string())?;
        
        let id_col = batch.column(0).as_any().downcast_ref::<arrow::array::StringArray>().unwrap();
        let name_col = batch.column(1).as_any().downcast_ref::<arrow::array::StringArray>().unwrap();
        let automerge_col = batch.column(2).as_any().downcast_ref::<arrow::array::BinaryArray>().unwrap();
        let text_col = batch.column(3).as_any().downcast_ref::<arrow::array::StringArray>().unwrap();
        let binary_col = batch.column(4).as_any().downcast_ref::<arrow::array::BinaryArray>().unwrap();
        let type_col = batch.column(5).as_any().downcast_ref::<arrow::array::StringArray>().unwrap();
        let path_col = batch.column(6).as_any().downcast_ref::<arrow::array::StringArray>().unwrap();
        let ver_col = batch.column(8).as_any().downcast_ref::<arrow::array::Int64Array>().unwrap();
        let created_col = batch.column(9).as_any().downcast_ref::<arrow::array::StringArray>().unwrap();
        let modified_col = batch.column(10).as_any().downcast_ref::<arrow::array::StringArray>().unwrap();
        let size_col = batch.column(11).as_any().downcast_ref::<arrow::array::Int64Array>().unwrap();
        let cat_col = batch.column(12).as_any().downcast_ref::<arrow::array::StringArray>().unwrap();
        let status_col = batch.column(13).as_any().downcast_ref::<arrow::array::StringArray>().unwrap();

        for i in 0..batch.num_rows() {
            pending.push(PendingDoc {
                doc_id:           id_col.value(i).to_string(),
                filename:         name_col.value(i).to_string(),
                automerge_state:  automerge_col.value(i).to_vec(),
                text_content:     if text_col.is_null(i) { String::new() } else { text_col.value(i).to_string() },
                binary_content:   if binary_col.is_null(i) { None } else { Some(binary_col.value(i).to_vec()) },
                content_type:     type_col.value(i).to_string(),
                last_modified_at: modified_col.value(i).to_string(),
                status:           status_col.value(i).to_string(),
                vault_path:       if path_col.is_null(i) { None } else { Some(path_col.value(i).to_string()) },
                epoch_id:         None,
                vault_category:   cat_col.value(i).to_string(),
                version:          ver_col.value(i),
                created_at:       created_col.value(i).to_string(),
                file_size:        size_col.value(i),
            });
        }
    }

    if pending.is_empty() {
        return Ok(0);
    }

    let semaphore = Arc::new(tokio::sync::Semaphore::new(4));
    let mut join_set = tokio::task::JoinSet::new();

    for doc in pending {
        let ldb_clone  = ldb.clone();
        let server     = server_url.to_string();
        let token      = access_token.to_string();
        let dev_id     = device_id.to_string();
        let sem        = Arc::clone(&semaphore);
        let app_clone  = app.clone();

        join_set.spawn(async move {
            let _permit = sem.acquire_owned().await.map_err(|e| format!("Semaphore error: {}", e))?;

            let file_bytes = if let Some(ref vp) = doc.vault_path {
                tokio::fs::read(vp).await.map_err(|e| format!("Read error: {}", e))?
            } else if let Some(blob) = doc.binary_content {
                blob
            } else {
                doc.text_content.as_bytes().to_vec()
            };

            let automerge_b64 = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, &doc.automerge_state);

            let upload_result = try_presigned_upload(
                &server, &doc.doc_id, &doc.filename, &doc.content_type,
                &automerge_b64, &file_bytes, &doc.text_content, &dev_id,
                &doc.last_modified_at, &token, file_bytes.len(), doc.epoch_id.map(|e| e as u32)
            ).await;

            let table = ldb_clone.open_table("documents").await?;
            match upload_result {
                Ok(_) => {
                    table.update().set("status", "'synced'").where_clause(format!("id = '{}'", doc.doc_id)).execute().await?;
                    let _ = app_clone.emit("sync-status", serde_json::json!({"id": doc.doc_id, "status": "synced"}));
                    Ok((doc.doc_id, true))
                }
                Err(e) => {
                    table.update().set("status", "'failed'").where_clause(format!("id = '{}'", doc.doc_id)).execute().await?;
                    let _ = app_clone.emit("sync-status", serde_json::json!({"id": doc.doc_id, "status": "failed", "error": e}));
                    Ok((doc.doc_id, false))
                }
            }
        });
    }

    let mut pushed = 0;
    while let Some(result) = join_set.join_next().await {
        if let Ok(Ok((_, true))) = result { pushed += 1; }
    }
    Ok(pushed)
}

// ══════════════════════════════════════════════════════════════════════════
// PULL
// ══════════════════════════════════════════════════════════════════════════

async fn pull_documents(
    ldb: &crate::db::lancedb::LanceDBManager,
    server_url: &str,
    access_token: &str,
    device_id: &str,
) -> Result<usize, String> {
    log::info!("[Pull] Pulling remote updates from Phoenix...");
    let last_sync = ldb.get_last_sync_at().await?;

    let client = reqwest::Client::new();
    let body = serde_json::json!({
        "requests": [
            {
                "type": "execute",
                "stmt": {
                    "sql": "SELECT id, filename, device_id, last_modified_atUpdated_at FROM documents WHERE user_id = ? AND updated_at > ? ORDER BY updated_at ASC",
                    "args": [{"type": "text", "value": user_id}, {"type": "text", "value": last_sync}]
                }
            },
            {"type": "close"}
        ]
    });

    let response = client.get(format!("{}/api/v1/sync/changes", server_url))
        .header("Authorization", format!("Bearer {}", access_token))
        .query(&[("since", last_sync)])
        .send().await.map_err(|e| e.to_string())?;

    if !response.status().is_success() { return Ok(0); }

    let result: serde_json::Value = response.json().await.map_err(|e| e.to_string())?;
    let rows = result["results"][0]["response"]["result"]["rows"].as_array().unwrap_or(&vec![]);

    let mut pulled = 0;
    let table = ldb.open_table("documents").await?;

    for row in rows {
        let remote_id       = row["id"].as_str().unwrap_or("").to_string();
        let remote_filename = row["filename"].as_str().unwrap_or("").to_string();
        let remote_device   = row["device_id"].as_str().unwrap_or("").to_string();
        let remote_modified = row["last_modified_at"].as_str().unwrap_or("").to_string();

        if remote_device == device_id { continue; }

        let mut stream = table.query().filter(format!("id = '{}'", remote_id)).execute().await?;
        if let Some(batch_res) = stream.next().await {
            let batch = batch_res.map_err(|e| e.to_string())?;
            if batch.num_rows() > 0 {
                // column 10 is last_modified_at
                let existing_modified = batch.column(10).as_any().downcast_ref::<arrow::array::StringArray>().unwrap().value(0);
                if existing_modified < remote_modified {
                    table.update()
                        .set("last_modified_at", format!("'{}'", remote_modified))
                        .set("status", "'synced'")
                        .where_clause(format!("id = '{}'", remote_id))
                        .execute().await?;
                    pulled += 1;
                }
            } else {
                // New document from remote - in a full implementation we'd download it here
                pulled += 1;
            }
        }
    }
    Ok(pulled)
}

// ══════════════════════════════════════════════════════════════════════════
// Presigned S3 Multipart
// ══════════════════════════════════════════════════════════════════════════

const MULTIPART_CHUNK_SIZE: usize = 5 * 1024 * 1024;

async fn try_presigned_upload(
    server_url:       &str,
    doc_id:           &str,
    filename:         &str,
    content_type:     &str,
    automerge_b64:    &str,
    file_bytes:       &[u8],
    text_content:     &str,
    device_id:        &str,
    last_modified_at: &str,
    token:            &str,
    file_size:        usize,
    epoch_id:         Option<u32>,
) -> Result<(), String> {
    let total_parts = file_size.div_ceil(MULTIPART_CHUNK_SIZE);
    let meta_client = reqwest::Client::builder().timeout(Duration::from_secs(30)).build().map_err(|e| e.to_string())?;

    let presign_resp = meta_client.post(format!("{}/api/v1/sync/upload-url", server_url))
        .header("Authorization", format!("Bearer {}", token))
        .json(&serde_json::json!({
            "doc_id": doc_id, "filename": filename, "content_type": content_type,
            "automerge_state": automerge_b64, "text_content": text_content,
            "device_id": device_id, "last_modified_at": last_modified_at,
            "file_size": file_size, "total_parts": total_parts, "epoch_id": epoch_id,
        })).send().await.map_err(|e| e.to_string())?;

    if !presign_resp.status().is_success() { return Err(format!("Presign failed: {}", presign_resp.status())); }

    let presign_json: serde_json::Value = presign_resp.json().await.map_err(|e| e.to_string())?;
    let upload_id = presign_json["upload_id"].as_str().ok_or("No upload_id")?.to_string();
    let s3_key = presign_json["s3_key"].as_str().ok_or("No s3_key")?.to_string();
    let part_urls: Vec<String> = presign_json["part_urls"].as_array().ok_or("No part_urls")?
        .iter().filter_map(|v| v.as_str().map(String::from)).collect();

    let sem = Arc::new(tokio::sync::Semaphore::new(6));
    let mut join_set = tokio::task::JoinSet::new();

    for (i, part_url) in part_urls.into_iter().enumerate() {
        let start = i * MULTIPART_CHUNK_SIZE;
        let end   = (start + MULTIPART_CHUNK_SIZE).min(file_size);
        let chunk = file_bytes[start..end].to_vec();
        let ct    = content_type.to_string();
        let pn    = i + 1;
        let sem   = Arc::clone(&sem);

        join_set.spawn(async move {
            let _permit = sem.acquire_owned().await.map_err(|e| e.to_string())?;
            let client = reqwest::Client::builder().timeout(Duration::from_secs(120)).build().map_err(|e| e.to_string())?;
            let resp = client.put(&part_url).header("Content-Type", &ct).body(chunk).send().await
                .map_err(|e| format!("Part {} failed: {}", pn, e))?;
            if !resp.status().is_success() { return Err(format!("Part {} status: {}", pn, resp.status())); }
            let etag = resp.headers().get("ETag").and_then(|v| v.to_str().ok())
                .map(|s| s.trim_matches('"').to_string()).ok_or_else(|| format!("No ETag in part {}", pn))?;
            Ok((pn, etag))
        });
    }

    let mut parts = Vec::new();
    while let Some(res) = join_set.join_next().await {
        parts.push(res.map_err(|e| e.to_string())??);
    }
    parts.sort_by_key(|(n, _)| *n);

    let notify_resp = meta_client.post(format!("{}/api/v1/sync/upload", server_url))
        .header("Authorization", format!("Bearer {}", token))
        .json(&serde_json::json!({
            "doc_id": doc_id, "filename": filename, "s3_key": s3_key, "upload_id": upload_id,
            "parts": parts, "content_type": content_type, "file_size": file_size, "epoch_id": epoch_id,
        })).send().await.map_err(|e| e.to_string())?;

    if !notify_resp.status().is_success() { return Err(format!("Finalize failed: {}", notify_resp.status())); }
    Ok(())
}

async fn emit_sync_status(ldb: &crate::db::lancedb::LanceDBManager, app: &AppHandle) {
    let counts = async {
        let table = match ldb.open_table("documents").await { Ok(t) => t, Err(_) => return (0, 0, 0, 0) };
        let mut pending = 0; let mut synced = 0; let mut failed = 0; let mut total = 0;
        if let Ok(mut stream) = table.query().execute().await {
            while let Some(Ok(batch)) = stream.next().await {
                total += batch.num_rows() as i64;
                if let Some(status_col) = batch.column(13).as_any().downcast_ref::<arrow::array::StringArray>() {
                    for i in 0..batch.num_rows() {
                        match status_col.value(i) { "pending" => pending += 1, "synced" => synced += 1, "failed" => failed += 1, _ => {} }
                    }
                }
            }
        }
        (pending, synced, failed, total)
    }.await;
    let _ = app.emit("sync-status", serde_json::json!({ "pending": counts.0, "synced": counts.1, "failed": counts.2, "total": counts.3 }));
}