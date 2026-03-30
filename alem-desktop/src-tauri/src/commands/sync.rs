use tauri::{AppHandle, State};
use crate::AppState;

#[tauri::command]
pub async fn sync_now(
    state: State<'_, AppState>,
    app: AppHandle,
) -> Result<String, String> {
    log::info!("🔄 [Manual Sync] User triggered sync");

    let conn = crate::db::connect(&state.db).await.map_err(|e| e.to_string())?;

    // Guard: must be logged in with a server URL before syncing
    let mut auth_rows = conn
        .query(
            "SELECT access_token, server_url FROM local_identity WHERE id = 'singleton'",
            (),
        )
        .await
        .map_err(|e| e.to_string())?;

    if let Some(row) = auth_rows.next().await.map_err(|e| e.to_string())? {
        let has_token = matches!(row.get_value(0).ok(), Some(libsql::Value::Text(s)) if !s.is_empty());
        let has_url   = matches!(row.get_value(1).ok(), Some(libsql::Value::Text(s)) if !s.is_empty());

        if !has_token {
            return Err("Not logged in — no access token".to_string());
        }
        if !has_url {
            return Err("Server URL not configured".to_string());
        }
    } else {
        return Err("No identity found — please login".to_string());
    }

    // Actually run the sync cycle (push + pull)
    match crate::sync::engine::run_sync_cycle(&app).await {
        Ok((pushed, pulled)) => {
            log::info!("[Manual Sync] ✅ pushed={}, pulled={}", pushed, pulled);
            Ok(format!("Synced: {} uploaded, {} pulled", pushed, pulled))
        }
        Err(e) => {
            log::error!("[Manual Sync] ❌ {}", e);
            Err(format!("Sync failed: {}", e))
        }
    }
}

#[tauri::command]
pub async fn get_sync_status(state: State<'_, AppState>) -> Result<SyncStatus, String> {
    let conn = crate::db::connect(&state.db).await.map_err(|e| e.to_string())?;

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
