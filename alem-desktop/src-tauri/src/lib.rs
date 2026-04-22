mod db;
mod commands;
mod sync;
mod crdt;
mod device;
mod vault;
mod arrow;

use std::sync::Arc;
use tauri::Manager;

pub struct AppState {
    pub vault_key: Arc<vault::VaultKey>,
    /// Server epoch x25519 public key — used by encrypt_file_v2 to wrap the
    /// per-file key so the server can decrypt vault files for CAS extraction.
    /// None if the server was unreachable at startup (falls back to v1 encrypt).
    /// Updated after login and on each sync cycle.
    pub epoch_key: Arc<tokio::sync::RwLock<Option<vault::EpochPublicKey>>>,
    pub lancedb:   Arc<db::lancedb::LanceDBManager>,
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    env_logger::init();
    
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_fs::init())
        .setup(|app| {
            log::info!("🚀 Starting ALEM with LanceDB Consolidation...");
            
            let data_dir = app.path().app_data_dir()
                .expect("Failed to resolve app data dir");
            
            std::fs::create_dir_all(&data_dir)?;
            
            let lancedb_mgr = Arc::new(db::lancedb::LanceDBManager::new(&data_dir));
            
            tauri::async_runtime::block_on(async {
                lancedb_mgr.initialize_all().await.expect("Failed to init LanceDB");
            });

            // Load (or generate) the vault encryption key.
            // Since we removed SQLite, we need to adapt vault::load_or_generate_key to use LanceDB.
            // For now, I'll keep the signature and pass the manager, but I'll need to update the implementation.
            let vault_key = tauri::async_runtime::block_on(async {
                vault::load_or_generate_key_lancedb(&lancedb_mgr)
                    .await
                    .expect("Failed to load vault key")
            });

            let vault_key = Arc::new(vault_key);

            // Try to fetch the server's current epoch public key.
            let epoch_key = tauri::async_runtime::block_on(async {
                // TODO: Get server_url from LanceDB identity table
                let server_url: Option<String> = None; // Placeholder

                if let Some(url) = server_url {
                    match vault::epoch::fetch_epoch_key(&url).await {
                        Ok(ek) => {
                            log::info!("🔑 [Startup] Epoch key loaded (epoch_id={})", ek.epoch_id);
                            Some(ek)
                        }
                        Err(e) => {
                            log::warn!("🔑 [Startup] Epoch key unavailable (v1 fallback): {}", e);
                            None
                        }
                    }
                } else {
                    log::info!("🔑 [Startup] No server URL configured yet — epoch key deferred");
                    None
                }
            });

            app.manage(AppState {
                vault_key: Arc::clone(&vault_key),
                epoch_key: Arc::new(tokio::sync::RwLock::new(epoch_key)),
                lancedb:   Arc::clone(&lancedb_mgr),
            });

            log::info!("🔄 Starting LanceDB sync engine...");
            
            let app_handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                sync::engine::start(app_handle).await;
            });
            
            log::info!("✅ ALEM initialized with Unified LanceDB!");
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::auth::get_captcha,
            commands::auth::register_account,
            commands::auth::get_stored_did,
            commands::auth::login,
            commands::auth::logout,
            commands::auth::verify_email,
            commands::auth::resend_otp,     
            commands::auth::forgot_password,
            commands::auth::reset_password,
            commands::auth::get_local_token,
            commands::auth::update_server_url,
            commands::did::validate_did,
            commands::did::store_server_did,
            commands::documents::create_document,
            commands::documents::update_document,
            commands::documents::list_documents,
            commands::documents::open_file_for_edit,
            commands::documents::save_edited_file,     
            commands::documents::delete_document,
            commands::documents::rename_document,
            commands::documents::upload_file,
            commands::documents::upload_file_chunk,
            commands::documents::upload_files_from_paths,
            commands::documents::get_file_bytes,
            commands::sync::sync_now,
            commands::sync::get_sync_status,
            commands::analytics::get_documents_arrow,
            commands::analytics::benchmark_serialization,
            commands::media::prepare_image_frames,
            // Phase 1 — Pull sync
            commands::documents::get_sync_stats,
            commands::documents::pull_sync,
            commands::documents::download_file,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}