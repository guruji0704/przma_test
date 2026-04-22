use tauri::{AppHandle, State};
use crate::AppState;

#[tauri::command]
pub async fn sync_now(
    state: State<'_, AppState>,
    app: AppHandle,
) -> Result<String, String> {
    log::info!("🔄 [Manual Sync] User triggered sync");

    // Guard: must be logged in with a server URL before syncing
    let url = state.lancedb.get_server_url().await?.ok_or_else(|| "Server URL not configured".to_string())?;
    let in_keyring = crate::vault::load_token_from_keyring()?.is_some();

    if !in_keyring {
        return Err("Not logged in — no access token".to_string());
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
    let table = state.lancedb.open_table("documents").await.map_err(|e| e.to_string())?;
    
    // Count documents where status = 'pending_upload' or similar. 
    // Wait, earlier LanceDB schema documents table had 'status'.
    // If 'needs_upload' was the old SQLite way, we just look up 'status'.
    let mut stream = table.query().filter("status = 'pending'").execute().await.map_err(|e| e.to_string())?;
    
    let mut pending: i64 = 0;
    while let Some(batch) = stream.next().await {
        if let Ok(b) = batch {
            pending += b.num_rows() as i64;
        }
    }

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
