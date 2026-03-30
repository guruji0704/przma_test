use crate::AppState;
use serde::{Deserialize, Serialize};
use tauri::State;

#[derive(Serialize, Deserialize)]
pub struct DIDResult {
    pub did: String,
    pub public_key_multibase: String,
}

#[tauri::command]
pub async fn validate_did(did: String) -> Result<bool, String> {
    Ok(did.starts_with("did:przma:") && did.len() > 12)
}

#[tauri::command]
pub async fn store_server_did(
    did: String,
    state: State<'_, AppState>,
) -> Result<(), String> {
    let conn = crate::db::connect(&state.db).await.map_err(|e| e.to_string())?;
    conn.execute(
        "UPDATE local_identity
         SET did = ?1, updated_at = datetime('now')
         WHERE id = 'singleton'",
        libsql::params![did],
    ).await.map_err(|e| e.to_string())?;

    Ok(())
}