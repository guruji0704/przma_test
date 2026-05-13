use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
static SYNC_RUNNING: AtomicBool = AtomicBool::new(false);
use std::time::Duration;
use futures::StreamExt;
use lancedb::query::{ExecutableQuery, QueryBase};
use tauri::{AppHandle, Manager, Emitter};
use crate::{AppState, device};
use arrow_array::{StringArray, BinaryArray, Int64Array, Float32Array, FixedSizeListArray, Array};
use arrow::record_batch::{RecordBatch, RecordBatchIterator};
use arrow::datatypes::{Field, DataType};
use crate::sync::stream_sync::StreamSyncWriter;
use serde_json::{json, Value as JsonValue};

// Either stream from a vault file (no RAM for file bytes) or use in-memory bytes (legacy blobs).
enum FileSource {
    VaultFile(String),
    Bytes(Vec<u8>),
}


// ══════════════════════════════════════════════════════════════════════════
// Background Sync Engine
// ══════════════════════════════════════════════════════════════════════════

pub async fn start(app: AppHandle) {
    log::info!("🔄 [CRDT Sync] Background sync engine started (Event-Driven)");
    
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
        
        let state = app.state::<AppState>();
        tokio::select! {
            _ = state.sync_notify.notified() => {
                log::info!("🔔 [Sync] Triggered by local change or nudge");
            }
            _ = tokio::time::sleep(Duration::from_secs(300)) => {
                log::info!("💓 [Sync] Safety heartbeat pulse (5m)");
            }
        }
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
                                log::info!("🔔 [SSE] Received sync nudge! Triggering main loop...");
                                app.state::<AppState>().sync_notify.notify_one();
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
        
        // Helper to log to file
        let debug_log = |msg: &str| {
            use std::io::Write;
            if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open("C:/Users/dhina/OneDrive/Desktop/sync_debug.txt") {
                let _ = writeln!(f, "[{}] {}", chrono::Utc::now().to_rfc3339(), msg);
            }
        };

        debug_log("═══════════════════════════════════════════");
        debug_log("[Sync] Starting sync cycle via LanceDB...");

        let identity_batch_opt = match state.lancedb.get_identity().await {
            Ok(opt) => opt,
            Err(e) => {
                let msg = format!("[Sync] ❌ Identity read failed: {}", e);
                log::error!("{}", msg);
                debug_log(&msg);
                return Err(e.to_string());
            }
        };

        let (server_url, _user_id) = match identity_batch_opt {
            Some(batch) if batch.num_rows() > 0 => {
                let s_url = batch.column(5).as_any().downcast_ref::<arrow::array::StringArray>().unwrap().value(0).to_string();
                let uid = batch.column(2).as_any().downcast_ref::<arrow::array::StringArray>().unwrap().value(0).to_string();
                debug_log(&format!("✔ Identity found, server_url={}", s_url));
                (s_url, uid)
            }
            _ => {
                log::warn!("[Sync] ❌ No identity found");
                debug_log("❌ No identity found");
                return Ok((0, 0));
            }
        };

        // Try keyring first (best-effort), then fall back to LanceDB
        let access_token = {
            let from_keyring = crate::vault::load_token_from_keyring().ok().flatten();
            if let Some(t) = from_keyring {
                debug_log("✔ Token loaded from keyring");
                t
            } else {
                debug_log("ℹ Keyring empty, trying LanceDB...");
                match state.lancedb.get_access_token().await {
                    Ok(t) => {
                        debug_log(&format!("✔ Token loaded from LanceDB (len={})", t.len()));
                        t
                    },
                    Err(e) => {
                        let msg = format!("❌ No access token (keyring+LanceDB both failed): {}", e);
                        log::warn!("[Sync] {}", msg);
                        debug_log(&msg);
                        return Ok((0, 0));
                    }
                }
            }
        };

        let device_id = match device::get_or_create_device_id(&state.lancedb).await {
            Ok(did) => { debug_log(&format!("✔ Got device_id: {}", did)); did },
            Err(e) => { debug_log(&format!("❌ Failed device_id: {}", e)); return Err(e); }
        };

        let mut pushed = 0;
        
        debug_log("Pushing personal vault...");
        match push_documents(Arc::clone(&state.lancedb), "personal_vault", "personal", &server_url, &access_token, &device_id, app).await {
            Ok(n) => { pushed += n; debug_log(&format!("  Pushed {} to personal", n)); },
            Err(e) => { debug_log(&format!("  ❌ Push personal failed: {}", e)); return Err(e); }
        }
        
        debug_log("Pushing private vault...");
        match push_documents(Arc::clone(&state.lancedb), "private_vault", "private", &server_url, &access_token, &device_id, app).await {
            Ok(n) => { pushed += n; debug_log(&format!("  Pushed {} to private", n)); },
            Err(e) => { debug_log(&format!("  ❌ Push private failed: {}", e)); return Err(e); }
        }

        debug_log("Pushing social vault...");
        match push_documents(Arc::clone(&state.lancedb), "social_vault", "social", &server_url, &access_token, &device_id, app).await {
            Ok(n) => { pushed += n; debug_log(&format!("  Pushed {} to social", n)); },
            Err(e) => { debug_log(&format!("  ❌ Push social failed: {}", e)); return Err(e); }
        }

        debug_log("Pulling documents...");
        let pulled = match pull_documents(Arc::clone(&state.lancedb), &server_url, &access_token, &device_id).await {
            Ok(n) => { debug_log(&format!("  Pulled {} from server", n)); n },
            Err(e) => { debug_log(&format!("  ❌ Pull failed: {}", e)); return Err(e); }
        };

        let _ = state.lancedb.update_last_sync_at().await;
        emit_sync_status(&state.lancedb, app).await;

        log::info!("[Sync] Cycle complete: pushed={}, pulled={}", pushed, pulled);
        debug_log(&format!("✔ Cycle complete: p {}, p {}", pushed, pulled));
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
    version:          i64,
    created_at:       String,
    file_size:        i64,
}

async fn push_documents(
    ldb: Arc<crate::db::lancedb::LanceDBManager>,
    table_name: &str,
    vault_category: &str,
    server_url: &str,
    access_token: &str,
    device_id: &str,
    app: &AppHandle,
) -> Result<usize, String> {
    log::info!("[Push:{}] Checking for pending documents...", table_name);

    let mut pending: Vec<PendingDoc> = Vec::new();
    let table = ldb.open_table(table_name).await.map_err(|e: anyhow::Error| e.to_string())?;
    let mut stream = table.query().only_if("status = 'pending'").execute().await.map_err(|e| e.to_string())?;

    while let Some(batch_res) = stream.next().await {
        let batch = batch_res.map_err(|e| format!("Batch error: {}", e))?;
        
        // Helper to safely downcast
        macro_rules! get_str_col {
            ($col:expr, $name:expr) => {
                batch.column($col).as_any().downcast_ref::<arrow::array::StringArray>()
                    .ok_or_else(|| format!("Downcast failed for {} (col {})", $name, $col))?
            }
        }
        macro_rules! get_bin_col {
            ($col:expr, $name:expr) => {
                batch.column($col).as_any().downcast_ref::<arrow::array::BinaryArray>()
                    .ok_or_else(|| format!("Downcast failed for {} (col {})", $name, $col))?
            }
        }
        macro_rules! get_int_col {
            ($col:expr, $name:expr) => {
                batch.column($col).as_any().downcast_ref::<arrow::array::Int64Array>()
                    .ok_or_else(|| format!("Downcast failed for {} (col {})", $name, $col))?
            }
        }

        let id_col = get_str_col!(0, "id");
        let name_col = get_str_col!(1, "filename");
        let automerge_col = get_bin_col!(2, "automerge");
        let text_col = get_str_col!(3, "text_content");
        let binary_col = get_bin_col!(4, "binary_content");
        let type_col = get_str_col!(5, "content_type");
        let path_col = get_str_col!(6, "vault_path");
        let ver_col = get_int_col!(8, "version");
        let created_col = get_str_col!(9, "created_at");
        let modified_col = get_str_col!(10, "updated_at");
        let size_col = get_int_col!(11, "file_size");
        let status_col = get_str_col!(13, "status");
        let epoch_col = get_int_col!(16, "epoch_id");

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
                epoch_id:         if epoch_col.is_null(i) { None } else { Some(epoch_col.value(i)) },
                version:          ver_col.value(i),
                created_at:       created_col.value(i).to_string(),
                file_size:        size_col.value(i),
            });
        }
    }

    if pending.is_empty() {
        log::info!("[Push:{}] No pending documents to upload.", table_name);
        return Ok(0);
    }

    log::info!("[Push:{}] Found {} pending documents. Starting uploads...", table_name, pending.len());
    let semaphore = Arc::new(tokio::sync::Semaphore::new(4));
    let mut join_set: tokio::task::JoinSet<Result<(String, bool), String>> = tokio::task::JoinSet::new();

    for doc in pending {
        let ldb_clone  = ldb.clone();
        let server     = server_url.to_string();
        let token      = access_token.to_string();
        let dev_id     = device_id.to_string();
        let sem        = Arc::clone(&semaphore);
        let app_clone  = app.clone();
        let t_name     = table_name.to_string();
        let v_cat      = vault_category.to_string();

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
                &doc.last_modified_at, &token, file_bytes.len(), doc.epoch_id.filter(|&e| e > 0).map(|e| e as u32),
                &v_cat
            ).await;

            let table = ldb_clone.open_table(&t_name).await.map_err(|e| e.to_string())?;
            match upload_result {
                Ok(_) => {
                    table.update().column("status", "'synced'").only_if(format!("id = '{}'", doc.doc_id)).execute().await.map_err(|e| e.to_string())?;
                    let _ = app_clone.emit("sync-status", serde_json::json!({"id": doc.doc_id, "status": "synced"}));
                    Ok((doc.doc_id, true))
                }
                Err(e) => {
                    // Keep status as "pending" so the next sync cycle retries
                    log::error!("[Push:{}] Upload failed for '{}': {}. Will retry next sync.", t_name, doc.doc_id, e);
                    let _ = app_clone.emit("sync-status", serde_json::json!({"id": doc.doc_id, "status": "pending", "error": &e}));
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
    ldb: Arc<crate::db::lancedb::LanceDBManager>,
    server_url: &str,
    access_token: &str,
    device_id: &str,
) -> Result<usize, String> {
    log::info!("[Pull] Pulling remote updates from Phoenix...");
    let last_sync = ldb.get_last_sync_at().await.map_err(|e| e.to_string())?;

    let client = reqwest::Client::new();
    
    let response = client.get(format!("{}/api/v1/sync/changes", server_url))
        .header("Authorization", format!("Bearer {}", access_token))
        .query(&[("since", last_sync)])
        .send().await.map_err(|e| e.to_string())?;

    if !response.status().is_success() { return Ok(0); }

    let result: serde_json::Value = response.json().await.map_err(|e| e.to_string())?;
    let default_vec = vec![];
    let rows = result["changes"].as_array().unwrap_or(&default_vec);

    let mut pulled = 0;
    
    // Cache tables to avoid reopening in the loop
    let mut table_cache = std::collections::HashMap::new();

    for row in rows {
        let remote_id       = row["id"].as_str().unwrap_or("").to_string();
        let remote_device   = row["device_id"].as_str().unwrap_or("").to_string();
        let remote_modified = row["last_modified_at"].as_str().unwrap_or("").to_string();
        let category        = row["vault_category"].as_str().unwrap_or("private");

        if remote_device == device_id { continue; }

        let table_name = match category {
            "personal" => "personal_vault",
            "social"   => "social_vault",
            _          => "private_vault",
        };

        let table = if let Some(t) = table_cache.get(table_name) {
            t
        } else {
            let t = ldb.open_table(table_name).await.map_err(|e| e.to_string())?;
            table_cache.insert(table_name, t);
            table_cache.get(table_name).unwrap()
        };

        let mut stream = table.query().only_if(format!("id = '{}'", remote_id)).execute().await.map_err(|e| e.to_string())?;
        if let Some(batch_res) = stream.next().await {
            let batch = batch_res.map_err(|e| e.to_string())?;
            if batch.num_rows() > 0 {
                // Existing doc — update timestamp if server version is newer
                let existing_modified = batch.column(10).as_any().downcast_ref::<arrow::array::StringArray>().unwrap().value(0);
                if existing_modified < remote_modified.as_str() {
                    table.update()
                        .column("updated_at", format!("'{}'", remote_modified))
                        .column("status", "'synced'")
                        .only_if(format!("id = '{}'", remote_id))
                        .execute().await.map_err(|e| e.to_string())?;
                    pulled += 1;
                }
            } else {
                // New document from remote — download and store
                let download_url = row["download_url"].as_str().unwrap_or("");
                let filename     = row["filename"].as_str().unwrap_or("file");
                let content_type = row["content_type"].as_str().unwrap_or("application/octet-stream");
                let epoch_id     = row["epoch_id"].as_i64();

                if !download_url.is_empty() {
                    match fetch_and_store_remote_doc(
                        &ldb, &remote_id, filename, content_type,
                        download_url, table_name, epoch_id,
                    ).await {
                        Ok(()) => {
                            log::info!("[Pull] Stored new doc '{}' in {}", remote_id, table_name);
                            pulled += 1;
                        }
                        Err(e) => {
                            log::error!("[Pull] Failed to download '{}': {}", remote_id, e);
                        }
                    }
                }
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
    _automerge_b64:   &str,
    file_bytes:       &[u8],
    _text_content:    &str,
    device_id:        &str,
    last_modified_at: &str,
    token:            &str,
    file_size:        usize,
    epoch_id:         Option<u32>,
    vault_category:   &str,
) -> Result<(), String> {
    let meta_client = reqwest::Client::builder().timeout(Duration::from_secs(30)).build().map_err(|e| e.to_string())?;

    // 1. Initiate V2 Multipart Upload
    let initiate_resp = meta_client.post(format!("{}/api/v1/sync/v2/initiate", server_url))
        .header("Authorization", format!("Bearer {}", token))
        .json(&serde_json::json!({
            "doc_id": doc_id,
            "filename": filename,
            "content_type": content_type,
            "file_size": file_size,
            "vault_category": vault_category,
        })).send().await.map_err(|e| format!("Initiate request failed: {}", e))?;

    if !initiate_resp.status().is_success() {
        return Err(format!("Initiate failed: {}", initiate_resp.status()));
    }

    let init_json: serde_json::Value = initiate_resp.json().await.map_err(|e| e.to_string())?;
    let upload_id = init_json["upload_id"].as_str().ok_or("No upload_id in response")?.to_string();

    // 2. Upload Parts via Elixir Proxy
    let sem = Arc::new(tokio::sync::Semaphore::new(3)); // lower concurrency to not overload Elixir processing
    let mut join_set = tokio::task::JoinSet::new();

    let total_parts = file_size.div_ceil(MULTIPART_CHUNK_SIZE);

    for p in 0..total_parts {
        let start = p * MULTIPART_CHUNK_SIZE;
        let end   = (start + MULTIPART_CHUNK_SIZE).min(file_size);
        let chunk = file_bytes[start..end].to_vec();
        let pn    = p + 1; // 1-indexed parts
        
        let client_c = reqwest::Client::builder().timeout(Duration::from_secs(120)).build().unwrap();
        let sem_part = Arc::clone(&sem);
        let url = format!("{}/api/v1/sync/v2/part", server_url);
        let token_c = token.to_string();
        let upload_id_c = upload_id.clone();
        let doc_id_c = doc_id.to_string();
        let filename_c = filename.to_string();
        let vault_category_c = vault_category.to_string();

        join_set.spawn(async move {
            let _permit = sem_part.acquire_owned().await.map_err(|e| e.to_string())?;

            // Build the URL with query parameters since the file chunk is in the body
            let part_url = reqwest::Url::parse_with_params(&url, &[
                ("upload_id", upload_id_c),
                ("doc_id", doc_id_c),
                ("filename", filename_c),
                ("part_num", pn.to_string()),
                ("vault_category", vault_category_c),
            ]).map_err(|e| e.to_string())?;

            let resp = client_c.post(part_url)
                .header("Authorization", format!("Bearer {}", token_c))
                .header("Content-Type", "application/octet-stream")
                .body(chunk)
                .send().await
                .map_err(|e| format!("Part {} request failed: {}", pn, e))?;
                
            if !resp.status().is_success() {
                let status = resp.status();
                let err_text = resp.text().await.unwrap_or_default();
                return Err(format!("Part {} status: {} - {}", pn, status, err_text));
            }
            
            let json_resp: serde_json::Value = resp.json().await.map_err(|e| e.to_string())?;
            let etag = json_resp["etag"].as_str().ok_or_else(|| format!("No ETag in part {}", pn))?.to_string();
            
            Ok((pn, etag))
        });
    }

    let mut parts = Vec::new();
    while let Some(res) = join_set.join_next().await {
        parts.push(res.map_err(|e| e.to_string())??);
    }
    parts.sort_by_key(|(n, _)| *n);

    let parts_json = parts.into_iter().map(|(n, etag)| {
        serde_json::json!({
            "part_num": n,
            "etag": etag
        })
    }).collect::<Vec<_>>();

    // 3. Complete the Multipart Upload
    let complete_resp = meta_client.post(format!("{}/api/v1/sync/v2/complete", server_url))
        .header("Authorization", format!("Bearer {}", token))
        .json(&serde_json::json!({
            "doc_id": doc_id,
            "upload_id": upload_id,
            "filename": filename,
            "parts": parts_json,
            "device_id": device_id,
            "epoch_id": epoch_id,
            "vault_category": vault_category,
        })).send().await.map_err(|e| format!("Complete request failed: {}", e))?;

    if !complete_resp.status().is_success() {
        let status = complete_resp.status();
        let err_text = complete_resp.text().await.unwrap_or_default();
        return Err(format!("Complete failed: {} - {}", status, err_text));
    }

    Ok(())
}

// ══════════════════════════════════════════════════════════════════════════
// fetch_and_store_remote_doc
//
// Downloads a file from a presigned S3 URL and inserts it into the
// appropriate vault table with status "synced".  The bytes stored are the
// raw vault-encrypted bytes — decryption happens on open, not on pull.
// ══════════════════════════════════════════════════════════════════════════

async fn fetch_and_store_remote_doc(
    ldb:          &Arc<crate::db::lancedb::LanceDBManager>,
    doc_id:       &str,
    filename:     &str,
    content_type: &str,
    download_url: &str,
    table_name:   &str,
    epoch_id:     Option<i64>,
) -> Result<(), String> {
    let bytes = reqwest::get(download_url)
        .await.map_err(|e| format!("S3 fetch failed: {}", e))?
        .bytes()
        .await.map_err(|e| format!("Body read failed: {}", e))?
        .to_vec();

    let now   = chrono::Utc::now().to_rfc3339();
    let table = ldb.open_table(table_name).await.map_err(|e| e.to_string())?;

    // Delete any stale record before inserting
    let mut stream = table.query().only_if(format!("id = '{}'", doc_id)).execute().await.map_err(|e| e.to_string())?;
    if let Some(batch_res) = stream.next().await {
        if batch_res.map(|b| b.num_rows() > 0).unwrap_or(false) {
            table.delete(&format!("id = '{}'", doc_id)).await.map_err(|e| e.to_string())?;
        }
    }

    let schema = table.schema().await.map_err(|e| e.to_string())?;
    let batch  = RecordBatch::try_new(
        schema.clone(),
        vec![
            Arc::new(StringArray::from(vec![doc_id])),                                        // 0  id
            Arc::new(StringArray::from(vec![filename])),                                      // 1  filename
            Arc::new(BinaryArray::from(vec![None as Option<&[u8]>])),                         // 2  automerge_state
            Arc::new(StringArray::from(vec![None as Option<&str>])),                          // 3  text_content
            Arc::new(BinaryArray::from(vec![Some(bytes.as_slice())])),                        // 4  binary_content
            Arc::new(StringArray::from(vec![content_type])),                                  // 5  content_type
            Arc::new(StringArray::from(vec![None as Option<&str>])),                          // 6  vault_path
            Arc::new(StringArray::from(vec!["server"])),                                      // 7  device_id
            Arc::new(Int64Array::from(vec![1i64])),                                           // 8  version
            Arc::new(StringArray::from(vec![now.clone()])),                                   // 9  created_at
            Arc::new(StringArray::from(vec![now.clone()])),                                   // 10 updated_at
            Arc::new(Int64Array::from(vec![bytes.len() as i64])),                             // 11 file_size
            Arc::new(StringArray::from(vec!["personal"])),                                    // 12 vault_category
            Arc::new(StringArray::from(vec!["synced"])),                                      // 13 status
            Arc::new(FixedSizeListArray::try_new(
                Arc::new(Field::new("item", DataType::Float32, true)),
                128, Arc::new(Float32Array::from(vec![0.0f32; 128])), None,
            ).map_err(|e| e.to_string())?),                                                   // 14 vector
            Arc::new(StringArray::from(vec![None as Option<&str>])),                          // 15 content_hash
            Arc::new(Int64Array::from(vec![epoch_id])),                                       // 16 epoch_id
        ],
    ).map_err(|e| e.to_string())?;

    let reader = RecordBatchIterator::new(vec![Ok(batch)], schema);
    table.add(Box::new(reader)).execute().await.map_err(|e| e.to_string())?;
    Ok(())
}

async fn emit_sync_status(ldb: &crate::db::lancedb::LanceDBManager, app: &AppHandle) {
    let mut total_pending = 0;
    let mut total_synced = 0;
    let mut total_failed = 0;
    let mut total_count = 0;

    for table_name in &["personal_vault", "private_vault", "social_vault"] {
        if let Ok(table) = ldb.open_table(table_name).await {
            if let Ok(mut stream) = table.query().execute().await {
                while let Some(Ok(batch)) = stream.next().await {
                    total_count += batch.num_rows() as i64;
                    if let Some(status_col) = batch.column(13).as_any().downcast_ref::<arrow::array::StringArray>() {
                        for i in 0..batch.num_rows() {
                            match status_col.value(i) {
                                "pending" => total_pending += 1,
                                "synced" => total_synced += 1,
                                "failed" => total_failed += 1,
                                _ => {}
                            }
                        }
                    }
                }
            }
        }
    }

    let _ = app.emit("sync-status", serde_json::json!({
        "pending": total_pending,
        "synced": total_synced,
        "failed": total_failed,
        "total": total_count
    }));
}