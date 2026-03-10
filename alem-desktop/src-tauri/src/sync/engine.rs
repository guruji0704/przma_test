use crate::{AppState, device};
use std::time::Duration;
use tauri::{AppHandle, Manager, Emitter};
use base64::Engine;

const SQLD_URL: &str = "http://172.235.17.68:8080";
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
    let state = app.state::<AppState>();
    let conn  = state.db.connect().map_err(|e| e.to_string())?;

    log::info!("═══════════════════════════════════════════");
    log::info!("[Sync] Starting sync cycle...");

    let mut rows = conn.query(
        "SELECT server_url, access_token, user_id FROM local_identity WHERE id = 'singleton'",
        (),
    ).await.map_err(|e| e.to_string())?;

    let (server_url, access_token, user_id) =
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
        };

    let device_id = device::get_or_create_device_id(&conn).await?;

    let pushed = push_documents(&conn, &server_url, &access_token, &device_id, app).await?;
    let pulled = pull_documents(&conn, &user_id, &device_id).await?;

    conn.execute(
        "UPDATE local_identity SET last_sync_at = datetime('now') WHERE id = 'singleton'",
        (),
    ).await.map_err(|e| e.to_string())?;

    // Emit final sync status to frontend
    emit_sync_status(&conn, app).await;

    log::info!("[Sync] Cycle complete: pushed={}, pulled={}", pushed, pulled);
    log::info!("═══════════════════════════════════════════");

    Ok((pushed, pulled))
}

// ══════════════════════════════════════════════════════════════════════════
// PUSH: Upload local documents to Phoenix (S3 + sqld)
// ══════════════════════════════════════════════════════════════════════════

async fn push_documents(
    conn: &libsql::Connection,
    server_url: &str,
    access_token: &str,
    device_id: &str,
    app: &AppHandle,
) -> Result<usize, String> {
    log::info!("[Push] Checking for pending documents...");

    // ✅ KEY FIX: Select binary_content AND content_type in addition to text_content
    let mut docs = conn.query(
        "SELECT id, filename, automerge_state, text_content,
                binary_content, content_type, last_modified_at, status
         FROM documents
         WHERE needs_upload = 1
         ORDER BY created_at ASC",
        (),
    ).await.map_err(|e| e.to_string())?;

    struct PendingDoc {
        doc_id: String,
        filename: String,
        automerge_state: Vec<u8>,
        text_content: String,
        binary_content: Option<Vec<u8>>,
        content_type: String,
        last_modified_at: String,
        status: String,
    }

    let mut pending = Vec::new();

    while let Some(row) = docs.next().await.map_err(|e| e.to_string())? {
        let doc_id = match row.get_value(0).ok() {
            Some(libsql::Value::Text(s)) => s,
            _ => continue,
        };
        let filename = match row.get_value(1).ok() {
            Some(libsql::Value::Text(s)) => s,
            _ => continue,
        };
        let automerge_state = match row.get_value(2).ok() {
            Some(libsql::Value::Blob(b)) => b,
            _ => vec![],
        };
        let text_content = match row.get_value(3).ok() {
            Some(libsql::Value::Text(s)) => s,
            _ => String::new(),
        };
        // ✅ Read binary_content (may be NULL for text docs)
        let binary_content = match row.get_value(4).ok() {
            Some(libsql::Value::Blob(b)) if !b.is_empty() => Some(b),
            _ => None,
        };
        // ✅ Read content_type, default to text/plain
        let content_type = match row.get_value(5).ok() {
            Some(libsql::Value::Text(s)) if !s.is_empty() => s,
            _ => "text/plain".to_string(),
        };
        let last_modified_at = match row.get_value(6).ok() {
            Some(libsql::Value::Text(s)) => s,
            _ => chrono::Utc::now().to_rfc3339(),
        };
        let status = match row.get_value(7).ok() {
            Some(libsql::Value::Text(s)) => s,
            _ => "unknown".to_string(),
        };

        pending.push(PendingDoc {
            doc_id, filename, automerge_state, text_content,
            binary_content, content_type, last_modified_at, status,
        });
    }

    if pending.is_empty() {
        log::info!("[Push] No documents to upload");
        return Ok(0);
    }

    log::info!("[Push] Uploading {} document(s) to {}", pending.len(), server_url);

    let mut pushed = 0;

    for doc in pending {
        if doc.status == "failed" {
            log::info!("[Push] Retrying failed document: {}", doc.filename);
            let _ = conn.execute(
                "UPDATE documents SET status = 'pending' WHERE id = ?",
                libsql::params![doc.doc_id.clone()],
            ).await;
        }

        // ✅ KEY FIX: Choose actual file bytes to upload
        // For binary files (PDFs, images, etc.) → use binary_content
        // For text documents → use text_content bytes
        let file_bytes: Vec<u8> = if let Some(blob) = &doc.binary_content {
            log::info!(
                "[Push] '{}' → binary ({}, {} bytes)",
                doc.filename, doc.content_type, blob.len()
            );
            blob.clone()
        } else {
            log::info!(
                "[Push] '{}' → text ({} bytes)",
                doc.filename, doc.text_content.len()
            );
            doc.text_content.as_bytes().to_vec()
        };

        if file_bytes.is_empty() {
            log::warn!("[Push] ⚠️  '{}' has empty content — skipping to avoid blank S3 upload", doc.filename);
            let _ = conn.execute(
                "UPDATE documents SET status = 'failed' WHERE id = ?",
                libsql::params![doc.doc_id.clone()],
            ).await;
            let _ = app.emit("sync-status", serde_json::json!({"id": doc.doc_id, "status": "failed"}));
            continue;
        }

        match upload_crdt_document(
            server_url,
            &doc.doc_id,
            &doc.filename,
            &doc.content_type,
            &doc.automerge_state,
            file_bytes,
            &doc.text_content,
            device_id,
            &doc.last_modified_at,
            access_token,
        ).await {
            Ok(_) => {
                log::info!("[Push] ✅ Uploaded '{}'", doc.filename);

                let _ = conn.execute(
                    "UPDATE documents SET
                        is_synced    = 1,
                        needs_upload = 0,
                        status       = 'synced',
                        last_synced_at = datetime('now')
                     WHERE id = ?",
                    libsql::params![doc.doc_id.clone()],
                ).await;

                let _ = app.emit("sync-status", serde_json::json!({"id": doc.doc_id, "status": "synced"}));
                pushed += 1;
            }
            Err(e) => {
                log::error!("[Push] ❌ Failed '{}': {}", doc.filename, e);

                let _ = conn.execute(
                    "UPDATE documents SET status = 'failed' WHERE id = ?",
                    libsql::params![doc.doc_id.clone()],
                ).await;

                let _ = app.emit("sync-status", serde_json::json!({"id": doc.doc_id, "status": "failed"}));
            }
        }
    }

    Ok(pushed)
}

// ══════════════════════════════════════════════════════════════════════════
// PULL: Download documents from sqld (metadata) + S3 (content)
// ══════════════════════════════════════════════════════════════════════════

async fn pull_documents(
    conn: &libsql::Connection,
    user_id: &str,
    device_id: &str,
) -> Result<usize, String> {
    let last_sync = get_last_sync_at(conn).await?;

    let client = reqwest::Client::new();

    let body = serde_json::json!({
        "requests": [
            {
                "type": "execute",
                "stmt": {
                    "sql": "SELECT id, filename, device_id, last_modified_at, s3_content_key, updated_at
                            FROM documents
                            WHERE user_id = ? AND updated_at > ?
                            ORDER BY updated_at ASC",
                    "args": [
                        {"type": "text", "value": user_id},
                        {"type": "text", "value": last_sync}
                    ]
                }
            },
            {"type": "close"}
        ]
    });

    let response = client
        .post(format!("{}/v3/pipeline", SQLD_URL))
        .header("content-type", "application/json")
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("sqld pull failed: {}", e))?;

    let result: serde_json::Value = response.json().await
        .map_err(|e| format!("sqld parse failed: {}", e))?;

    let rows = result["results"][0]["response"]["result"]["rows"]
        .as_array()
        .cloned()
        .unwrap_or_default();

    let mut pulled = 0;

    for row in &rows {
        let remote_doc_id   = row[0]["value"].as_str().unwrap_or("").to_string();
        let remote_filename = row[1]["value"].as_str().unwrap_or("").to_string();
        let remote_device   = row[2]["value"].as_str().unwrap_or("").to_string();
        let remote_modified = row[3]["value"].as_str().unwrap_or("").to_string();
        let s3_content_key  = row[4]["value"].as_str().unwrap_or("").to_string();

        // Skip documents from this device — we already have them
        if remote_device == device_id {
            continue;
        }

        // Use s3_content_key as a note that content lives in S3
        // A full implementation would download from S3 here
        let text_content = if s3_content_key.is_empty() {
            "(Content in S3 — open to download)".to_string()
        } else {
            format!("(S3: {})", s3_content_key)
        };

        let exists = doc_exists(conn, &remote_doc_id).await?;

        if exists {
            conn.execute(
                "UPDATE documents SET
                    text_content     = ?,
                    last_modified_at = ?,
                    is_synced        = 1,
                    needs_upload     = 0,
                    status           = 'synced'
                 WHERE id = ? AND last_modified_at < ?",
                libsql::params![
                    text_content,
                    remote_modified.clone(),
                    remote_doc_id,
                    remote_modified,
                ],
            ).await.map_err(|e| e.to_string())?;
        } else {
            conn.execute(
                "INSERT OR IGNORE INTO documents (
                    id, filename, automerge_state, text_content,
                    content_type, device_id, last_modified_at,
                    is_synced, needs_upload, status
                ) VALUES (?, ?, ?, ?, 'application/octet-stream', ?, ?, 1, 0, 'synced')",
                libsql::params![
                    remote_doc_id,
                    remote_filename.clone(),
                    Vec::<u8>::new(),
                    text_content,
                    remote_device,
                    remote_modified,
                ],
            ).await.map_err(|e| e.to_string())?;

            log::info!("[Pull] ✅ New doc: '{}'", remote_filename);
            pulled += 1;
        }
    }

    Ok(pulled)
}

// ══════════════════════════════════════════════════════════════════════════
// Upload to Phoenix
// ══════════════════════════════════════════════════════════════════════════

async fn upload_crdt_document(
    server_url: &str,
    doc_id: &str,
    filename: &str,
    content_type: &str,
    automerge_state: &[u8],
    file_bytes: Vec<u8>,  // ✅ actual file bytes (binary or text)
    text_content: &str,   // kept for text docs metadata
    device_id: &str,
    last_modified_at: &str,
    token: &str,
) -> Result<(), String> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(60))
        .build()
        .map_err(|e| format!("HTTP client error: {}", e))?;

    let automerge_b64 = base64::engine::general_purpose::STANDARD.encode(automerge_state);

    // ✅ KEY FIX: Send actual file bytes as base64 so Phoenix can upload real content to S3
    let file_content_b64 = base64::engine::general_purpose::STANDARD.encode(&file_bytes);

    let url = format!("{}/api/v1/sync/crdt/upload", server_url);

    log::info!(
        "[Upload] POST {} | doc={} | file={} bytes | type={}",
        url, doc_id, file_bytes.len(), content_type
    );

    let response = client
        .post(&url)
        .header("Authorization", format!("Bearer {}", token))
        .json(&serde_json::json!({
            "doc_id":             doc_id,
            "filename":           filename,
            "content_type":       content_type,          // ✅ NEW
            "automerge_state":    automerge_b64,
            "file_content_b64":   file_content_b64,      // ✅ NEW: actual file bytes
            "text_content":       text_content,           // kept for text doc content
            "device_id":          device_id,
            "last_modified_at":   last_modified_at,
            "file_size":          file_bytes.len(),       // ✅ NEW
        }))
        .send()
        .await
        .map_err(|e| format!("Network error: {}", e))?;

    let status = response.status();
    if !status.is_success() {
        let body = response.text().await.unwrap_or_default();
        return Err(format!("Upload failed ({}): {}", status, body));
    }

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

async fn doc_exists(conn: &libsql::Connection, doc_id: &str) -> Result<bool, String> {
    let mut rows = conn.query(
        "SELECT 1 FROM documents WHERE id = ?",
        libsql::params![doc_id.to_string()],
    ).await.map_err(|e| e.to_string())?;
    Ok(rows.next().await.map_err(|e| e.to_string())?.is_some())
}