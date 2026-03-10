mod db;
mod commands;
mod sync;
mod crdt; 
mod device;

use std::sync::Arc;
use tauri::Manager;
use tauri::Emitter;
use tauri_plugin_deep_link::DeepLinkExt;

pub struct AppState {
    pub db: Arc<libsql::Database>,
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    env_logger::init();
    
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_shell::init())
        .setup(|app| {
            log::info!("🚀 Starting ALEM with CRDT support...");
            
            let data_dir = app.path().app_data_dir()
                .expect("Failed to resolve app data dir");
            
            std::fs::create_dir_all(&data_dir)?;
            let db_path = data_dir.join("alem.db");
            
            log::info!("📂 Database: {:?}", db_path);

            let database = tauri::async_runtime::block_on(async {
                db::open(db_path.to_str().expect("Invalid path"))
                    .await
                    .expect("Failed to open database")
            });

            let db = Arc::new(database);
            app.manage(AppState { db: Arc::clone(&db) });

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
            commands::did::validate_did,
            commands::did::store_server_did,
            commands::documents::create_document,
            commands::documents::update_document,
            commands::documents::list_documents,
            commands::documents::open_file_for_edit,
            commands::documents::save_edited_file,     
            commands::documents::delete_document,
            commands::documents::upload_file,
            commands::sync::sync_now,
            commands::sync::get_sync_status,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}