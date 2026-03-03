use tauri::State;
use crate::AppState;

#[tauri::command]
pub async fn sync_now(state: State<'_, AppState>) -> Result<String, String> {
    log::info!("🔄 [Manual Sync] User triggered sync");
    
    let conn = state.db.connect().map_err(|e| e.to_string())?;
    
    // Check how many documents need upload
    let mut rows = conn
        .query("SELECT COUNT(*) FROM documents WHERE needs_upload = 1", ())
        .await
        .map_err(|e| e.to_string())?;
    
    let pending_count = if let Some(row) = rows.next().await.map_err(|e| e.to_string())? {
        match row.get_value(0).ok() {
            Some(libsql::Value::Integer(i)) => i,
            _ => 0,
        }
    } else {
        0
    };
    
    log::info!("[Manual Sync] {} documents pending upload", pending_count);
    
    // Check auth status
    let mut auth_rows = conn
        .query("SELECT access_token, server_url FROM local_identity WHERE id = 'singleton'", ())
        .await
        .map_err(|e| e.to_string())?;
    
    if let Some(row) = auth_rows.next().await.map_err(|e| e.to_string())? {
        let has_token = matches!(row.get_value(0).ok(), Some(libsql::Value::Text(s)) if !s.is_empty());
        let has_url = matches!(row.get_value(1).ok(), Some(libsql::Value::Text(s)) if !s.is_empty());
        
        log::info!("[Manual Sync] Auth status: token={}, url={}", has_token, has_url);
        
        if !has_token {
            return Err("Not logged in - no access token".to_string());
        }
        if !has_url {
            return Err("Server URL not configured".to_string());
        }
    } else {
        return Err("No identity found - please login".to_string());
    }
    
    Ok(format!("Sync triggered - {} documents pending", pending_count))
}

#[tauri::command]
pub async fn get_sync_status(state: State<'_, AppState>) -> Result<SyncStatus, String> {
    let conn = state.db.connect().map_err(|e| e.to_string())?;
    
    let mut rows = conn
        .query("SELECT COUNT(*) FROM documents WHERE needs_upload = 1", ())
        .await
        .map_err(|e| e.to_string())?;
    
    let pending = if let Some(row) = rows.next().await.map_err(|e| e.to_string())? {
        match row.get_value(0).ok() {
            Some(libsql::Value::Integer(i)) => i,
            _ => 0,
        }
    } else {
        0
    };
    
    Ok(SyncStatus {
        pending_uploads: pending,
        is_syncing: false,
    })
}

#[derive(serde::Serialize)]
pub struct SyncStatus {
    pub pending_uploads: i64,
    pub is_syncing: bool,
}