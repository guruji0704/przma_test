use crate::{AppState, device, sync::engine, crdt::CRDTDocument};
use tauri::{AppHandle, Manager};
use uuid::Uuid;
use base64::Engine;
use std::fs;
use serde::{Deserialize, Serialize};

// ══════════════════════════════════════════════════════════════════════════
// Structs
// ══════════════════════════════════════════════════════════════════════════

#[derive(Serialize, Deserialize)]
pub struct DocumentInfo {
    pub id: String,
    pub filename: String,
    pub text_content: String,
    pub is_synced: i64,
    pub status: String,
    pub created_at: String,
    pub updated_at: String,
    pub content_type: String,
    pub version: i64,
    pub conflict_copy_of: Option<String>,
}

// ══════════════════════════════════════════════════════════════════════════
// list_documents
// ══════════════════════════════════════════════════════════════════════════

#[tauri::command]
pub async fn list_documents(state: tauri::State<'_, AppState>) -> Result<Vec<DocumentInfo>, String> {
    let conn = state.db.connect().map_err(|e| e.to_string())?;

    let mut rows = conn.query(
        "SELECT id, filename, text_content, is_synced, status, created_at, updated_at,
                COALESCE(NULLIF(content_type, ''), 'text/plain') as content_type,
                COALESCE(version, 1) as version,
                conflict_copy_of
         FROM documents ORDER BY created_at DESC",
        (),
    ).await.map_err(|e| e.to_string())?;

    let mut docs = Vec::new();
    while let Some(row) = rows.next().await.map_err(|e| e.to_string())? {
        docs.push(DocumentInfo {
            id:               get_text(&row, 0),
            filename:         get_text(&row, 1),
            text_content:     get_text(&row, 2),
            is_synced:        get_int(&row, 3),
            status:           get_text(&row, 4),
            created_at:       get_text(&row, 5),
            updated_at:       get_text(&row, 6),
            content_type:     get_text(&row, 7),
            version:          get_int(&row, 8),
            conflict_copy_of: get_opt_text(&row, 9),
        });
    }
    Ok(docs)
}

// ══════════════════════════════════════════════════════════════════════════
// upload_file
// ══════════════════════════════════════════════════════════════════════════

#[tauri::command]
pub async fn upload_file(
    filename: String,
    content_type: String,
    file_data_b64: String,
    state: tauri::State<'_, AppState>,
    app: AppHandle,
) -> Result<(), String> {
    let conn = state.db.connect().map_err(|e| e.to_string())?;
    let doc_id = Uuid::new_v4().to_string();
    let device_id = device::get_or_create_device_id(&conn).await?;

    let binary_data = base64::engine::general_purpose::STANDARD
        .decode(&file_data_b64)
        .map_err(|e| format!("Base64 decode failed: {}", e))?;

    let safe_content_type = if content_type.is_empty() {
        "application/octet-stream".to_string()
    } else {
        content_type.clone()
    };

    let crdt_doc = CRDTDocument::new(
        doc_id.clone(),
        filename.clone(),
        format!("Binary file: {}", safe_content_type),
        device_id.clone(),
    )?;

    let now = chrono::Utc::now().to_rfc3339();

    conn.execute(
        "INSERT INTO documents (
            id, filename, automerge_state, binary_content, content_type,
            text_content, device_id, last_modified_at, updated_at,
            status, needs_upload, is_synced, version
        ) VALUES (?, ?, ?, ?, ?, '', ?, ?, ?, 'pending', 1, 0, 1)",
        libsql::params![
            doc_id.clone(),
            filename.clone(),
            crdt_doc.automerge_state,
            binary_data,
            safe_content_type,
            device_id,
            now.clone(),
            now,
        ],
    ).await.map_err(|e| e.to_string())?;

    log::info!("✅ [Binary] Uploaded {} ({})", filename, doc_id);
    tokio::spawn(async move { let _ = engine::run_sync_cycle(&app).await; });
    Ok(())
}

// ══════════════════════════════════════════════════════════════════════════
// create_document
// ══════════════════════════════════════════════════════════════════════════

#[tauri::command]
pub async fn create_document(
    filename: String,
    text_content: String,
    tags: Vec<String>,
    state: tauri::State<'_, AppState>,
    app: AppHandle,
) -> Result<(), String> {
    let conn = state.db.connect().map_err(|e| e.to_string())?;
    let doc_id = Uuid::new_v4().to_string();
    let device_id = device::get_or_create_device_id(&conn).await?;

    let crdt_doc = CRDTDocument::new(
        doc_id.clone(),
        filename.clone(),
        text_content.clone(),
        device_id.clone(),
    )?;

    let tags_json = serde_json::to_string(&tags).unwrap_or_else(|_| "[]".to_string());
    let now = chrono::Utc::now().to_rfc3339();

    conn.execute(
        "INSERT INTO documents (
            id, filename, automerge_state, text_content, content_type,
            device_id, last_modified_at, updated_at,
            status, needs_upload, is_synced, version, tags
        ) VALUES (?, ?, ?, ?, 'text/plain', ?, ?, ?, 'pending', 1, 0, 1, ?)",
        libsql::params![
            doc_id.clone(),
            filename,
            crdt_doc.automerge_state,
            text_content,
            device_id,
            now.clone(),
            now,
            tags_json,
        ],
    ).await.map_err(|e| e.to_string())?;

    log::info!("✅ [Text] Document created (ID: {})", doc_id);
    tokio::spawn(async move {
        let _ = engine::run_sync_cycle(&app).await;
    });
    Ok(())
}

// ══════════════════════════════════════════════════════════════════════════
// update_document
// ══════════════════════════════════════════════════════════════════════════

#[tauri::command]
pub async fn update_document(
    id: String,
    text_content: String,
    state: tauri::State<'_, AppState>,
    app: AppHandle,
) -> Result<(), String> {
    let conn = state.db.connect().map_err(|e| e.to_string())?;
    let device_id = device::get_or_create_device_id(&conn).await?;

    log::info!("✏️  [CRDT] Updating document '{}'", id);

    let mut rows = conn.query(
        "SELECT automerge_state, filename FROM documents WHERE id = ?",
        libsql::params![id.clone()],
    ).await.map_err(|e| e.to_string())?;

    if let Some(row) = rows.next().await.map_err(|e| e.to_string())? {
        let automerge_state = match row.get_value(0).ok() {
            Some(libsql::Value::Blob(b)) => b,
            _ => vec![],
        };

        let filename = match row.get_value(1).ok() {
            Some(libsql::Value::Text(s)) => s,
            _ => return Err("Filename not found".to_string()),
        };

        let now = chrono::Utc::now().to_rfc3339();

        let new_automerge_state = if automerge_state.is_empty() {
            let crdt_doc = CRDTDocument::new(
                id.clone(),
                filename.clone(),
                text_content.clone(),
                device_id.clone(),
            )?;
            crdt_doc.automerge_state
        } else {
            let mut crdt_doc = CRDTDocument::from_db(
                id.clone(),
                filename,
                automerge_state,
                device_id.clone(),
                now.clone(),
                false,
                true,
            )?;
            crdt_doc.update_content(text_content.clone())?;
            crdt_doc.automerge_state
        };

        conn.execute(
            "UPDATE documents SET
                automerge_state  = ?,
                text_content     = ?,
                content_type     = 'text/plain',
                last_modified_at = ?,
                updated_at       = datetime('now'),
                version          = version + 1,
                needs_upload     = 1,
                is_synced        = 0,
                status           = 'pending'
             WHERE id = ?",
            libsql::params![
                new_automerge_state,
                text_content,
                now,
                id,
            ],
        ).await.map_err(|e| e.to_string())?;

        log::info!("✅ [CRDT] Document updated");

        tokio::spawn(async move {
            let _ = engine::run_sync_cycle(&app).await;
        });

        Ok(())
    } else {
        Err("Document not found".to_string())
    }
}

// ══════════════════════════════════════════════════════════════════════════
// delete_document
// ══════════════════════════════════════════════════════════════════════════

#[tauri::command]
pub async fn delete_document(
    id: String,
    state: tauri::State<'_, AppState>,
) -> Result<(), String> {
    let conn = state.db.connect().map_err(|e| e.to_string())?;
    conn.execute("DELETE FROM documents WHERE id = ?", libsql::params![id])
        .await
        .map_err(|e| e.to_string())?;
    log::info!("🗑️  Document deleted");
    Ok(())
}

// ══════════════════════════════════════════════════════════════════════════
// open_file_for_edit
// ══════════════════════════════════════════════════════════════════════════

#[tauri::command]
pub async fn open_file_for_edit(
    id: String,
    filename: String,
    state: tauri::State<'_, AppState>,
    app: AppHandle,
) -> Result<String, String> {
    let conn = state.db.connect().map_err(|e| e.to_string())?;

    let mut rows = conn.query(
        "SELECT binary_content FROM documents WHERE id = ?",
        libsql::params![id.clone()],
    ).await.map_err(|e| e.to_string())?;

    let bytes = if let Some(row) = rows.next().await.map_err(|e| e.to_string())? {
        match row.get_value(0).ok() {
            Some(libsql::Value::Blob(b)) => b,
            _ => return Err("No binary content found for this file.".to_string()),
        }
    } else {
        return Err("File not found. Please sync first.".to_string());
    };

    let app_dir = app.path().app_data_dir().map_err(|e| e.to_string())?;
    let cache_dir = app_dir.join("cache");
    fs::create_dir_all(&cache_dir).map_err(|e| e.to_string())?;

    let local_path = cache_dir.join(format!("{}_{}", id, filename));
    fs::write(&local_path, bytes).map_err(|e| e.to_string())?;

    opener::open(&local_path).map_err(|e| e.to_string())?;

    log::info!("📂 Opened for editing: {:?}", local_path);
    Ok(local_path.to_string_lossy().to_string())
}

// ══════════════════════════════════════════════════════════════════════════
// save_edited_file
//
// Returns:
//   Ok("NO_CHANGES") — bytes identical, user hasn't saved in external app
//   Ok("SAVED")      — saved successfully, version bumped, sync triggered
//   Err("CONFLICT…") — optimistic lock failed, conflict copy created
// ══════════════════════════════════════════════════════════════════════════

#[tauri::command]
pub async fn save_edited_file(
    id: String,
    local_path: String,
    current_version: i64,
    state: tauri::State<'_, AppState>,
    app: AppHandle,
) -> Result<String, String> { // <--- CHANGED RETURN TYPE to String
    let conn = state.db.connect().map_err(|e| e.to_string())?;

    // 1. Read the file from disk
    let new_bytes = fs::read(&local_path).map_err(|e| format!("Failed to read file: {}", e))?;

    // 2. Get current state from DB
    let mut rows = conn.query(
        "SELECT binary_content, version FROM documents WHERE id = ?", 
        libsql::params![id.clone()]
    ).await.map_err(|e| e.to_string())?;

    let (current_bytes, server_version) = if let Some(row) = rows.next().await.map_err(|e| e.to_string())? {
        let bytes = match row.get_value(0).ok() {
            Some(libsql::Value::Blob(b)) => b,
            _ => return Err("No binary content found in DB".to_string())
        };
        let ver = get_int(&row, 1);
        (bytes, ver)
    } else {
        return Err("Document deleted".to_string());
    };

    // 3. ✅ NEW: Compare Content
    if current_bytes == new_bytes {
        return Ok("NO_CHANGES".to_string()); 
    }

    // 4. Check for Version Conflict (Optimistic Locking)
    if server_version != current_version {
        // Pass the NEW bytes to the conflict handler so they aren't lost
        return handle_conflict(&conn, &id, &local_path, current_version).await;
    }

    // 5. Proceed with Update
    let new_version = current_version + 1;

    let rows_affected = conn.execute(
        "UPDATE documents SET 
            binary_content = ?,
            last_modified_at = ?,
            needs_upload = 1,
            is_synced = 0,
            status = 'pending',
            version = ?
         WHERE id = ? AND version = ?", 
        libsql::params![
            new_bytes, 
            chrono::Utc::now().to_rfc3339(), 
            new_version, 
            id.clone(), 
            current_version
        ]
    ).await.map_err(|e| e.to_string())?;

    if rows_affected == 0 {
        // Race condition occurred
        return handle_conflict(&conn, &id, &local_path, current_version).await;
    }

    log::info!("✅ [Edit] Saved version {}", new_version);
    tokio::spawn(async move { let _ = engine::run_sync_cycle(&app).await; });
    
    Ok("SUCCESS".to_string())
}

// ══════════════════════════════════════════════════════════════════════════
// handle_conflict
// ══════════════════════════════════════════════════════════════════════════

async fn handle_conflict(
    conn: &libsql::Connection, 
    original_id: &str, 
    local_path: &str, 
    _base_version: i64
) -> Result<String, String> { // <--- CHANGED RETURN TYPE
    log::warn!("⚠️ Conflict detected for {}. Creating copy.", original_id);
    
    let bytes = fs::read(local_path).map_err(|e| e.to_string())?;
    let conflict_id = Uuid::new_v4().to_string();
    let now = chrono::Utc::now().to_rfc3339();

    let mut rows = conn.query(
        "SELECT filename, content_type, text_content FROM documents WHERE id = ?", 
        libsql::params![original_id]
    ).await.map_err(|e| e.to_string())?;
    
    let (filename, ctype, text_content) = if let Some(row) = rows.next().await.map_err(|e| e.to_string())? {
        (get_text(&row, 0), get_text(&row, 1), get_text(&row, 2))
    } else {
        ("conflict_file".to_string(), "application/octet-stream".to_string(), String::new())
    };

    conn.execute(
        "INSERT INTO documents (
            id, filename, binary_content, content_type, text_content,
            device_id, last_modified_at, status, needs_upload, is_synced, 
            version, conflict_copy_of
        ) VALUES (?, ?, ?, ?, ?, 'conflict_resolver', ?, 'pending', 1, 0, 1, ?)",
        libsql::params![
            conflict_id.clone(), 
            format!("{} (Conflict Copy)", filename),
            bytes, 
            ctype, 
            text_content,
            now, 
            original_id
        ],
    ).await.map_err(|e| e.to_string())?;

    Err(format!("CONFLICT: Created copy {}", conflict_id))
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

fn get_opt_text(row: &libsql::Row, idx: i32) -> Option<String> {
    match row.get_value(idx).ok() {
        Some(libsql::Value::Text(s)) if !s.is_empty() => Some(s),
        _ => None,
    }
}

fn get_int(row: &libsql::Row, idx: i32) -> i64 {
    match row.get_value(idx).ok() {
        Some(libsql::Value::Integer(i)) => i,
        _ => 0,
    }
}