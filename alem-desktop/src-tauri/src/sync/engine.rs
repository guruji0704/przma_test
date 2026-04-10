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

// Either stream from a vault file (no RAM for file bytes) or use in-memory bytes (legacy blobs).
enum FileSource {
    VaultFile(String),
    Bytes(Vec<u8>),
}

// ── XRPC MsgPack upload envelope ─────────────────────────────────────────
//
// Wire format:  Content-Type: application/x-msgpack
//               Body: rmp_serde::to_vec_named(&XrpcUpload { ... })
//
// Binary fields (file_content, automerge_state, arrow_metadata_ipc) use
// `#[serde(with = "serde_bytes")]` so rmp_serde encodes them as MsgPack
// bin type — compact binary, not a JSON-style array of integers.
//
// Server decodes via Alem.Plug.MsgpackParser (Msgpax binary: true):
//   file_content       → <<binary>> → Vault.CASStore → S3
//   arrow_metadata_ipc → <<binary>> → Arrow→Parquet  → S3
#[derive(serde::Serialize)]
struct XrpcUpload<'a> {
    doc_id:             &'a str,
    filename:           &'a str,
    content_type:       &'a str,
    #[serde(with = "serde_bytes")]
    file_content:       &'a [u8],           // raw vault bytes  (MsgPack bin)
    #[serde(with = "serde_bytes")]
    automerge_state:    &'a [u8],           // CRDT state bytes (MsgPack bin)
    epoch_id:           Option<u32>,        // vault v2 key epoch
    text_content:       &'a str,
    last_modified_at:   &'a str,
    device_id:          &'a str,
    #[serde(with = "serde_bytes")]
    arrow_metadata_ipc: &'a [u8],           // Arrow IPC snapshot (MsgPack bin)
}

fn sqld_url() -> String {
    "http://172.235.17.68:8080".to_string()
}

// ══════════════════════════════════════════════════════════════════════════
// Background Sync Engine
// ══════════════════════════════════════════════════════════════════════════

pub async fn start(app: AppHandle) {
    log::info!("🔄 [CRDT Sync] Background sync engine started");
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

// ══════════════════════════════════════════════════════════════════════════
// Main Sync Cycle
// ══════════════════════════════════════════════════════════════════════════

pub async fn run_sync_cycle(app: &AppHandle) -> Result<(usize, usize), String> {
    // 0. Prevent duplicate sync loops
    if SYNC_RUNNING.swap(true, Ordering::SeqCst) {
        log::warn!("[Sync] Sync already in progress, skipping loop");
        return Ok((0, 0));
    }

    let result = async {
        let state = app.state::<AppState>();
        
        log::info!("═══════════════════════════════════════════");
        log::info!("[Sync] Starting sync cycle...");

        // 1. Fetch Identity (Short-lived connection)
        let (server_url, access_token, user_id) = {
            let conn = crate::db::connect(&state.db).await.map_err(|e| e.to_string())?;
            let mut rows = conn.query(
                "SELECT server_url, access_token, user_id FROM local_identity WHERE id = 'singleton'",
                (),
            ).await.map_err(|e| e.to_string())?;

            if let Some(row) = rows.next().await.map_err(|e| e.to_string())? {
                let url = match row.get_value(0).ok() {
                    Some(libsql::Value::Text(s)) if !s.is_empty() => s,
                    _ => { log::warn!("[Sync] ❌ No server URL"); return Ok((0, 0)); }
                };
                let token = match row.get_value(1).ok() {
                    Some(libsql::Value::Text(s)) if !s.is_empty() => s,
                    _ => { log::warn!("[Sync] ❌ No access token"); return Ok((0, 0)); }
                };
                let uid = match row.get_value(2).ok() {
                    Some(libsql::Value::Text(s)) if !s.is_empty() => s,
                    _ => { log::warn!("[Sync] ❌ No user_id"); return Ok((0, 0)); }
                };
                (url, token, uid)
            } else {
                log::warn!("[Sync] ❌ No identity found");
                return Ok((0, 0));
            }
        };

        // 2. Fetch/Create Device ID (Short-lived connection)
        let device_id = {
            let conn = crate::db::connect(&state.db).await.map_err(|e| e.to_string())?;
            device::get_or_create_device_id(&conn).await?
        };

        let db = Arc::clone(&state.db);
        
        // 3. PUSH/PULL (These now manage their own internal short-lived connections)
        let pushed = push_documents(&db, &server_url, &access_token, &device_id, app).await?;
        let pulled = pull_documents(&db, &user_id, &device_id).await?;

        // 4. Final Updates (Short-lived connection)
        {
            let conn = crate::db::connect(&state.db).await.map_err(|e| e.to_string())?;
            conn.execute(
                "UPDATE local_identity SET last_sync_at = datetime('now') WHERE id = 'singleton'",
                (),
            ).await.map_err(|e| e.to_string())?;
            
            emit_sync_status(&conn, app).await;
        }

        log::info!("[Sync] Cycle complete: pushed={}, pulled={}", pushed, pulled);
        log::info!("═══════════════════════════════════════════");

        Ok((pushed, pulled))
    }.await;

    SYNC_RUNNING.store(false, Ordering::SeqCst);
    result
}

// ══════════════════════════════════════════════════════════════════════════
// PUSH: Upload local documents to Phoenix (S3 + sqld)
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
}

async fn push_documents(
    db: &Arc<libsql::Database>,
    server_url: &str,
    access_token: &str,
    device_id: &str,
    app: &AppHandle,
) -> Result<usize, String> {
    log::info!("[Push] Checking for pending documents...");

    let mut pending: Vec<PendingDoc> = Vec::new();

    {
        let conn = crate::db::connect(db).await.map_err(|e| e.to_string())?;
        let mut docs = conn.query(
            "SELECT id, filename, automerge_state, text_content,
                    binary_content, content_type, last_modified_at, status, vault_path, epoch_id
             FROM documents
             WHERE needs_upload = 1
             ORDER BY created_at ASC",
            (),
        ).await.map_err(|e| e.to_string())?;

        while let Some(row) = docs.next().await.map_err(|e| e.to_string())? {
            let doc_id = row.get_value(0).ok().and_then(|v| match v { libsql::Value::Text(s) => Some(s), _ => None }).unwrap_or_default();
            let filename = row.get_value(1).ok().and_then(|v| match v { libsql::Value::Text(s) => Some(s), _ => None }).unwrap_or_default();
            let automerge_state = row.get_value(2).ok().and_then(|v| match v { libsql::Value::Blob(b) => Some(b), _ => None }).unwrap_or_default();
            let text_content = row.get_value(3).ok().and_then(|v| match v { libsql::Value::Text(s) => Some(s), _ => None }).unwrap_or_default();
            let binary_content = row.get_value(4).ok().and_then(|v| match v { libsql::Value::Blob(b) if !b.is_empty() => Some(b), _ => None });
            let content_type = row.get_value(5).ok().and_then(|v| match v { libsql::Value::Text(s) => Some(s), _ => None }).unwrap_or_else(|| "application/octet-stream".to_string());
            let last_modified_at = row.get_value(6).ok().and_then(|v| match v { libsql::Value::Text(s) => Some(s), _ => None }).unwrap_or_default();
            let status = row.get_value(7).ok().and_then(|v| match v { libsql::Value::Text(s) => Some(s), _ => None }).unwrap_or_else(|| "pending".to_string());
            let vault_path = row.get_value(8).ok().and_then(|v| match v { libsql::Value::Text(s) if !s.is_empty() => Some(s), _ => None });
            let epoch_id = row.get_value(9).ok().and_then(|v| match v { libsql::Value::Integer(i) => Some(i), _ => None });

            pending.push(PendingDoc {
                doc_id, filename, automerge_state, text_content,
                binary_content, content_type, last_modified_at, status, vault_path, epoch_id,
            });
        }
    } // End of fetch connection scope

    if pending.is_empty() {
        log::info!("[Push] No documents to upload");
        return Ok(0);
    }

    log::info!("[Push] Uploading {} document(s) in parallel (max 8) to {}", pending.len(), server_url);

    // ── Parallel upload: up to 4 concurrent files (unlocked for speed) ──
    let semaphore = Arc::new(tokio::sync::Semaphore::new(4));
    let mut join_set: tokio::task::JoinSet<Result<(String, bool), String>> =
        tokio::task::JoinSet::new();

    for doc in pending {
        let db_clone   = Arc::clone(db);
        let server     = server_url.to_string();
        let token      = access_token.to_string();
        let dev_id     = device_id.to_string();
        let sem        = Arc::clone(&semaphore);
        let app_clone  = app.clone();

        join_set.spawn(async move {
            // Acquire concurrency slot
            let _permit = sem.acquire_owned().await
                .map_err(|e| format!("Semaphore error: {}", e))?;

            // ─── Phase 1: Determine file source (No DB connection needed yet) ───
            let file_source = if let Some(ref vp) = doc.vault_path {
                if !std::path::Path::new(vp.as_str()).exists() {
                     log::error!("[Push] Vault file missing: {}", vp);
                      if let Ok(conn) = crate::db::connect(&db_clone).await {
                          let _ = conn.execute(
                              "UPDATE documents SET status = 'failed' WHERE id = ?",
                              libsql::params![doc.doc_id.clone()],
                          ).await.map_err(|e| e.to_string())?;
                      }
                     let _ = app_clone.emit("sync-status",
                         serde_json::json!({"id": doc.doc_id, "status": "failed"}));
                     return Ok((doc.doc_id, false));
                }
                FileSource::VaultFile(vp.clone())
            } else if let Some(blob) = doc.binary_content.clone() {
                FileSource::Bytes(blob)
            } else {
                FileSource::Bytes(doc.text_content.as_bytes().to_vec())
            };

            // ─── Phase 2: Perform Upload (Streaming, NO DB connection held) ───
            let upload_result = if let FileSource::VaultFile(ref vp) = file_source {
                upload_crdt_document_stream(
                    &server,
                    doc.doc_id.as_str(),
                    doc.filename.as_str(),
                    doc.content_type.as_str(),
                    &doc.automerge_state,
                    vp.as_str(),
                    doc.text_content.as_str(),
                    dev_id.as_str(),
                    doc.last_modified_at.as_str(),
                    token.as_str(),
                    doc.epoch_id,
                ).await
            } else {
                upload_crdt_document(
                    &server,
                    &doc.doc_id,
                    &doc.filename,
                    &doc.content_type,
                    &doc.automerge_state,
                    file_source,
                    &doc.text_content,
                    &dev_id,
                    &doc.last_modified_at,
                    &token,
                    doc.epoch_id,
                ).await
            };

            // ─── Phase 3: Update DB status (Fresh short-lived connection) ───
            let conn = crate::db::connect(&db_clone).await
                .map_err(|e| format!("DB connect failed for update: {}", e))?;

            match upload_result {
                Ok(_) => {
                    log::info!("[Push] ✅ Successfully uploaded '{}'", doc.filename);
                    let _ = conn.execute(
                        "UPDATE documents SET is_synced = 1, needs_upload = 0, status = 'synced', last_synced_at = datetime('now') WHERE id = ?",
                        libsql::params![doc.doc_id.clone()],
                    ).await.map_err(|e| e.to_string())?;
                    let _ = app_clone.emit("sync-status",
                        serde_json::json!({"id": doc.doc_id, "status": "synced"}));
                    Ok((doc.doc_id, true))
                }
                Err(e) => {
                    log::error!("[Push] ❌ Failed '{}': {}", doc.filename, e);
                    let _ = conn.execute(
                        "UPDATE documents SET status = 'failed', last_error = ? WHERE id = ?",
                        libsql::params![e.clone(), doc.doc_id.clone()],
                    ).await.map_err(|e| e.to_string())?;
                    let _ = app_clone.emit("sync-status",
                        serde_json::json!({"id": doc.doc_id, "status": "failed", "error": e}));
                    Ok((doc.doc_id, false))
                }
            }
        });
    }

    let mut pushed = 0;
    while let Some(result) = join_set.join_next().await {
        match result {
            Ok(Ok((_, true)))  => pushed += 1,
            Ok(Ok((_, false))) => {}
            Ok(Err(e))         => log::error!("[Push] Task error: {}", e),
            Err(e)             => log::error!("[Push] Join error: {}", e),
        }
    }

    Ok(pushed)
}

// ══════════════════════════════════════════════════════════════════════════
// PULL: Download documents from sqld (metadata) + S3 (content)
// ══════════════════════════════════════════════════════════════════════════

async fn pull_documents(
    db: &Arc<libsql::Database>,
    user_id: &str,
    device_id: &str,
) -> Result<usize, String> {
    log::info!("[Pull] Pulling remote updates for user {}...", user_id);

    // 1. Get last sync time (Short-lived connection)
    let last_sync = {
        let conn = crate::db::connect(db).await.map_err(|e| e.to_string())?;
        get_last_sync_at(&conn).await?
    };

    // 2. Fetch remote metadata from sqld server
    let client = reqwest::Client::new();
    let body = serde_json::json!({
        "requests": [
            {
                "type": "execute",
                "stmt": {
                    "sql": "SELECT id, filename, device_id, last_modified_at, s3_content_key, updated_at FROM documents WHERE user_id = ? AND updated_at > ? ORDER BY updated_at ASC",
                    "args": [
                        {"type": "text", "value": user_id},
                        {"type": "text", "value": last_sync}
                    ]
                }
            },
            {"type": "close"}
        ]
    });

    let sqld_url_final = sqld_url();
    let response = match client
        .post(format!("{}/v3/pipeline", sqld_url_final))
        .header("content-type", "application/json")
        .json(&body)
        .send()
        .await
    {
        Ok(resp) => resp,
        Err(e) => {
            log::warn!("⚠️ [Pull] sqld server unreachable: {}", e);
            return Ok(0);
        }
    };

    if !response.status().is_success() {
        log::warn!("⚠️ [Pull] sqld server returned error status: {}", response.status());
        return Ok(0);
    }

    let result: serde_json::Value = response.json().await.map_err(|e| e.to_string())?;
    
    let rows = result["results"][0]["response"]["result"]["rows"]
        .as_array()
        .cloned()
        .unwrap_or_default();

    let mut pulled = 0;

    for row in rows {
        let remote_doc_id   = row[0]["value"].as_str().unwrap_or("").to_string();
        let remote_filename = row[1]["value"].as_str().unwrap_or("").to_string();
        let remote_device   = row[2]["value"].as_str().unwrap_or("").to_string();
        let remote_modified = row[3]["value"].as_str().unwrap_or("").to_string();
        let s3_content_key  = row[4]["value"].as_str().unwrap_or("").to_string();

        if remote_device == device_id { continue; }

        let text_content = if s3_content_key.is_empty() {
            "(In S3)".to_string()
        } else {
            format!("(S3: {})", s3_content_key)
        };

        if doc_exists(db, &remote_doc_id).await? {
            let conn = crate::db::connect(db).await.map_err(|e| e.to_string())?;
            let _ = conn.execute(
                "UPDATE documents SET text_content = ?, last_modified_at = ?, is_synced = 1, needs_upload = 0, status = 'synced' WHERE id = ? AND last_modified_at < ?",
                libsql::params![text_content, remote_modified.clone(), remote_doc_id, remote_modified],
            ).await.map_err(|e| e.to_string())?;
        } else {
            let conn = crate::db::connect(db).await.map_err(|e| e.to_string())?;
            let _ = conn.execute(
                "INSERT OR IGNORE INTO documents (id, filename, automerge_state, text_content, content_type, device_id, last_modified_at, is_synced, needs_upload, status) VALUES (?, ?, ?, ?, 'application/octet-stream', ?, ?, 1, 0, 'synced')",
                libsql::params![remote_doc_id, remote_filename.clone(), Vec::<u8>::new(), text_content, remote_device, remote_modified],
            ).await.map_err(|e| e.to_string())?;
            log::info!("[Pull] ✅ New doc: '{}'", remote_filename);
            pulled += 1;
        }
    }

    Ok(pulled)
}

// ══════════════════════════════════════════════════════════════════════════
// Upload a document to Phoenix /api/v1/sync/crdt/upload
//
// ALL files (any size) are sent as a single JSON POST with the file content
// base64-encoded in the `file_content_b64` field.
//
// Why not chunked uploads?
//   Chunked uploads wrote each chunk to `/tmp` on the server and assembled
//   them in `finalize_upload`.  When the server runs multiple OS processes
//   (behind nginx, in Docker, or with an Elixir cluster), chunk N and the
//   finalize request may land on different processes that have separate `/tmp`
//   directories — causing `:missing_chunk, N, :enoent` errors no matter how
//   many retries are added on the client side.
//
//   Sending the whole file as one JSON request is simpler, stateless, and
//   works correctly across any number of server processes.  The Plug.Parsers
//   `length: 100_000_000` limit (100 MB) on the server allows files up to
//   ~75 MB (since base64 adds ~33% overhead).  The 300 s client timeout
//   handles slow network connections.
//
// Retries up to 3 times (delays: 0 s, 1 s, 2 s) before returning Err.
// ══════════════════════════════════════════════════════════════════════════

async fn upload_crdt_document(
    server_url: &str,
    doc_id: &str,
    filename: &str,
    content_type: &str,
    automerge_state: &[u8],
    file_source: FileSource,
    text_content: &str,
    device_id: &str,
    last_modified_at: &str,
    token: &str,
    epoch_id: Option<i64>,
) -> Result<(), String> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(300))
        .build()
        .map_err(|e| format!("HTTP client error: {}", e))?;

    // Resolve file source to bytes once.
    let file_bytes: Vec<u8> = match file_source {
        FileSource::VaultFile(vault_path) => {
            tokio::fs::read(&vault_path).await
                .map_err(|e| format!("Cannot read vault file '{}': {}", vault_path, e))?
        }
        FileSource::Bytes(bytes) => bytes,
    };

    let file_size = file_bytes.len();

    // Use the epoch_id from the DB if available, fallback to header parsing
    let epoch_id = epoch_id.map(|id| id as u32).or_else(|| read_vault_epoch_id(&file_bytes));
    log::info!("[Upload] '{}' ({} bytes, epoch_id={:?})", filename, file_size, epoch_id);

    // ══════════════════════════════════════════════════════════════════════
    // XRPC MsgPack upload
    //
    // Wire:  POST /api/v1/sync/crdt/upload
    //        Content-Type: application/x-msgpack
    //        Body: XrpcUpload { file_content: <bin>, automerge_state: <bin>,
    //                           arrow_metadata_ipc: <bin>, ... }
    //
    // Binary fields are MsgPack bin (not base64 strings) — ~33% smaller
    // than JSON+base64 and decoded natively on the server.
    //
    // Server path:
    //   Alem.Plug.MsgpackParser decodes body into conn.params
    //   → file_content       → Vault.CASStore → S3
    //   → arrow_metadata_ipc → Arrow→Parquet  → S3  (analytics shard)
    //   → automerge_state    → sqld (CRDT metadata)
    // ══════════════════════════════════════════════════════════════════════
    let now_str = chrono::Utc::now().to_rfc3339();

    // Build Arrow IPC metadata snapshot (one row, metadata columns only).
    // This is the analytics record — sent alongside file bytes so the server
    // can write a Parquet shard in one round-trip.
    let meta = UploadMeta {
        doc_id,
        filename,
        content_type,
        file_size: file_size as i64,
        status:    "uploading",
        created_at: &now_str,
    };
    let arrow_ipc = match upload_meta_to_ipc(&meta) {
        Ok(b)  => b,
        Err(e) => {
            log::warn!("[Upload] Arrow IPC snapshot failed for '{}': {} — continuing without analytics", filename, e);
            vec![]
        }
    };

    let upload = XrpcUpload {
        doc_id,
        filename,
        content_type,
        file_content:       &file_bytes,
        automerge_state,
        epoch_id,
        text_content,
        last_modified_at,
        device_id,
        arrow_metadata_ipc: &arrow_ipc,
    };

    let msgpack_body = rmp_serde::to_vec_named(&upload)
        .map_err(|e| format!("MsgPack encode failed: {e}"))?;

    drop(upload);
    drop(arrow_ipc);
    drop(file_bytes);

    log::info!("[Upload] '{}' → XRPC MsgPack ({} bytes, arrow_ipc={} bytes)",
        filename, msgpack_body.len(), meta.file_size);

    let url = format!("{}/api/v1/sync/crdt/upload", server_url);

    // ── Retry loop: up to 3 attempts (0 s → 1 s → 2 s delays) ─────────────
    let mut last_err = String::new();

    for attempt in 0..3u32 {
        if attempt > 0 {
            tokio::time::sleep(Duration::from_secs(attempt as u64)).await;
            log::warn!("[Upload] Retry {}/3 for '{}'", attempt + 1, filename);
        }

        match client
            .post(&url)
            .header("Authorization", format!("Bearer {}", token))
            .header("Content-Type", "application/x-msgpack")
            .body(msgpack_body.clone())
            .send()
            .await
        {
            Ok(resp) if resp.status().is_success() => {
                log::info!("[Upload] ✅ '{}' uploaded via XRPC/MsgPack (attempt {})", filename, attempt + 1);
                return Ok(());
            }
            Ok(resp) => {
                let status    = resp.status();
                let body_text = resp.text().await.unwrap_or_default();
                last_err = format!("Upload failed ({}): {}", status, body_text);
                log::warn!("[Upload] Attempt {} failed for '{}': {}", attempt + 1, filename, last_err);
            }
            Err(e) => {
                last_err = format!("Network error: {}", e);
                log::warn!("[Upload] Attempt {} network error for '{}': {}", attempt + 1, filename, last_err);
            }
        }
    }

    Err(last_err)
}

/// New Streaming Upload using Arrow IPC batches wrapped in MessagePack.
/// Handles 1GB+ files with constant 5MB RAM usage.
async fn upload_crdt_document_stream(
    server_url: &str,
    doc_id: &str,
    filename: &str,
    content_type: &str,
    _automerge_state: &[u8],
    vault_path: &str,
    _text_content: &str,
    device_id: &str,
    last_modified_at: &str,
    token: &str,
    epoch_id: Option<i64>,
) -> Result<(), String> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(3600)) // 1 hour for large files
        .build()
        .map_err(|e| format!("HTTP client error: {}", e))?;
    let writer = StreamSyncWriter::new(doc_id);
    
    // Get file size for analytics
    let file_meta = tokio::fs::metadata(vault_path).await.map_err(|e| e.to_string())?;
    let file_size = file_meta.len() as i64;
    
    // Create Arrow Metadata IPC for server-side analytics (Track B)
    let analytic_meta = crate::arrow::UploadMeta {
        doc_id,
        filename,
        content_type,
        file_size,
        status: "synced",
        created_at: last_modified_at,
    };
    let arrow_meta_ipc = crate::arrow::upload_meta_to_ipc(&analytic_meta)?;

    let path = vault_path.to_string();

    // --- START V2 PARALLEL TRANSITION (Track A) ---
    // Instead of a single stream, we now use a parallel multipart dispatcher.

    // 1. INITIATE (v2/initiate)
    let init_payload = json!({
        "doc_id": doc_id,
        "filename": filename,
        "content_type": content_type,
        "arrow_metadata_ipc": serde_bytes::Bytes::new(&arrow_meta_ipc)
    });

    let init_resp = client
        .post(format!("{}/api/v1/sync/v2/initiate", server_url))
        .header("Authorization", format!("Bearer {}", token))
        .json(&init_payload)
        .send()
        .await
        .map_err(|e: reqwest::Error| format!("Initiate fail: {}", e))?;

    if !init_resp.status().is_success() {
        return Err(format!("V2 Initiate failed: {}", init_resp.text().await.unwrap_or_default()));
    }

    let init_data: JsonValue = init_resp.json().await.map_err(|e: reqwest::Error| e.to_string())?;
    let upload_id = init_data["upload_id"].as_str().ok_or("No upload_id returned")?.to_string();

    // 2. DISPATCH PARTS IN PARALLEL
    let part_stream = writer.file_to_raw_stream(path, 10 * 1024 * 1024).await
        .map_err(|e: anyhow::Error| e.to_string())?;

    let parts_results = part_stream
        .enumerate()
        .map(|(i, batch_res)| {
            let part_num = (i + 1) as i32;
            let client = client.clone();
            let server_url = server_url.to_string();
            let upload_id = upload_id.clone();
            let doc_id = doc_id.to_string();
            let filename = filename.to_string();
            let token = token.to_string();

            async move {
                let batch = batch_res.map_err(|e: anyhow::Error| e.to_string())?;
                
                // POST raw binary body to avoid multipart overhead/timeouts.
                // Metadata is passed via query string.
                let resp = client
                    .post(format!("{}/api/v1/sync/v2/part", server_url))
                    .query(&[
                        ("upload_id", upload_id),
                        ("doc_id", doc_id),
                        ("part_num", part_num.to_string()),
                        ("filename", filename),
                    ])
                    .header("Authorization", format!("Bearer {}", token))
                    .header("Content-Type", "application/octet-stream")
                    .body(batch) 
                    .send()
                    .await
                    .map_err(|e: reqwest::Error| e.to_string())?;

                if !resp.status().is_success() {
                    let err_txt = resp.text().await.map_err(|e: reqwest::Error| e.to_string())?;
                    return Err(format!("Part {} failed: {}", part_num, err_txt));
                }

                let data: JsonValue = resp.json().await.map_err(|e: reqwest::Error| e.to_string())?;
                let etag = data["etag"].as_str().ok_or("No etag")?.to_string();
                
                Ok::<JsonValue, String>(json!({ "part_num": part_num, "etag": etag }))
            }
        })
        .buffer_unordered(8) 
        .collect::<Vec<Result<JsonValue, String>>>()
        .await;

    let mut final_parts = Vec::new();
    for res in parts_results {
        final_parts.push(res?);
    }

    // 3. COMPLETE (v2/complete)
    let complete_payload = serde_json::json!({
        "doc_id": doc_id,
        "upload_id": upload_id,
        "filename": filename,
        "parts": final_parts,
        "device_id": device_id,
        "last_modified_at": last_modified_at,
        "file_size": file_size,
        "epoch_id": epoch_id
    });

    let complete_resp = client
        .post(format!("{}/api/v1/sync/v2/complete", server_url))
        .header("Authorization", format!("Bearer {}", token))
        .json(&complete_payload)
        .send()
        .await
        .map_err(|e: reqwest::Error| e.to_string())?;

    if !complete_resp.status().is_success() {
        return Err(format!("V2 Complete failed: {}", complete_resp.text().await.unwrap_or_default()));
    }

    log::info!("[V2 Parallel Sync] ✅ Successfully synced {} to S3", filename);
    Ok(())
}

// ══════════════════════════════════════════════════════════════════════════
// Presigned S3 Multipart Upload (large files >10 MB)
//
// Splits the file into 5 MB parts and uploads all parts in parallel over
// separate TCP connections.  A 30 MB file becomes 6 × 5 MB parts uploading
// concurrently — saturating the available uplink instead of a single stream.
//
// 3-step flow:
//   1. POST /upload-url  — server initiates S3 multipart upload, returns
//      { upload_id, part_urls: [url1, url2, ...], s3_key }.
//      Server also fires a parallel Task to write metadata to sqld
//      (status: "uploading") so the DB is populated while we upload.
//   2. PUT each part directly to S3 via its presigned URL, all in parallel.
//      Each PUT returns an ETag header.
//   3. POST /upload  — send all (part_number, etag) pairs to Phoenix.
//      Phoenix calls S3 CompleteMultipartUpload then flips sqld to "synced".
//
// Falls back to base64 JSON path if any step fails.
// ══════════════════════════════════════════════════════════════════════════

const MULTIPART_CHUNK_SIZE: usize = 5 * 1024 * 1024; // 5 MB (S3 minimum part size)

// ══════════════════════════════════════════════════════════════════════════
// Vault Header Parser
// ══════════════════════════════════════════════════════════════════════════

/// Read epoch_id from a v2 vault file header.
///
/// v2 layout: [4 magic][1 version=2][8 original_size][4 epoch_id][...]
/// Returns None for v1 files (version byte = 1) or invalid data.
fn read_vault_epoch_id(bytes: &[u8]) -> Option<u32> {
    if bytes.len() < 17 { return None; }
    if &bytes[0..4] != b"ALEM" { return None; }
    if bytes[4] != 2 { return None; }  // version must be 2
    Some(u32::from_le_bytes([bytes[13], bytes[14], bytes[15], bytes[16]]))
}

async fn try_presigned_upload(
    server_url:       &str,
    doc_id:           &str,
    filename:         &str,
    content_type:     &str,
    automerge_b64:    &str,
    file_bytes:       &[u8],    // borrow — stays available for base64 fallback
    text_content:     &str,
    device_id:        &str,
    last_modified_at: &str,
    token:            &str,
    file_size:        usize,
    epoch_id:         Option<u32>,  // from vault header — tells server which epoch key to use
) -> Result<(), String> {
    let total_parts = file_size.div_ceil(MULTIPART_CHUNK_SIZE);

    let meta_client = reqwest::Client::builder()
        .timeout(Duration::from_secs(30))
        .build()
        .map_err(|e| format!("HTTP client error: {}", e))?;

    // ── Step 1: request multipart presigned URLs ───────────────────────────
    // Server initiates S3 multipart upload and returns one presigned PUT URL
    // per part.  It also fires a background Task to write metadata to sqld
    // (status: "uploading") so both happen in parallel.
    log::info!(
        "[Presigned] Requesting {} presigned part URLs for '{}' ({} MB)",
        total_parts, filename, file_size / 1024 / 1024
    );

    let presign_resp = meta_client
        .post(format!("{}/api/v1/sync/upload-url", server_url))
        .header("Authorization", format!("Bearer {}", token))
        .json(&serde_json::json!({
            "doc_id":           doc_id,
            "filename":         filename,
            "content_type":     content_type,
            "automerge_state":  automerge_b64,
            "text_content":     text_content,
            "device_id":        device_id,
            "last_modified_at": last_modified_at,
            "file_size":        file_size,
            "total_parts":      total_parts,
            "epoch_id":         epoch_id,   // which server epoch key wrapped the file key
        }))
        .send()
        .await
        .map_err(|e| format!("Presign request failed: {}", e))?;

    if !presign_resp.status().is_success() {
        let status = presign_resp.status();
        let body   = presign_resp.text().await.unwrap_or_default();
        return Err(format!("Presign URL request failed ({}): {}", status, body));
    }

    let presign_json: serde_json::Value = presign_resp.json().await
        .map_err(|e| format!("Presign response parse error: {}", e))?;

    let upload_id = presign_json["upload_id"].as_str()
        .ok_or("Missing upload_id in presign response")?
        .to_string();
    let s3_key = presign_json["s3_key"].as_str()
        .ok_or("Missing s3_key in presign response")?
        .to_string();
    let part_urls: Vec<String> = presign_json["part_urls"]
        .as_array()
        .ok_or("Missing part_urls in presign response")?
        .iter()
        .filter_map(|v| v.as_str().map(String::from))
        .collect();

    if part_urls.len() != total_parts {
        return Err(format!(
            "Expected {} part URLs, got {}",
            total_parts, part_urls.len()
        ));
    }

    // ── Step 2: upload all parts in parallel ──────────────────────────────
    // Each part gets its own reqwest client and TCP connection.
    // While these PUTs are running, the server's Task.start has already
    // written the "uploading" metadata to sqld concurrently.
    log::info!(
        "[Presigned] Uploading '{}' in {} parallel parts × {} MB",
        filename, total_parts, MULTIPART_CHUNK_SIZE / 1024 / 1024
    );

    let sem = Arc::new(tokio::sync::Semaphore::new(6)); // cap at 6 concurrent S3 PUTs
    let mut join_set: tokio::task::JoinSet<Result<(usize, String), String>> =
        tokio::task::JoinSet::new();

    for (i, part_url) in part_urls.into_iter().enumerate() {
        let start = i * MULTIPART_CHUNK_SIZE;
        let end   = (start + MULTIPART_CHUNK_SIZE).min(file_size);
        let chunk = file_bytes[start..end].to_vec(); // only 5 MB copy per task
        let ct    = content_type.to_string();
        let pn    = i + 1;
        let sem   = Arc::clone(&sem);

        join_set.spawn(async move {
            let _permit = sem.acquire_owned().await.map_err(|e| e.to_string())?;

            let client = reqwest::Client::builder()
                .timeout(Duration::from_secs(120)) // 2 min per 5 MB part
                .build()
                .map_err(|e| format!("S3 part client error: {}", e))?;

            let resp = client
                .put(&part_url)
                .header("Content-Type", &ct)
                .body(chunk)
                .send()
                .await
                .map_err(|e| format!("Part {} PUT failed: {}", pn, e))?;

            if !resp.status().is_success() {
                let status = resp.status();
                let body   = resp.text().await.unwrap_or_default();
                return Err(format!("Part {} failed ({}): {}", pn, status, body));
            }

            // S3 returns the ETag — required to complete multipart upload
            let etag = resp
                .headers()
                .get("ETag")
                .and_then(|v| v.to_str().ok())
                .map(|s| s.trim_matches('"').to_string())
                .ok_or_else(|| format!("No ETag in part {} response", pn))?;

            log::info!("[Presigned] Part {}/{} ✅", pn, total_parts);
            Ok((pn, etag))
        });
    }

    // Collect all ETags, fail fast on any part error
    let mut parts: Vec<(usize, String)> = Vec::with_capacity(total_parts);
    while let Some(res) = join_set.join_next().await {
        match res {
            Ok(Ok((n, etag))) => parts.push((n, etag)),
            Ok(Err(e))        => return Err(format!("Multipart part failed: {}", e)),
            Err(e)            => return Err(format!("Task join error: {}", e)),
        }
    }
    parts.sort_by_key(|(n, _)| *n);

    log::info!("[Presigned] ✅ All {} parts uploaded for '{}'", total_parts, filename);

    // ── Step 3: complete multipart + flip sqld to "synced" ────────────────
    let parts_json: Vec<serde_json::Value> = parts
        .iter()
        .map(|(n, e)| serde_json::json!({"part_number": n, "etag": e}))
        .collect();

    let notify_resp = meta_client
        .post(format!("{}/api/v1/sync/upload", server_url))
        .header("Authorization", format!("Bearer {}", token))
        .json(&serde_json::json!({
            "doc_id":       doc_id,
            "filename":     filename,
            "s3_key":       s3_key,
            "upload_id":    upload_id,
            "parts":        parts_json,
            "content_type": content_type,
            "file_size":    file_size,
            "epoch_id":     epoch_id,   // server uses this to pick epoch private key for CAS
        }))
        .send()
        .await
        .map_err(|e| format!("Complete multipart request failed: {}", e))?;

    if !notify_resp.status().is_success() {
        let status = notify_resp.status();
        let body   = notify_resp.text().await.unwrap_or_default();
        return Err(format!("Complete multipart failed ({}): {}", status, body));
    }

    log::info!("[Presigned] ✅ Multipart complete + metadata synced for '{}'", filename);
    Ok(())
}

// ══════════════════════════════════════════════════════════════════════════
// Emit Sync Status to Frontend
// ══════════════════════════════════════════════════════════════════════════

async fn emit_sync_status(conn: &libsql::Connection, app: &AppHandle) {
    let counts = async {
        let pending = count_where(conn, "needs_upload = 1 AND status != 'failed'").await.unwrap_or(0);
        let synced  = count_where(conn, "is_synced = 1").await.unwrap_or(0);
        let failed  = count_where(conn, "status = 'failed'").await.unwrap_or(0);
        let total   = count_where(conn, "1=1").await.unwrap_or(0);
        (pending, synced, failed, total)
    }.await;

    let _ = app.emit("sync-status", serde_json::json!({
        "pending": counts.0,
        "synced":  counts.1,
        "failed":  counts.2,
        "total":   counts.3,
    }));
}

async fn count_where(conn: &libsql::Connection, condition: &str) -> Result<i64, String> {
    let sql = format!("SELECT COUNT(*) FROM documents WHERE {}", condition);
    let mut rows = conn.query(&sql, ()).await.map_err(|e| e.to_string())?;
    if let Some(row) = rows.next().await.map_err(|e| e.to_string())? {
        return Ok(match row.get_value(0).ok() {
            Some(libsql::Value::Integer(i)) => i,
            _ => 0,
        });
    }
    Ok(0)
}

// ══════════════════════════════════════════════════════════════════════════
// Helpers
// ══════════════════════════════════════════════════════════════════════════

async fn get_last_sync_at(conn: &libsql::Connection) -> Result<String, String> {
    let mut rows = conn.query(
        "SELECT last_sync_at FROM local_identity WHERE id = 'singleton'",
        (),
    ).await.map_err(|e| e.to_string())?;

    if let Some(row) = rows.next().await.map_err(|e| e.to_string())? {
        match row.get_value(0).ok() {
            Some(libsql::Value::Text(s)) if !s.is_empty() => return Ok(s),
            _ => {}
        }
    }
    Ok("2020-01-01T00:00:00Z".to_string())
}

async fn doc_exists(db: &Arc<libsql::Database>, id: &str) -> Result<bool, String> {
    let conn = crate::db::connect(db).await.map_err(|e| e.to_string())?;
    let mut rows = conn.query("SELECT 1 FROM documents WHERE id = ?", libsql::params![id]).await
        .map_err(|e| e.to_string())?;
    Ok(rows.next().await.map_err(|e| e.to_string())?.is_some())
}