use crate::{AppState, device, sync::engine};
use tauri::AppHandle;
use uuid::Uuid;

#[tauri::command]
pub async fn create_document(
    filename: String,
    text_content: String,
    tags: Vec<String>,
    state: tauri::State<'_, AppState>,
    app: AppHandle, // ✅ Add AppHandle
) -> Result<(), String> {
    let conn = state.db.connect().map_err(|e| e.to_string())?;
    
    let doc_id = Uuid::new_v4().to_string();
    let device_id = device::get_or_create_device_id(&conn).await?;
    
    log::info!("📝 [CRDT] Creating document '{}'", filename);
    
    let crdt_doc = crate::crdt::CRDTDocument::new(
        doc_id.clone(),
        filename.clone(),
        text_content.clone(),
        device_id.clone(),
    )?;
    
    let tags_json = serde_json::to_string(&tags).unwrap_or_else(|_| "[]".to_string());
    
    conn.execute(
        "INSERT INTO documents (
            id, filename, automerge_state, text_content, tags,
            device_id, last_modified_at, status, needs_upload, is_synced
        ) VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', 1, 0)",
        libsql::params![
            doc_id.clone(),
                        filename,
            crdt_doc.automerge_state,
            text_content,
            tags_json,
            device_id,
            crdt_doc.last_modified_at,
        ],
    )
    .await
    .map_err(|e| e.to_string())?;
    
    log::info!("✅ [CRDT] Document created (ID: {})", doc_id);

    // ✅ TRIGGER: Immediate background sync
    tokio::spawn(async move {
        log::info!("🚀 [AutoSync] Triggering immediate sync for new document...");
        let _ = engine::run_sync_cycle(&app).await;
    });

    Ok(())
}

#[tauri::command]
pub async fn update_document(
    id: String,
    text_content: String,
    state: tauri::State<'_, AppState>,
    app: AppHandle, // ✅ Add AppHandle
) -> Result<(), String> {
    let conn = state.db.connect().map_err(|e| e.to_string())?;
    let device_id = device::get_or_create_device_id(&conn).await?;
    
    log::info!("✏️ [CRDT] Updating document '{}'", id);
    
    let mut rows = conn
        .query(
            "SELECT automerge_state, filename FROM documents WHERE id = ?",
            libsql::params![id.clone()],
        )
        .await
        .map_err(|e| e.to_string())?;
    
    if let Some(row) = rows.next().await.map_err(|e| e.to_string())? {
        let automerge_state = match row.get_value(0).ok() {
            Some(libsql::Value::Blob(b)) => b,
            _ => return Err("Invalid CRDT state".to_string()),
        };
        
        let filename = match row.get_value(1).ok() {
            Some(libsql::Value::Text(s)) => s,
            _ => return Err("Filename not found".to_string()),
        };
        
        let mut crdt_doc = crate::crdt::CRDTDocument::from_db(
            id.clone(),
            filename,
            automerge_state,
            device_id.clone(),
            chrono::Utc::now().to_rfc3339(),
            false,
            true,
        )?;
        
        crdt_doc.update_content(text_content.clone())?;
        
        conn.execute(
            "UPDATE documents SET 
                automerge_state = ?,
                text_content = ?,
                last_modified_at = ?,
                needs_upload = 1,
                is_synced = 0,
                status = 'pending'
             WHERE id = ?",
            libsql::params![
                crdt_doc.automerge_state,
                text_content,
                crdt_doc.last_modified_at,
                id,
            ],
        )
        .await
        .map_err(|e| e.to_string())?;
        
        log::info!("✅ [CRDT] Document updated");

        // ✅ TRIGGER: Immediate background sync
        tokio::spawn(async move {
            log::info!("🚀 [AutoSync] Triggering immediate sync for updated document...");
            let _ = engine::run_sync_cycle(&app).await;
        });

        Ok(())
    } else {
        Err("Document not found".to_string())
    }
}

#[tauri::command]
pub async fn list_documents(state: tauri::State<'_, AppState>) -> Result<Vec<DocumentInfo>, String> {
    let conn = state.db.connect().map_err(|e| e.to_string())?;
    
    let mut rows = conn
        .query(
            "SELECT id, filename, text_content, is_synced, status, created_at 
             FROM documents ORDER BY created_at DESC",
            (),
        )
        .await
        .map_err(|e| e.to_string())?;
    
    let mut docs = Vec::new();
    while let Some(row) = rows.next().await.map_err(|e| e.to_string())? {
        docs.push(DocumentInfo {
            id: get_text_value(&row, 0),
            filename: get_text_value(&row, 1),
            text_content: get_text_value(&row, 2),
            is_synced: get_int_value(&row, 3),
            status: get_text_value(&row, 4),
            created_at: get_text_value(&row, 5),
            updated_at: get_text_value(&row, 6)
        });
    }
    
    Ok(docs)
}

#[tauri::command]
pub async fn delete_document(id: String, state: tauri::State<'_, AppState>) -> Result<(), String> {
    let conn = state.db.connect().map_err(|e| e.to_string())?;
    
    conn.execute("DELETE FROM documents WHERE id = ?", libsql::params![id])
        .await
        .map_err(|e| e.to_string())?;
    
    log::info!("🗑️ [CRDT] Document deleted");
    Ok(())
}

#[derive(serde::Serialize)]
pub struct DocumentInfo {
    pub id: String,
    pub filename: String,
    pub text_content: String,
    pub is_synced: i64,
    pub status: String,
    pub created_at: String,
    pub updated_at: String
}

fn get_text_value(row: &libsql::Row, index: i32) -> String {
    match row.get_value(index).ok() {
        Some(libsql::Value::Text(s)) => s,
        _ => String::new(),
    }
}

fn get_int_value(row: &libsql::Row, index: i32) -> i64 {
    match row.get_value(index).ok() {
        Some(libsql::Value::Integer(i)) => i,
        _ => 0,
    }
}