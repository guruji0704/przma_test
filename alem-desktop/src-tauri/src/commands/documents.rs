use crate::{AppState, device, sync::engine, crdt::CRDTDocument, vault};
use tauri::{AppHandle, Manager, Emitter};
use uuid::Uuid;
use base64::Engine;
use std::fs;
use std::sync::{Arc, atomic::{AtomicUsize, Ordering}};
use serde::{Deserialize, Serialize};
use rayon::prelude::*;

// ══════════════════════════════════════════════════════════════════════════
// Structs
// ══════════════════════════════════════════════════════════════════════════

#[derive(Serialize, Deserialize)]
pub struct UploadResult {
    pub filename: String,
    pub status:   String,
    pub error:    Option<String>,
}

/// Emitted as `vault-encrypt-progress` event for files larger than 50 MB.
/// Frontend can listen to render a per-file progress bar during encryption.
#[derive(Serialize, Clone)]
pub struct EncryptProgress {
    pub filename:    String,
    pub bytes_done:  u64,
    pub bytes_total: u64,
    pub percent:     u8,
}

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
    let conn = crate::db::connect(&state.db).await.map_err(|e| e.to_string())?;

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
// upload_file  (single file via base64 IPC)
// ══════════════════════════════════════════════════════════════════════════

#[tauri::command]
pub async fn upload_file(
    filename: String,
    content_type: String,
    file_data_b64: String,
    state: tauri::State<'_, AppState>,
    app: AppHandle,
) -> Result<(), String> {
    let conn = crate::db::connect(&state.db).await.map_err(|e| e.to_string())?;
    let doc_id = Uuid::new_v4().to_string();
    let device_id = device::get_or_create_device_id(&conn).await?;

    let raw_bytes = base64::engine::general_purpose::STANDARD
        .decode(&file_data_b64)
        .map_err(|e| format!("Base64 decode failed: {}", e))?;

    // Encrypt before storing — vault stores only ciphertext
    let binary_data = state.vault_key.encrypt(&raw_bytes);

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
// upload_files_from_paths
//
// Two-phase parallel upload using Rayon:
//
//   PHASE 1 (Rayon — all CPU cores in parallel):
//     std::fs::read(path) → encrypt with ChaCha20-Poly1305
//     AtomicUsize tracks progress across threads (no Mutex needed)
//     spawn_blocking isolates Rayon from Tokio's async runtime
//
//   PHASE 2 (sequential — SQLite single-writer rule):
//     INSERT each encrypted blob into documents table one at a time
//
// Result: for N files, all reads+encrypts happen simultaneously,
// then writes are serialised — no database-locked errors.
// ══════════════════════════════════════════════════════════════════════════

/// Infer MIME type from file extension.
fn mime_from_path(path: &std::path::Path) -> &'static str {
    match path.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase().as_str() {
        "pdf"              => "application/pdf",
        "jpg" | "jpeg"     => "image/jpeg",
        "png"              => "image/png",
        "gif"              => "image/gif",
        "webp"             => "image/webp",
        "svg"              => "image/svg+xml",
        "mp4"              => "video/mp4",
        "webm"             => "video/webm",
        "mov"              => "video/quicktime",
        "mp3"              => "audio/mpeg",
        "wav"              => "audio/wav",
        "ogg"              => "audio/ogg",
        "zip"              => "application/zip",
        "tar"              => "application/x-tar",
        "gz"               => "application/gzip",
        "txt"              => "text/plain",
        "md"               => "text/markdown",
        "json"             => "application/json",
        "docx"             => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xlsx"             => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        _                  => "application/octet-stream",
    }
}

#[tauri::command]
pub async fn upload_files_from_paths(
    paths: Vec<String>,
    state: tauri::State<'_, AppState>,
    app: AppHandle,
) -> Result<Vec<UploadResult>, String> {

    // Create the vault directory once before spawning Rayon
    let app_data_dir = app.path().app_data_dir().map_err(|e| e.to_string())?;
    let vault_dir = app_data_dir.join("vault");
    std::fs::create_dir_all(&vault_dir).map_err(|e| e.to_string())?;

    // ── Phase 1: Parallel streaming encrypt across all CPU cores ─────────
    //
    // Each Rayon thread:
    //   1. Reads input file in 64 KB chunks (never more than 64 KB in RAM)
    //   2. Encrypts each chunk with ChaCha20-Poly1305 + fresh nonce
    //   3. Writes [enc_len][nonce][ciphertext] to a .vault file on disk
    //   4. Writes a metadata.json alongside
    //
    // Memory: constant ~64 KB per thread regardless of file size.
    // ─────────────────────────────────────────────────────────────────────
    let vault_key   = Arc::clone(&state.vault_key);
    let app_emit    = app.clone();
    let total       = paths.len();
    let paths_copy  = paths.clone();
    let vault_dir_c = vault_dir.clone();

    // Snapshot epoch key once before entering the Rayon blocking context.
    // EpochPublicKey is Copy so this is a cheap stack copy, not a heap allocation.
    let epoch_key_snapshot: Option<vault::EpochPublicKey> = *state.epoch_key.read().await;
    let epoch_id = epoch_key_snapshot.map(|ek| ek.epoch_id as i64);

    struct ReadyFile {
        doc_id:        String,
        path_str:      String,
        filename:      String,
        content_type:  String,
        vault_path:    std::path::PathBuf,
        original_size: u64,
    }

    let phase1: Vec<Result<ReadyFile, UploadResult>> =
        tokio::task::spawn_blocking(move || {
            let completed = AtomicUsize::new(0);

            paths_copy
                .into_par_iter()
                .map(|path_str| {
                    let path     = std::path::Path::new(&path_str);
                    let filename = path
                        .file_name()
                        .and_then(|n| n.to_str())
                        .unwrap_or("unknown_file")
                        .to_string();
                    let content_type = mime_from_path(path).to_string();

                    // Generate doc_id in Phase 1 so vault filename matches
                    let doc_id     = Uuid::new_v4().to_string();
                    let vault_path = vault_dir_c.join(format!("{}.vault", doc_id));

                    // ── Streaming encrypt → .vault file ──────────────────
                    //
                    // For files >50 MB we emit `vault-encrypt-progress` events so
                    // the frontend can show a per-file progress bar.  Smaller files
                    // are fast enough that a single "done" event is sufficient.
                    let file_size_hint = path.metadata().map(|m| m.len()).unwrap_or(0);
                    let large_file = file_size_hint > 50 * 1024 * 1024;

                    let cb_app      = app_emit.clone();
                    let cb_filename = filename.clone();
                    let cb_path     = path_str.clone();

                    let progress_cb = move |done: u64, total: u64| {
                        if large_file {
                            let _ = cb_app.emit("vault-encrypt-progress", EncryptProgress {
                                filename:    cb_filename.clone(),
                                bytes_done:  done,
                                bytes_total: total,
                                percent:     (done.saturating_mul(100) / total.max(1)) as u8,
                            });
                        }
                        // Emit a lightweight path-keyed event so the UI can update
                        // the status row for this specific file
                        let _ = cb_app.emit("fs-upload-progress", serde_json::json!({
                            "path":     cb_path,
                            "filename": cb_filename,
                            "status":   "encrypting",
                            "bytes_done":  done,
                            "bytes_total": total,
                        }));
                    };

                    // Use v2 dual-key encryption when server epoch key is available.
                    // v2 embeds a server-readable wrapped key so the server can
                    // Streaming encrypt → .vault file
                    let encrypt_result = match epoch_key_snapshot {
                        Some(ref ek) => {
                            log::info!("[Vault] 🔐 Using V2 encryption for '{}' (epoch_id={})", filename, ek.epoch_id);
                            vault::encrypt_file_v2(path, &vault_path, &vault_key, ek, progress_cb)
                                .map(|r| r.original_size)
                        },
                        None => {
                            log::warn!("[Vault] ⚠️ Falling back to V1 encryption for '{}' (No Epoch Key)", filename);
                            vault::encrypt_file(path, &vault_path, &vault_key, progress_cb)
                        },
                    };
                    let original_size = match encrypt_result {
                        Ok(n)  => n,
                        Err(e) => {
                            let _ = std::fs::remove_file(&vault_path); // cleanup partial
                            let err = format!("Encrypt failed: {}", e);
                            log::error!("[Vault] '{}': {}", filename, err);
                            let _ = app_emit.emit("fs-upload-progress", serde_json::json!({
                                "path": path_str, "filename": filename,
                                "status": "error", "error": err.clone(),
                            }));
                            return Err(UploadResult {
                                filename, status: "error".into(), error: Some(err),
                            });
                        }
                    };

                    // ── Write metadata.json alongside the vault file ──────
                    let meta_path = vault_dir_c.join(format!("{}.json", doc_id));
                    let metadata  = serde_json::json!({
                        "doc_id":       doc_id,
                        "filename":     filename,
                        "content_type": content_type,
                        "size":         original_size,
                        "created_at":   chrono::Utc::now().to_rfc3339(),
                    });
                    let _ = std::fs::write(&meta_path, metadata.to_string());

                    // Track overall batch progress (how many files done out of total)
                    let done = completed.fetch_add(1, Ordering::Relaxed) + 1;
                    let _ = app_emit.emit("fs-batch-progress", serde_json::json!({
                        "files_done":  done,
                        "files_total": total,
                        "percent":     (done * 100 / total.max(1)),
                    }));

                    log::info!("[Vault] ✅ '{}' → {}.vault ({} bytes)", filename, doc_id, original_size);
                    Ok(ReadyFile { doc_id, path_str, filename, content_type, vault_path, original_size })
                })
                .collect()
        })
        .await
        .map_err(|e| format!("Parallel encrypt failed: {}", e))?;

    // ── Phase 2: Sequential SQLite writes (single-writer rule) ───────────
    let mut results: Vec<UploadResult> = Vec::new();

    for item in phase1 {
        let ready = match item {
            Err(r) => { results.push(r); continue; }
            Ok(r)  => r,
        };

        let conn = match crate::db::connect(&state.db).await {
            Ok(c)  => c,
            Err(e) => {
                results.push(UploadResult {
                    filename: ready.filename, status: "error".into(),
                    error: Some(format!("DB connect: {}", e)),
                });
                continue;
            }
        };

        let device_id = match device::get_or_create_device_id(&conn).await {
            Ok(d)  => d,
            Err(e) => {
                results.push(UploadResult {
                    filename: ready.filename, status: "error".into(), error: Some(e),
                });
                continue;
            }
        };

        let crdt_doc = match CRDTDocument::new(
            ready.doc_id.clone(),
            ready.filename.clone(),
            format!("Binary file: {}", ready.content_type),
            device_id.clone(),
        ) {
            Ok(d)  => d,
            Err(e) => {
                results.push(UploadResult {
                    filename: ready.filename, status: "error".into(), error: Some(e),
                });
                continue;
            }
        };

        let now        = chrono::Utc::now().to_rfc3339();
        let vault_path = ready.vault_path.to_string_lossy().to_string();

        match conn.execute(
            "INSERT INTO documents (
                id, filename, automerge_state, vault_path, content_type,
                text_content, device_id, last_modified_at, updated_at,
                status, needs_upload, is_synced, version, epoch_id
            ) VALUES (?, ?, ?, ?, ?, '', ?, ?, ?, 'pending', 1, 0, 1, ?)",
            libsql::params![
                ready.doc_id.clone(),
                ready.filename.clone(),
                crdt_doc.automerge_state,
                vault_path,
                ready.content_type,
                device_id,
                now.clone(),
                now,
                epoch_id,
            ],
        ).await {
            Ok(_) => {
                log::info!("[Vault] ✅ '{}' stored (vault file)", ready.filename);
                let _ = app.emit("fs-upload-progress", serde_json::json!({
                    "path": ready.path_str, "filename": ready.filename,
                    "status": "done", "progress": 100,
                }));
                results.push(UploadResult {
                    filename: ready.filename, status: "done".into(), error: None,
                });
            }
            Err(e) => {
                let err = format!("DB insert: {}", e);
                log::error!("[Vault] ❌ '{}': {}", ready.filename, err);
                let _ = app.emit("fs-upload-progress", serde_json::json!({
                    "path": ready.path_str, "filename": ready.filename,
                    "status": "error", "error": err.clone(),
                }));
                results.push(UploadResult {
                    filename: ready.filename, status: "error".into(), error: Some(err),
                });
            }
        }
    }

    let app_clone = app.clone();
    tokio::spawn(async move { let _ = engine::run_sync_cycle(&app_clone).await; });

    Ok(results)
}

// ══════════════════════════════════════════════════════════════════════════
// upload_file_chunk
// ══════════════════════════════════════════════════════════════════════════

#[tauri::command]
pub async fn upload_file_chunk(
    doc_id: String,
    filename: String,
    content_type: String,
    chunk_index: u32,
    total_chunks: u32,
    chunk_data_b64: String,
    state: tauri::State<'_, AppState>,
    app: AppHandle,
) -> Result<String, String> {
    let conn = crate::db::connect(&state.db).await.map_err(|e| e.to_string())?;

    let chunk_bytes = base64::engine::general_purpose::STANDARD
        .decode(&chunk_data_b64)
        .map_err(|e| format!("Base64 decode failed: {}", e))?;

    conn.execute(
        "INSERT OR REPLACE INTO file_chunks (id, doc_id, chunk_index, total_chunks, data)
         VALUES (?, ?, ?, ?, ?)",
        libsql::params![
            format!("{}_{}", doc_id, chunk_index),
            doc_id.clone(),
            chunk_index as i64,
            total_chunks as i64,
            chunk_bytes,
        ],
    ).await.map_err(|e| e.to_string())?;

    let mut count_rows = conn.query(
        "SELECT COUNT(*) FROM file_chunks WHERE doc_id = ?",
        libsql::params![doc_id.clone()],
    ).await.map_err(|e| e.to_string())?;

    let received = if let Some(row) = count_rows.next().await.map_err(|e| e.to_string())? {
        match row.get_value(0).ok() {
            Some(libsql::Value::Integer(i)) => i as u32,
            _ => 0,
        }
    } else { 0 };

    if received < total_chunks {
        log::info!("[Chunk] '{}' {}/{}", filename, received, total_chunks);
        return Ok(format!("CHUNK_OK:{}/{}", received, total_chunks));
    }

    // All chunks received — assemble
    let mut chunk_rows = conn.query(
        "SELECT data FROM file_chunks WHERE doc_id = ? ORDER BY chunk_index ASC",
        libsql::params![doc_id.clone()],
    ).await.map_err(|e| e.to_string())?;

    let mut assembled: Vec<u8> = Vec::new();
    while let Some(row) = chunk_rows.next().await.map_err(|e| e.to_string())? {
        match row.get_value(0).ok() {
            Some(libsql::Value::Blob(b)) => assembled.extend_from_slice(&b),
            _ => return Err("Corrupt chunk data in staging table".to_string()),
        }
    }

    let assembled_len = assembled.len();

    let device_id = device::get_or_create_device_id(&conn).await?;
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

    // Encrypt assembled chunks before storing
    let encrypted = state.vault_key.encrypt(&assembled);
    drop(assembled);

    conn.execute(
        "INSERT OR REPLACE INTO documents (
            id, filename, automerge_state, binary_content, content_type,
            text_content, device_id, last_modified_at, updated_at,
            status, needs_upload, is_synced, version
        ) VALUES (?, ?, ?, ?, ?, '', ?, ?, ?, 'pending', 1, 0, 1)",
        libsql::params![
            doc_id.clone(),
            filename.clone(),
            crdt_doc.automerge_state,
            encrypted,
            safe_content_type,
            device_id,
            now.clone(),
            now,
        ],
    ).await.map_err(|e| e.to_string())?;

    conn.execute(
        "DELETE FROM file_chunks WHERE doc_id = ?",
        libsql::params![doc_id.clone()],
    ).await.map_err(|e| e.to_string())?;

    log::info!("✅ [Chunked] Assembled '{}' from {} chunks ({} bytes)", filename, total_chunks, assembled_len);
    tokio::spawn(async move { let _ = engine::run_sync_cycle(&app).await; });
    Ok("ASSEMBLED".to_string())
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
    let conn = crate::db::connect(&state.db).await.map_err(|e| e.to_string())?;
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
    tokio::spawn(async move { let _ = engine::run_sync_cycle(&app).await; });
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
    let conn = crate::db::connect(&state.db).await.map_err(|e| e.to_string())?;
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
            let crdt_doc = CRDTDocument::new(id.clone(), filename.clone(), text_content.clone(), device_id.clone())?;
            crdt_doc.automerge_state
        } else {
            let mut crdt_doc = CRDTDocument::from_db(
                id.clone(), filename, automerge_state, device_id.clone(), now.clone(), false, true,
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
            libsql::params![new_automerge_state, text_content, now, id],
        ).await.map_err(|e| e.to_string())?;

        log::info!("✅ [CRDT] Document updated");
        tokio::spawn(async move { let _ = engine::run_sync_cycle(&app).await; });
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
    let conn = crate::db::connect(&state.db).await.map_err(|e| e.to_string())?;
    conn.execute("DELETE FROM documents WHERE id = ?", libsql::params![id])
        .await
        .map_err(|e| e.to_string())?;
    log::info!("🗑️  Document deleted");
    Ok(())
}

// ══════════════════════════════════════════════════════════════════════════
// rename_document
// ══════════════════════════════════════════════════════════════════════════

#[tauri::command]
pub async fn rename_document(
    id: String,
    new_name: String,
    state: tauri::State<'_, AppState>,
    app: AppHandle,
) -> Result<(), String> {
    let conn = crate::db::connect(&state.db).await.map_err(|e| e.to_string())?;
    
    log::info!("✏️  Renaming document {} to '{}'", id, new_name);

    conn.execute(
        "UPDATE documents SET 
            filename = ?, 
            updated_at = datetime('now'),
            version = version + 1,
            needs_upload = 1,
            is_synced = 0,
            status = 'pending'
         WHERE id = ?",
        libsql::params![new_name, id],
    ).await.map_err(|e| e.to_string())?;

    log::info!("✅ Document renamed");
    tokio::spawn(async move { let _ = engine::run_sync_cycle(&app).await; });
    Ok(())
}

// ══════════════════════════════════════════════════════════════════════════
// get_file_bytes — decrypt a vault document and return raw bytes to the
// frontend for download (avoids needing fs:read permissions on the frontend).
// ══════════════════════════════════════════════════════════════════════════

#[tauri::command]
pub async fn get_file_bytes(
    id: String,
    state: tauri::State<'_, AppState>,
) -> Result<Vec<u8>, String> {
    let conn = crate::db::connect(&state.db).await.map_err(|e| e.to_string())?;

    let mut rows = conn.query(
        "SELECT binary_content, vault_path FROM documents WHERE id = ?",
        libsql::params![id.clone()],
    ).await.map_err(|e| e.to_string())?;

    let row = rows.next().await.map_err(|e| e.to_string())?
        .ok_or_else(|| "File not found".to_string())?;

    let binary_content = match row.get_value(0).ok() {
        Some(libsql::Value::Blob(b)) if !b.is_empty() => Some(b),
        _ => None,
    };
    let vault_path_str = match row.get_value(1).ok() {
        Some(libsql::Value::Text(s)) if !s.is_empty() => Some(s),
        _ => None,
    };

    if let Some(vp) = vault_path_str {
        vault::decrypt_file_any(std::path::Path::new(&vp), &state.vault_key)
            .map_err(|e| format!("Decrypt failed: {}", e))
    } else if let Some(enc) = binary_content {
        state.vault_key.decrypt(&enc)
            .map_err(|e| format!("Decrypt failed: {}", e))
    } else {
        Err("No file content found".to_string())
    }
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
    let conn = crate::db::connect(&state.db).await.map_err(|e| e.to_string())?;

    let mut rows = conn.query(
        "SELECT binary_content, vault_path FROM documents WHERE id = ?",
        libsql::params![id.clone()],
    ).await.map_err(|e| e.to_string())?;

    let row = rows.next().await.map_err(|e| e.to_string())?
        .ok_or_else(|| "File not found. Please sync first.".to_string())?;

    let binary_content = match row.get_value(0).ok() {
        Some(libsql::Value::Blob(b)) if !b.is_empty() => Some(b),
        _ => None,
    };
    let vault_path_str = match row.get_value(1).ok() {
        Some(libsql::Value::Text(s)) if !s.is_empty() => Some(s),
        _ => None,
    };

    // Decrypt: prefer vault file (streaming), fall back to legacy blob
    let bytes = if let Some(vp) = vault_path_str {
        vault::decrypt_file_any(std::path::Path::new(&vp), &state.vault_key)
            .map_err(|e| format!("Vault decrypt failed: {}", e))?
    } else if let Some(enc) = binary_content {
        state.vault_key.decrypt(&enc)
            .map_err(|e| format!("Vault decrypt failed: {}", e))?
    } else {
        return Err("No file content found for this document.".to_string());
    };

    let app_dir   = app.path().app_data_dir().map_err(|e| e.to_string())?;
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
// ══════════════════════════════════════════════════════════════════════════

#[tauri::command]
pub async fn save_edited_file(
    id: String,
    local_path: String,
    current_version: i64,
    state: tauri::State<'_, AppState>,
    app: AppHandle,
) -> Result<String, String> {
    let conn = crate::db::connect(&state.db).await.map_err(|e| e.to_string())?;

    let new_bytes = fs::read(&local_path).map_err(|e| format!("Failed to read file: {}", e))?;

    let mut rows = conn.query(
        "SELECT binary_content, version, vault_path FROM documents WHERE id = ?",
        libsql::params![id.clone()]
    ).await.map_err(|e| e.to_string())?;

    let (binary_content_opt, server_version, vault_path_opt) =
        if let Some(row) = rows.next().await.map_err(|e| e.to_string())? {
            let blob = match row.get_value(0).ok() {
                Some(libsql::Value::Blob(b)) if !b.is_empty() => Some(b),
                _ => None,
            };
            let ver = get_int(&row, 1);
            let vp  = match row.get_value(2).ok() {
                Some(libsql::Value::Text(s)) if !s.is_empty() => Some(s),
                _ => None,
            };
            (blob, ver, vp)
        } else {
            return Err("Document deleted".to_string());
        };

    // Decrypt current version for comparison
    let current_bytes = if let Some(ref vp) = vault_path_opt {
        vault::decrypt_file_any(std::path::Path::new(vp), &state.vault_key)
            .map_err(|e| format!("Vault decrypt failed: {}", e))?
    } else if let Some(enc) = binary_content_opt {
        state.vault_key.decrypt(&enc)
            .map_err(|e| format!("Vault decrypt failed: {}", e))?
    } else {
        return Err("No binary content found in DB".to_string());
    };

    if current_bytes == new_bytes {
        return Ok("NO_CHANGES".to_string());
    }

    if server_version != current_version {
        return handle_conflict(&conn, &id, &local_path, current_version, &state.vault_key).await;
    }

    let new_version = current_version + 1;

    // Re-encrypt: vault file if available, otherwise blob
    let rows_affected = if let Some(ref vp) = vault_path_opt {
        // Overwrite the existing vault file with new encrypted content
        // Use v2 if epoch key is available; otherwise v1
        let epoch_snap = *state.epoch_key.read().await;
        match epoch_snap {
            Some(ref ek) => vault::encrypt_file_v2(
                std::path::Path::new(&local_path),
                std::path::Path::new(vp),
                &state.vault_key, ek, |_, _| {},
            ).map(|_| ()).map_err(|e| format!("Re-encrypt failed: {}", e))?,
            None => vault::encrypt_file(
                std::path::Path::new(&local_path),
                std::path::Path::new(vp),
                &state.vault_key, |_, _| {},
            ).map(|_| ()).map_err(|e| format!("Re-encrypt failed: {}", e))?,
        };

        conn.execute(
            "UPDATE documents SET
                last_modified_at = ?,
                needs_upload     = 1,
                is_synced        = 0,
                status           = 'pending',
                version          = ?
             WHERE id = ? AND version = ?",
            libsql::params![
                chrono::Utc::now().to_rfc3339(),
                new_version,
                id.clone(),
                current_version
            ]
        ).await.map_err(|e| e.to_string())?
    } else {
        let encrypted_new = state.vault_key.encrypt(&new_bytes);
        conn.execute(
            "UPDATE documents SET
                binary_content   = ?,
                last_modified_at = ?,
                needs_upload     = 1,
                is_synced        = 0,
                status           = 'pending',
                version          = ?
             WHERE id = ? AND version = ?",
            libsql::params![
                encrypted_new,
                chrono::Utc::now().to_rfc3339(),
                new_version,
                id.clone(),
                current_version
            ]
        ).await.map_err(|e| e.to_string())?
    };

    let rows_affected = rows_affected;

    if rows_affected == 0 {
        return handle_conflict(&conn, &id, &local_path, current_version, &state.vault_key).await;
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
    _base_version: i64,
    vault_key: &crate::vault::VaultKey,
) -> Result<String, String> {
    log::warn!("⚠️ Conflict detected for {}. Creating copy.", original_id);

    let plaintext = fs::read(local_path).map_err(|e| e.to_string())?;
    let bytes     = vault_key.encrypt(&plaintext);

    let conflict_id = Uuid::new_v4().to_string();
    let now         = chrono::Utc::now().to_rfc3339();

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
// Phase 1 — Pull Sync
//
// get_sync_stats  : ask server how many files the user has
// pull_sync       : compare local doc IDs vs server → download missing files
// download_file   : fetch one file by doc_id, decrypt, store locally
// ══════════════════════════════════════════════════════════════════════════

#[derive(Serialize)]
pub struct SyncStats {
    pub total_files:      i64,
    pub total_size_bytes: i64,
    pub synced:           i64,
    pub indexed:          i64,
    pub pending:          i64,
}

#[derive(Serialize)]
pub struct PullResult {
    pub downloaded: usize,
    pub skipped:    usize,
    pub errors:     Vec<String>,
}

#[tauri::command]
pub async fn get_sync_stats(state: tauri::State<'_, AppState>) -> Result<SyncStats, String> {
    let conn  = crate::db::connect(&state.db).await.map_err(|e| e.to_string())?;
    let token = get_local_token_inner(&conn).await?;
    let url   = get_server_url_inner(&conn).await?;

    let resp = reqwest::Client::new()
        .get(format!("{}/api/v1/sync/stats", url))
        .bearer_auth(&token)
        .send()
        .await
        .map_err(|e| format!("Stats request failed: {}", e))?;

    let body: serde_json::Value = resp.json().await.map_err(|e| e.to_string())?;

    Ok(SyncStats {
        total_files:      body["total_files"].as_i64().unwrap_or(0),
        total_size_bytes: body["total_size_bytes"].as_i64().unwrap_or(0),
        synced:           body["synced"].as_i64().unwrap_or(0),
        indexed:          body["indexed"].as_i64().unwrap_or(0),
        pending:          body["pending"].as_i64().unwrap_or(0),
    })
}

#[tauri::command]
pub async fn pull_sync(
    since: Option<String>,
    state: tauri::State<'_, AppState>,
    app: AppHandle,
) -> Result<PullResult, String> {
    let conn  = crate::db::connect(&state.db).await.map_err(|e| e.to_string())?;
    let token = get_local_token_inner(&conn).await?;
    let url   = get_server_url_inner(&conn).await?;

    let since_ts = since.unwrap_or_else(|| "1970-01-01T00:00:00Z".to_string());

    log::info!("[PullSync] Fetching changes since {}", since_ts);

    let resp = reqwest::Client::new()
        .get(format!("{}/api/v1/sync/changes", url))
        .query(&[("since", &since_ts)])
        .bearer_auth(&token)
        .send()
        .await
        .map_err(|e| format!("get_changes request failed: {}", e))?;

    let body: serde_json::Value = resp.json().await.map_err(|e| e.to_string())?;
    let changes = body["changes"].as_array().cloned().unwrap_or_default();

    log::info!("[PullSync] Server returned {} changes", changes.len());

    let mut downloaded = 0usize;
    let mut skipped    = 0usize;
    let mut errors     = Vec::new();

    for doc in &changes {
        let doc_id   = doc["id"].as_str().unwrap_or("").to_string();
        let filename = doc["filename"].as_str().unwrap_or("unknown").to_string();

        // Skip if we already have this doc locally
        let exists: bool = conn.query(
            "SELECT 1 FROM documents WHERE id = ? LIMIT 1",
            libsql::params![doc_id.clone()],
        ).await.map_err(|e| e.to_string())?
        .next().await.map_err(|e| e.to_string())?
        .is_some();

        if exists {
            skipped += 1;
            continue;
        }

        // Download + store
        match download_and_store(&conn, doc, &token, &app).await {
            Ok(()) => {
                downloaded += 1;
                log::info!("[PullSync] Downloaded: {}", filename);
            }
            Err(e) => {
                log::error!("[PullSync] Failed {}: {}", filename, e);
                errors.push(format!("{}: {}", filename, e));
            }
        }
    }

    log::info!("[PullSync] Done — downloaded={} skipped={} errors={}", downloaded, skipped, errors.len());
    Ok(PullResult { downloaded, skipped, errors })
}

#[tauri::command]
pub async fn download_file(
    doc_id: String,
    state: tauri::State<'_, AppState>,
    app: AppHandle,
) -> Result<String, String> {
    let conn  = crate::db::connect(&state.db).await.map_err(|e| e.to_string())?;
    let token = get_local_token_inner(&conn).await?;
    let url   = get_server_url_inner(&conn).await?;

    // Get presigned download URL from server
    let resp = reqwest::Client::new()
        .get(format!("{}/api/v1/sync/download/{}", url, doc_id))
        .bearer_auth(&token)
        .send()
        .await
        .map_err(|e| format!("Download request failed: {}", e))?;

    let meta: serde_json::Value = resp.json().await.map_err(|e| e.to_string())?;

    match download_and_store(&conn, &meta, &token, &app).await {
        Ok(()) => Ok(meta["filename"].as_str().unwrap_or("file").to_string()),
        Err(e) => Err(e),
    }
}

// Internal: download a file from S3 presigned URL and store it locally
async fn download_and_store(
    conn: &libsql::Connection,
    doc: &serde_json::Value,
    _token: &str,
    _app: &AppHandle,
) -> Result<(), String> {
    let doc_id       = doc["id"].as_str().unwrap_or("").to_string();
    let filename     = doc["filename"].as_str().unwrap_or("file").to_string();
    let content_type = doc["content_type"].as_str().unwrap_or("application/octet-stream").to_string();
    let download_url = doc["download_url"].as_str().unwrap_or("");

    if download_url.is_empty() {
        return Err("No download URL available".to_string());
    }

    // Fetch encrypted vault bytes from S3
    let bytes = reqwest::get(download_url)
        .await
        .map_err(|e| format!("S3 fetch failed: {}", e))?
        .bytes()
        .await
        .map_err(|e| format!("Read bytes failed: {}", e))?
        .to_vec();

    let now = chrono::Utc::now().to_rfc3339();

    // Store encrypted bytes locally (vault file stays encrypted at rest)
    conn.execute(
        "INSERT INTO documents (
            id, filename, binary_content, content_type,
            text_content, status, is_synced, needs_upload,
            needs_download, version, created_at, updated_at
        ) VALUES (?, ?, ?, ?, '', 'synced', 1, 0, 0, 1, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            binary_content = excluded.binary_content,
            status         = 'synced',
            is_synced      = 1,
            needs_download = 0,
            updated_at     = excluded.updated_at",
        libsql::params![
            doc_id,
            filename,
            bytes,
            content_type,
            now.clone(),
            now,
        ],
    ).await.map_err(|e| format!("Local store failed: {}", e))?;

    Ok(())
}

// Read server URL from local_identity
async fn get_server_url_inner(conn: &libsql::Connection) -> Result<String, String> {
    let mut rows = conn.query(
        "SELECT server_url FROM local_identity WHERE id = 'singleton' LIMIT 1",
        libsql::params![],
    ).await.map_err(|e| e.to_string())?;

    if let Some(row) = rows.next().await.map_err(|e| e.to_string())? {
        match row.get_value(0).ok() {
            Some(libsql::Value::Text(s)) if !s.is_empty() => Ok(s),
            _ => Ok("http://localhost:4201".to_string()),
        }
    } else {
        Ok("http://localhost:4201".to_string())
    }
}

// Read access_token from local_identity
async fn get_local_token_inner(conn: &libsql::Connection) -> Result<String, String> {
    let mut rows = conn.query(
        "SELECT access_token FROM local_identity WHERE id = 'singleton' LIMIT 1",
        libsql::params![],
    ).await.map_err(|e| e.to_string())?;

    if let Some(row) = rows.next().await.map_err(|e| e.to_string())? {
        match row.get_value(0).ok() {
            Some(libsql::Value::Text(s)) if !s.is_empty() => Ok(s),
            _ => Err("No token — please log in".to_string()),
        }
    } else {
        Err("No token — please log in".to_string())
    }
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
