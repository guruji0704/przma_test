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
    pub db:        Arc<libsql::Database>,
    pub vault_key: Arc<vault::VaultKey>,
    /// Server epoch x25519 public key — used by encrypt_file_v2 to wrap the
    /// per-file key so the server can decrypt vault files for CAS extraction.
    /// None if the server was unreachable at startup (falls back to v1 encrypt).
    /// Updated after login and on each sync cycle.
    pub epoch_key: Arc<tokio::sync::RwLock<Option<vault::EpochPublicKey>>>,
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    env_logger::init();
    
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_fs::init())
        .setup(|app| {
            log::info!("🚀 Starting ALEM with CRDT support...");
            
            let data_dir = app.path().app_data_dir()
                .expect("Failed to resolve app data dir");
            
            std::fs::create_dir_all(&data_dir)?;
            let db_path = data_dir.join("przma.db");
            
            log::info!("📂 Database: {:?}", db_path);

            let database = tauri::async_runtime::block_on(async {
                db::open(db_path.to_str().expect("Invalid path"))
                    .await
                    .expect("Failed to open database")
            });

            // Load (or generate) the vault encryption key from local_identity.
            // This key never leaves the device; the sync engine sends only
            // encrypted bytes to the server, providing true E2EE.
            let vault_key = tauri::async_runtime::block_on(async {
                vault::load_or_generate_key(&database)
                    .await
                    .expect("Failed to load vault key")
            });

            let db        = Arc::new(database);
            let vault_key = Arc::new(vault_key);

            // Try to fetch the server's current epoch public key.
            // This is a public endpoint — no auth token required.
            // Fails silently if server is unreachable; vault falls back to v1.
            let epoch_key = tauri::async_runtime::block_on(async {
                let conn = crate::db::connect(&db).await.expect("db connect");
                let server_url: Option<String> = async {
                    let mut rows = conn
                        .query("SELECT server_url FROM local_identity WHERE id='singleton'", ())
                        .await
                        .ok()?;
                    let row = rows.next().await.ok()??;
                    if let libsql::Value::Text(s) = row.get_value(0).ok()? {
                        Some(s)
                    } else {
                        None
                    }
                }.await;

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
                db:        Arc::clone(&db),
                vault_key: Arc::clone(&vault_key),
                epoch_key: Arc::new(tokio::sync::RwLock::new(epoch_key)),
            });

            log::info!("🔄 Starting CRDT sync engine...");
            
            let app_handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                sync::engine::start(app_handle).await;
            });
            
            log::info!("✅ ALEM initialized with CRDT!");
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