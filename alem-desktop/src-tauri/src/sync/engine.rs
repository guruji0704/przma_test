use crate::{AppState, device};
use std::time::Duration;
use tauri::{AppHandle, Manager};
use base64::Engine;

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

async fn run_sync_cycle(app: &AppHandle) -> Result<(usize, usize), String> {
    let state = app.state::<AppState>();
    let conn  = state.db.connect().map_err(|e| e.to_string())?;

    log::info!("═══════════════════════════════════════════");
    log::info!("[Sync] Starting sync cycle...");

    // Check credentials AND get sqld_url
    let mut rows = conn.query(
        "SELECT server_url, access_token, user_id, sqld_url FROM local_identity WHERE id = 'singleton'",
        (),
    ).await.map_err(|e| e.to_string())?;

    let (server_url, access_token, user_id, sqld_url) = if let Some(row) = rows.next().await.map_err(|e| e.to_string())? {
        let url = get_text(&row, 0);
        let token = get_text(&row, 1);
        let uid = get_text(&row, 2);
        let sqld = get_text(&row, 3);
        
        if url.is_empty() || token.is_empty() { 
            log::warn!("[Sync] ❌ Missing credentials");
            return Ok((0, 0)); 
        }
        
        (url, token, uid, sqld)
    } else {
        log::warn!("[Sync] ❌ No identity found");
        return Ok((0, 0));
    };

    log::info!("[Sync] ✅ Credentials OK");
    log::info!("  Server: {}", server_url);
    log::info!("  User ID: {}", user_id);
    log::info!("  Sqld URL: {}", sqld_url);

    let device_id = device::get_or_create_device_id(&conn).await?;
    log::info!("[Sync] Device ID: {}", device_id);

    let pushed = push_documents(&conn, &server_url, &access_token, &device_id).await?;
    
    // Use dynamic sqld_url for pull
    let pulled = pull_documents(&conn, &user_id, &device_id, &sqld_url).await?;

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
) -> Result<usize, String> {
    log::info!("[Push] Checking for pending documents...");
    
    // (Counting logic omitted for brevity, same as original)

    let mut docs = conn.query(
        "SELECT id, filename, automerge_state, text_content, last_modified_at, status
         FROM documents
         WHERE needs_upload = 1
         ORDER BY created_at ASC",
        (),
    ).await.map_err(|e| e.to_string())?;

    let mut pending = Vec::new();
    while let Some(row) = docs.next().await.map_err(|e| e.to_string())? {
        let doc_id = get_text(&row, 0);
        let filename = get_text(&row, 1);
        let automerge_state = match row.get_value(2).ok() {
            Some(libsql::Value::Blob(b)) => b,
            _ => { log::warn!("[Push] Doc {} has no CRDT state!", doc_id); continue; }
        };
        let text_content = get_text(&row, 3);
        let last_modified_at = get_text(&row, 4);
        
        pending.push((doc_id, filename, automerge_state, text_content, last_modified_at));
    }

    if pending.is_empty() {
        log::info!("[Push] No documents to upload");
        return Ok(0);
    }

    log::info!("[Push] Uploading {} document(s) to {}", pending.len(), server_url);

    let mut pushed = 0;

    for (doc_id, filename, automerge_state, text_content, last_modified_at) in pending {
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
                conn.execute(
                    "UPDATE documents SET
                        is_synced = 1,
                        needs_upload = 0,
                        status = 'synced',
                        last_synced_at = datetime('now')
                     WHERE id = ?",
                    libsql::params![doc_id.clone()],
                ).await.map_err(|e| e.to_string())?;
                
                pushed += 1;
            }
            Err(e) => {
                log::error!("[Push] ❌ Upload failed for '{}': {}", filename, e);
                conn.execute(
                    "UPDATE documents SET status = 'failed' WHERE id = ?",
                    libsql::params![doc_id.clone()],
                ).await.map_err(|e| e.to_string())?;
            }
        }
    }

    Ok(pushed)
}

// ══════════════════════════════════════════════════════════════════════════
// PULL: Download documents from sqld
// ══════════════════════════════════════════════════════════════════════════

async fn pull_documents(
    conn: &libsql::Connection,
    user_id: &str,
    device_id: &str,
    sqld_url: &str, // Dynamic URL
) -> Result<usize, String> {
    // If sqld_url is empty, use fallback or skip
    if sqld_url.is_empty() {
        log::warn!("[Pull] No sqld_url configured, skipping pull");
        return Ok(0);
    }

    let last_sync = get_last_sync_at(conn).await?;

    let client = reqwest::Client::new();

    // Convert libsql:// to http:// if necessary
    let http_url = sqld_url.replace("libsql://", "http://");

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
        .post(format!("{}/v3/pipeline", http_url))
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

        // Skip documents from this device
        if remote_device == device_id {
            continue;
        }

        // (S3 content download logic would go here)
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
// Upload to Phoenix
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
// Helpers
// ══════════════════════════════════════════════════════════════════════════

fn get_text(row: &libsql::Row, idx: i32) -> String {
    match row.get_value(idx).ok() {
        Some(libsql::Value::Text(s)) => s,
        _ => String::new(),
    }
}

async fn get_last_sync_at(conn: &libsql::Connection) -> Result<String, String> {
    let mut rows = conn.query(
        "SELECT last_sync_at FROM local_identity WHERE id = 'singleton'",
        (),
    ).await.map_err(|e| e.to_string())?;

    if let Some(row) = rows.next().await.map_err(|e| e.to_string())? {
        match row.get_value(0).ok() {
            Some(libsql::Value::Text(s)) if !s.is_empty() => Ok(s),
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