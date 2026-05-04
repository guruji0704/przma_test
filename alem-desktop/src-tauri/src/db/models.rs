// src-tauri/src/db/models.rs
// Unchanged structurally — but now populated from libsql::Row instead of rusqlite::Row
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Document {
    pub id: String,
    pub user_id: String,
    pub tenant_id: String,
    pub filename: String,
    pub content_type: Option<String>,
    pub file_size: Option<i64>,
    pub content_hash: Option<String>,
    pub local_path: Option<String>,
    pub object_key: Option<String>,
    pub text_content: Option<String>,
    pub metadata: serde_json::Value,
    pub tags: Vec<String>,
    pub status: String,
    pub local_version: i32,
    pub server_version: i32,
    pub is_synced: bool,
    pub needs_upload: bool,
    pub needs_download: bool,
    pub sync_error: Option<String>,
    pub last_synced_at: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    pub vault_category: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LocalIdentity {
    pub user_id: Option<String>,
    pub tenant_id: String,
    pub username: Option<String>,
    pub email: Option<String>,
    pub did: Option<String>,
    pub did_public_key: Option<String>,
    pub pleroma_account_id: Option<String>,
    pub server_url: String,
    pub last_sync_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OfflineOperation {
    pub id: String,
    pub user_id: String,
    pub op_type: String,
    pub payload: serde_json::Value,
    pub status: String,
    pub retry_count: i32,
    pub error_msg: Option<String>,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DIDResult {
    pub did: String,
    pub public_key_multibase: String,
    // private key is NEVER returned — stored only in OS keychain
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncStatus {
    pub is_syncing: bool,
    pub last_sync_at: Option<String>,
    pub pending_count: i64,
    pub failed_count: i64,
    pub connection_online: bool,
}


// row_to_document removed -- legacy libsql helper.