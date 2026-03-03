use crate::{AppState, device};
use std::time::Duration;
use tauri::{AppHandle, Manager, Emitter};
use base64::Engine;

const SQLD_URL: &str = "http://172.235.17.68:8080";

// ══════════════════════════════════════════════════════════════════════════
// Background Sync Engine - Starts on app launch
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
// Main Sync Cycle - MADE PUBLIC for manual triggering
// ══════════════════════════════════════════════════════════════════════════

pub async fn run_sync_cycle(app: &AppHandle) -> Result<(usize, usize), String> {
    let state = app.state::<AppState>();
    let conn  = state.db.connect().map_err(|e| e.to_string())?;

    log::info!("═══════════════════════════════════════════");
    log::info!("[Sync] Starting sync cycle...");

    // Check credentials
    let mut rows = conn.query(
        "SELECT server_url, access_token, user_id FROM local_identity WHERE id = 'singleton'",
        (),
    ).await.map_err(|e| e.to_string())?;

    let (server_url, access_token, user_id) = if let Some(row) = rows.next().await.map_err(|e| e.to_string())? {
        let url = match row.get_value(0).ok() {
            Some(libsql::Value::Text(s)) if !s.is_empty() => s,
            _ => {
                log::warn!("[Sync] ❌ No server URL - skipping sync");
                return Ok((0, 0));
            }
        };
        let token = match row.get_value(1).ok() {
            Some(libsql::Value::Text(s)) if !s.is_empty() => s,
            _ => {
                log::warn!("[Sync] ❌ No access token - user not logged in");
                return Ok((0, 0));
            }
        };
        let uid = match row.get_value(2).ok() {
            Some(libsql::Value::Text(s)) if !s.is_empty() => s,
            _ => {
                log::warn!("[Sync] ❌ No user_id");
                return Ok((0, 0));
            }
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
    app: &AppHandle, // Added AppHandle for events
) -> Result<usize, String> {
    log::info!("[Push] Checking for pending documents...");
    
    // ✅ REMOVED "AND status != 'failed'" to allow retries
    let mut docs = conn.query(
        "SELECT id, filename, automerge_state, text_content, last_modified_at, status
         FROM documents
         WHERE needs_upload = 1
         ORDER BY created_at ASC",
        (),
    ).await.map_err(|e| e.to_string())?;

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
            _ => continue,
        };
        let text_content = match row.get_value(3).ok() {
            Some(libsql::Value::Text(s)) => s,
            _ => String::new(),
        };
        let last_modified_at = match row.get_value(4).ok() {
            Some(libsql::Value::Text(s)) => s,
            _ => chrono::Utc::now().to_rfc3339(),
        };
        let status = match row.get_value(5).ok() {
            Some(libsql::Value::Text(s)) => s,
            _ => "unknown".to_string(),
        };
        
        pending.push((doc_id, filename, automerge_state, text_content, last_modified_at, status));
    }

    if pending.is_empty() {
        log::info!("[Push] No documents to upload");
        return Ok(0);
    }

    log::info!("[Push] Uploading {} document(s) to {}", pending.len(), server_url);

    let mut pushed = 0;

    for (doc_id, filename, automerge_state, text_content, last_modified_at, current_status) in pending {
        // ✅ FIX: If previously failed, reset to 'pending' visually before retry
        if current_status == "failed" {
            log::info!("[Push] Retrying failed document: {}", filename);
            conn.execute(
                "UPDATE documents SET status = 'pending' WHERE id = ?",
                libsql::params![doc_id.clone()],
            ).await.map_err(|e| e.to_string())?;
            
            // Emit event to frontend to update UI to "Pending"
            let _ = app.emit("sync-status", serde_json::json!({"id": doc_id, "status": "pending"}));
        }

        log::info!("[Push] Uploading '{}'...", filename);

        match upload_crdt_document(
            server_url,
            &doc_id,
            &filename,
            &automerge_state,
            &text_content,
            device_id,
            &last_modified_at,
            access_token,
        ).await {
            Ok(_) => {
                log::info!("[Push] ✅ Upload successful for '{}'", filename);
                
                conn.execute(
                    "UPDATE documents SET
                        is_synced = 1,
                        needs_upload = 0,
                        status = 'synced',
                        last_synced_at = datetime('now')
                     WHERE id = ?",
                    libsql::params![doc_id.clone()],
                ).await.map_err(|e| e.to_string())?;
                
                // Emit event to frontend to update UI to "Synced"
                let _ = app.emit("sync-status", serde_json::json!({"id": doc_id, "status": "synced"}));
                
                pushed += 1;
            }
            Err(e) => {
                log::error!("[Push] ❌ Upload failed for '{}': {}", filename, e);
                
                conn.execute(
                    "UPDATE documents SET status = 'failed' WHERE id = ?",
                    libsql::params![doc_id.clone()],
                ).await.map_err(|e| e.to_string())?;
                
                // Emit event to frontend to update UI to "Failed"
                let _ = app.emit("sync-status", serde_json::json!({"id": doc_id, "status": "failed"}));
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
        let remote_doc_id      = row[0]["value"].as_str().unwrap_or("").to_string();
        let remote_filename    = row[1]["value"].as_str().unwrap_or("").to_string();
        let remote_device      = row[2]["value"].as_str().unwrap_or("").to_string();
        let remote_modified    = row[3]["value"].as_str().unwrap_or("").to_string();
        let _s3_content_key    = row[4]["value"].as_str().unwrap_or("").to_string();

        if remote_device == device_id {
            continue;
        }

        let text_content = String::from("(Content in S3)");

        let exists = doc_exists(conn, &remote_doc_id).await?;

        if exists {
            conn.execute(
                "UPDATE documents SET
                    text_content = ?,
                    last_modified_at = ?,
                    is_synced = 1,
                    needs_upload = 0,
                    status = 'synced'
                 WHERE id = ? AND last_modified_at < ?",
                libsql::params![text_content, remote_modified.clone(), remote_doc_id, remote_modified],
            ).await.map_err(|e| e.to_string())?;
        } else {
            let empty_crdt: Vec<u8> = vec![];
            
            conn.execute(
                "INSERT OR IGNORE INTO documents (
                    id, filename, automerge_state, text_content,
                    device_id, last_modified_at,
                    is_synced, needs_upload, status
                ) VALUES (?, ?, ?, ?, ?, ?, 1, 0, 'synced')",
                libsql::params![
                    remote_doc_id,
                    remote_filename.clone(),
                    empty_crdt,
                    text_content,
                    remote_device,
                    remote_modified,
                ],
            ).await.map_err(|e| e.to_string())?;

            log::info!("[Pull] ✅ New: '{}'", remote_filename);
            pulled += 1;
        }
    }

    Ok(pulled)
}

// ══════════════════════════════════════════════════════════════════════════
// Upload to Phoenix (S3 + sqld)
// ══════════════════════════════════════════════════════════════════════════

async fn upload_crdt_document(
    server_url: &str,
    doc_id: &str,
    filename: &str,
    automerge_state: &[u8],
    text_content: &str,
    device_id: &str,
    last_modified_at: &str,
    token: &str,
) -> Result<(), String> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(30))
        .build()
        .map_err(|e| format!("HTTP client error: {}", e))?;

    let automerge_state_b64 = base64::engine::general_purpose::STANDARD.encode(automerge_state);
    let url = format!("{}/api/v1/sync/crdt/upload", server_url);

    let response = client
        .post(&url)
        .header("Authorization", format!("Bearer {}", token))
        .json(&serde_json::json!({
            "doc_id":           doc_id,
            "filename":         filename,
            "automerge_state":  automerge_state_b64,
            "text_content":     text_content,
            "device_id":        device_id,
            "last_modified_at": last_modified_at,
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
// Helper Functions
// ══════════════════════════════════════════════════════════════════════════

async fn get_last_sync_at(conn: &libsql::Connection) -> Result<String, String> {
    let mut rows = conn.query(
        "SELECT last_sync_at FROM local_identity WHERE id = 'singleton'",
        (),
    ).await.map_err(|e| e.to_string())?;

    if let Some(row) = rows.next().await.map_err(|e| e.to_string())? {
        match row.get_value(0).ok() {
            Some(libsql::Value::Text(s)) => Ok(s),
            _ => Ok("2020-01-01T00:00:00Z".to_string()),
        }
    } else {
        Ok("2020-01-01T00:00:00Z".to_string())
    }
}

async fn doc_exists(conn: &libsql::Connection, doc_id: &str) -> Result<bool, String> {
    let mut rows = conn.query(
        "SELECT 1 FROM documents WHERE id = ?",
        libsql::params![doc_id.to_string()],
    ).await.map_err(|e| e.to_string())?;

    Ok(rows.next().await.map_err(|e| e.to_string())?.is_some())
}