use crate::{AppState, device, sync::engine, crdt::CRDTDocument, vault};
use lancedb::query::{ExecutableQuery, QueryBase};
use arrow_array::Array;
use futures::StreamExt;
use tauri::{AppHandle, Manager, Emitter};
use uuid::Uuid;
use base64::Engine;
use std::fs;
use std::sync::{Arc, atomic::{AtomicUsize, Ordering}};
use serde::{Deserialize, Serialize};
use rayon::prelude::*;
use arrow::record_batch::{RecordBatch, RecordBatchIterator};
use arrow::array::{StringArray, BinaryArray, Int64Array, Float32Array, FixedSizeListArray};
use arrow::datatypes::{Schema, Field, DataType};

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
    pub file_size: i64,
    pub vault_category: String,
    pub conflict_copy_of: Option<String>,
}

// ══════════════════════════════════════════════════════════════════════════
// list_documents
// ══════════════════════════════════════════════════════════════════════════

#[tauri::command]
pub async fn list_documents(state: tauri::State<'_, AppState>, vault_name: String) -> Result<Vec<DocumentInfo>, String> {
    let table = state.lancedb.open_table(&vault_name).await.map_err(|e| e.to_string())?;
    let mut stream = table.query().only_if("status != 'deleted'").execute().await.map_err(|e| e.to_string())?;

    let mut docs = Vec::new();
    while let Some(batch_res) = stream.next().await {
        let batch = batch_res.map_err(|e| e.to_string())?;
        
        let id_col = batch.column(0).as_any().downcast_ref::<arrow::array::StringArray>().unwrap();
        let name_col = batch.column(1).as_any().downcast_ref::<arrow::array::StringArray>().unwrap();
        let text_col = batch.column(3).as_any().downcast_ref::<arrow::array::StringArray>().unwrap();
        let status_col = batch.column(13).as_any().downcast_ref::<arrow::array::StringArray>().unwrap();
        let created_col = batch.column(9).as_any().downcast_ref::<arrow::array::StringArray>().unwrap();
        let updated_col = batch.column(10).as_any().downcast_ref::<arrow::array::StringArray>().unwrap();
        let type_col = batch.column(5).as_any().downcast_ref::<arrow::array::StringArray>().unwrap();
        let ver_col = batch.column(8).as_any().downcast_ref::<arrow::array::Int64Array>().unwrap();
        let size_col = batch.column(11).as_any().downcast_ref::<arrow::array::Int64Array>().unwrap();
        let cat_col = batch.column(12).as_any().downcast_ref::<arrow::array::StringArray>().unwrap();

        for i in 0..batch.num_rows() {
            docs.push(DocumentInfo {
                id:               id_col.value(i).to_string(),
                filename:         name_col.value(i).to_string(),
                text_content:     if text_col.is_null(i) { String::new() } else { text_col.value(i).to_string() },
                is_synced:        if status_col.value(i) == "synced" { 1 } else { 0 },
                status:           status_col.value(i).to_string(),
                created_at:       created_col.value(i).to_string(),
                updated_at:       updated_col.value(i).to_string(),
                content_type:     type_col.value(i).to_string(),
                version:          ver_col.value(i),
                file_size:        size_col.value(i),
                vault_category:   cat_col.value(i).to_string(),
                conflict_copy_of: None, // Handle conflicts later
            });
        }
    }
    log::info!("📂 [ListDocs] Found {} documents in table '{}'", docs.len(), vault_name);
    Ok(docs)
}

// ══════════════════════════════════════════════════════════════════════════
// search_documents  (FTS-powered, falls back to LIKE)
// ══════════════════════════════════════════════════════════════════════════

#[tauri::command]
pub async fn search_documents(
    state: tauri::State<'_, AppState>,
    query: String,
    vault_name: Option<String>,
) -> Result<Vec<DocumentInfo>, String> {
    if query.trim().is_empty() {
        return Ok(vec![]);
    }

    let vaults: Vec<&str> = match vault_name.as_deref() {
        Some("all") | None => vec!["personal_vault", "private_vault", "social_vault"],
        Some(v) => vec![v],
    };

    let mut all_results: Vec<DocumentInfo> = Vec::new();

    for vname in vaults {
        let table = match state.lancedb.open_table(vname).await {
            Ok(t)  => t,
            Err(e) => { log::warn!("⚠️ [Search] Cannot open '{}': {}", vname, e); continue; }
        };

        // ── Try native FTS first ───────────────────────────────────────
        let fts_result = table
            .query()
            .full_text_search(lancedb::index::scalar::FullTextSearchQuery::new(query.clone()))
            .only_if("status != 'deleted'")
            .limit(100)
            .execute()
            .await;

        let mut stream = match fts_result {
            Ok(s)  => s,
            Err(_) => {
                // FTS index not yet built — fall back to LIKE
                log::debug!("🔎 [Search] FTS not ready for '{}', using LIKE fallback", vname);
                let q = query.replace("'", "''");
                let filter = format!(
                    "status != 'deleted' AND (filename LIKE '%{q}%' OR text_content LIKE '%{q}%')"
                );
                match table.query().only_if(&filter).execute().await {
                    Ok(s)  => s,
                    Err(e) => { log::warn!("⚠️ [Search] LIKE fallback failed on '{}': {}", vname, e); continue; }
                }
            }
        };

        // ── Decode batches ─────────────────────────────────────────────
        while let Some(batch_res) = stream.next().await {
            let batch = batch_res.map_err(|e| e.to_string())?;
            let id_col      = batch.column(0).as_any().downcast_ref::<arrow::array::StringArray>().unwrap();
            let name_col    = batch.column(1).as_any().downcast_ref::<arrow::array::StringArray>().unwrap();
            let text_col    = batch.column(3).as_any().downcast_ref::<arrow::array::StringArray>().unwrap();
            let status_col  = batch.column(13).as_any().downcast_ref::<arrow::array::StringArray>().unwrap();
            let created_col = batch.column(9).as_any().downcast_ref::<arrow::array::StringArray>().unwrap();
            let updated_col = batch.column(10).as_any().downcast_ref::<arrow::array::StringArray>().unwrap();
            let type_col    = batch.column(5).as_any().downcast_ref::<arrow::array::StringArray>().unwrap();
            let ver_col     = batch.column(8).as_any().downcast_ref::<arrow::array::Int64Array>().unwrap();
            let size_col    = batch.column(11).as_any().downcast_ref::<arrow::array::Int64Array>().unwrap();
            let cat_col     = batch.column(12).as_any().downcast_ref::<arrow::array::StringArray>().unwrap();

            for i in 0..batch.num_rows() {
                all_results.push(DocumentInfo {
                    id:               id_col.value(i).to_string(),
                    filename:         name_col.value(i).to_string(),
                    text_content:     if text_col.is_null(i) { String::new() } else { text_col.value(i).to_string() },
                    is_synced:        if status_col.value(i) == "synced" { 1 } else { 0 },
                    status:           status_col.value(i).to_string(),
                    created_at:       created_col.value(i).to_string(),
                    updated_at:       updated_col.value(i).to_string(),
                    content_type:     type_col.value(i).to_string(),
                    version:          ver_col.value(i),
                    file_size:        size_col.value(i),
                    vault_category:   cat_col.value(i).to_string(),
                    conflict_copy_of: None,
                });
            }
        }
    }

    // De-duplicate by doc ID (FTS can return duplicates across vaults)
    all_results.dedup_by(|a, b| a.id == b.id);

    log::info!("🔍 [FTS Search] '{}' → {} results", query, all_results.len());
    Ok(all_results)
}

// ══════════════════════════════════════════════════════════════════════════
// rebuild_fts_indexes
// ══════════════════════════════════════════════════════════════════════════

#[tauri::command]
pub async fn rebuild_fts_indexes(state: tauri::State<'_, AppState>) -> Result<(), String> {
    state.lancedb.rebuild_fts_indexes().await.map_err(|e| e.to_string())?;
    log::info!("✅ [FTS] All vault indexes rebuilt");
    Ok(())
}

// ══════════════════════════════════════════════════════════════════════════
// upload_file  (single file via base64 IPC)
// ══════════════════════════════════════════════════════════════════════════

#[tauri::command]
pub async fn upload_file(
    filename: String,
    content_type: String,
    file_data_b64: String,
    vault_name: String,
    state: tauri::State<'_, AppState>,
    app: AppHandle,
) -> Result<(), String> {
    let doc_id = Uuid::new_v4().to_string();
    let device_id = device::get_or_create_device_id(&state.lancedb).await?;

    let raw_bytes = base64::engine::general_purpose::STANDARD
        .decode(&file_data_b64)
        .map_err(|e| format!("Base64 decode failed: {}", e))?;

    // Encrypt before storing — vault stores only ciphertext
    let vault_key_snapshot = *state.vault_key.read().await;
    let binary_data = vault_key_snapshot.encrypt(&raw_bytes);

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

    let table = state.lancedb.open_table(&vault_name).await.map_err(|e| e.to_string())?;
    let schema = table.schema().await.map_err(|e| e.to_string())?;
    
    let batch = arrow::array::RecordBatch::try_new(
        schema.clone(),
        vec![
            Arc::new(arrow::array::StringArray::from(vec![doc_id.clone()])),
            Arc::new(arrow::array::StringArray::from(vec![filename.clone()])),
            Arc::new(arrow::array::BinaryArray::from(vec![crdt_doc.automerge_state.as_slice()])),
            Arc::new(arrow::array::StringArray::from(vec![None as Option<&str>])), // text_content
            Arc::new(arrow::array::BinaryArray::from(vec![Some(binary_data.as_slice())])),
            Arc::new(arrow::array::StringArray::from(vec![safe_content_type])),
            Arc::new(arrow::array::StringArray::from(vec![None as Option<&str>])), // vault_path
            Arc::new(arrow::array::StringArray::from(vec![device_id])),
            Arc::new(arrow::array::Int64Array::from(vec![1])), // version
            Arc::new(arrow::array::StringArray::from(vec![now.clone()])),
            Arc::new(arrow::array::StringArray::from(vec![now])),
            Arc::new(arrow::array::Int64Array::from(vec![raw_bytes.len() as i64])),
            Arc::new(arrow::array::StringArray::from(vec!["personal"])),
            Arc::new(arrow::array::StringArray::from(vec!["pending"])),
            Arc::new(arrow::array::FixedSizeListArray::try_new(
                Arc::new(arrow::datatypes::Field::new("item", arrow::datatypes::DataType::Float32, true)),
                 128, Arc::new(arrow::array::Float32Array::from(vec![0.0f32; 128])), None).unwrap()),
            Arc::new(arrow::array::StringArray::from(vec![None as Option<&str>])), // hash
        ],
    ).map_err(|e| e.to_string())?;

    let reader = arrow::record_batch::RecordBatchIterator::new(vec![Ok(batch)], schema);
    table.add(Box::new(reader)).execute().await.map_err(|e| e.to_string())?;

    log::info!("✅ [Binary] Uploaded {} ({}) to LanceDB", filename, doc_id);
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
    vault_name: String,
    category: vault::przma_vault::VaultCategory,
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
    let vault_key_snapshot = *state.vault_key.read().await;
    let app_emit    = app.clone();
    let total       = paths.len();
    let paths_copy  = paths.clone();
    let vault_dir_c = vault_dir.clone();

    // Snapshot epoch key once before entering the Rayon blocking context.
    // EpochPublicKey is Copy so this is a cheap stack copy, not a heap allocation.
    let epoch_key_snapshot: Option<vault::EpochPublicKey> = *state.epoch_key.read().await;
    let _epoch_id = epoch_key_snapshot.map(|ek| ek.epoch_id as i64);

    struct ReadyFile {
        doc_id:        String,
        path_str:      String,
        filename:      String,
        content_type:  String,
        vault_path:    std::path::PathBuf,
        original_size: u64,
        hash:          String,
    }

    // Extract things from state that we need in the blocking thread.
    // tauri::State itself cannot be moved into spawn_blocking because it's not 'static.
    let ldb_arc = Arc::clone(&state.lancedb);
    let _db_path = state.lancedb.get_uri().await.map_err(|e: anyhow::Error| e.to_string())?;

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

                    // ── Phase 1.1: Local CAS Check (Deduplication) ──────────────
                    let hash = match vault::cas::LocalCAS::compute_hash(path) {
                        Ok(h) => h,
                        Err(e) => {
                            let err = format!("Hash failed: {}", e);
                            return Err(UploadResult { filename, status: "error".into(), error: Some(err) });
                        }
                    };

                    // Check if this hash + category already exists in LanceDB (blocking on async for simplicity in Rayon thread)
                    let ldb = Arc::clone(&ldb_arc);
                    let hash_for_query = hash.clone();
                    let existing_vault = tauri::async_runtime::block_on(async move {
                        vault::cas::LocalCAS::find_existing_vault(&hash_for_query, &ldb).await.ok().flatten()
                    });

                    let file_size_hint = path.metadata().map(|m| m.len()).unwrap_or(0);
                    let doc_id = if let Some(ref path) = existing_vault {
                        // Reuse doc_id from the filename if possible, otherwise generate new
                        path.file_stem().and_then(|s| s.to_str()).unwrap_or(&Uuid::new_v4().to_string()).to_string()
                    } else {
                        Uuid::new_v4().to_string()
                    };
                    let vault_path = vault_dir_c.join(format!("{}.vault", doc_id));

                    if let Some(path) = existing_vault {
                        log::info!("[CAS] ♻️  Deduplicated: '{}' (hash: {})", filename, &hash[..8]);
                        let done = completed.fetch_add(1, Ordering::Relaxed) + 1;
                        let _ = app_emit.emit("fs-batch-progress", serde_json::json!({
                            "files_done":  done,
                            "files_total": total,
                            "percent":     (done * 100 / total.max(1)),
                        }));
                        return Ok(ReadyFile { doc_id, path_str, filename, content_type, vault_path: path, original_size: file_size_hint, hash });
                    }

                    // ── Streaming encrypt → .vault file ──────────────────
                    //
                    // For files >50 MB we emit `vault-encrypt-progress` events so
                    // the frontend can show a per-file progress bar.  Smaller files
                    // are fast enough that a single "done" event is sufficient.
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
                            vault::encrypt_file_v2(path, &vault_path, &vault_key_snapshot, ek, progress_cb)
                                .map(|r| r.original_size)
                        },
                        None => {
                            log::warn!("[Vault] ⚠️ Falling back to V1 encryption for '{}' (No Epoch Key)", filename);
                            vault::encrypt_file(path, &vault_path, &vault_key_snapshot, progress_cb)
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
                        "hash":         hash,
                        "category":     category,
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
                    Ok(ReadyFile { doc_id, path_str, filename, content_type, vault_path, original_size, hash })
                })
                .collect()
        })
        .await
        .map_err(|e| format!("Parallel encrypt failed: {}", e))?;

    // ── Phase 2: Sequential LanceDB writes ───────────
    let mut results: Vec<UploadResult> = Vec::new();

    let table = state.lancedb.open_table(&vault_name).await.map_err(|e| e.to_string())?;
    let schema = table.schema().await.map_err(|e| e.to_string())?;
    let device_id = device::get_or_create_device_id(&state.lancedb).await?;

    for item in phase1 {
        let ready = match item {
            Err(r) => { results.push(r); continue; }
            Ok(r)  => r,
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

        // ── Phase 2.1: Metadata Deduplication Check ──────────
        let mut check_stream = table.query()
            .only_if(format!("content_hash = '{}'", ready.hash))
            .execute().await.map_err(|e| e.to_string())?;
        
        if let Some(existing_batch) = check_stream.next().await {
            let eb = existing_batch.map_err(|e| e.to_string())?;
            if eb.num_rows() > 0 {
                log::info!("[Vault] ♻️  Skipping duplicate metadata for '{}' (hash matches)", ready.filename);
                results.push(UploadResult {
                    filename: ready.filename, status: "skipped".into(), error: None,
                });
                continue;
            }
        }

        let batch = RecordBatch::try_new(
            schema.clone(),
            vec![
                Arc::new(arrow::array::StringArray::from(vec![ready.doc_id.clone()])),
                Arc::new(arrow::array::StringArray::from(vec![ready.filename.clone()])),
                Arc::new(arrow::array::BinaryArray::from(vec![crdt_doc.automerge_state.as_slice()])),
                Arc::new(arrow::array::StringArray::from(vec![None as Option<&str>])), // text_content
                Arc::new(arrow::array::BinaryArray::from(vec![None as Option<&[u8]>])), // binary_content (stored in vault_path)
                Arc::new(arrow::array::StringArray::from(vec![ready.content_type])),
                Arc::new(arrow::array::StringArray::from(vec![Some(vault_path.as_str())])),
                Arc::new(arrow::array::StringArray::from(vec![device_id.clone()])),
                Arc::new(arrow::array::Int64Array::from(vec![1])), // version
                Arc::new(arrow::array::StringArray::from(vec![now.clone()])),
                Arc::new(arrow::array::StringArray::from(vec![now])),
                Arc::new(arrow::array::Int64Array::from(vec![ready.original_size as i64])),
                Arc::new(arrow::array::StringArray::from(vec![category.to_string()])),
                Arc::new(arrow::array::StringArray::from(vec!["pending"])),
                Arc::new(arrow::array::FixedSizeListArray::try_new(
                    Arc::new(arrow::datatypes::Field::new("item", arrow::datatypes::DataType::Float32, true)),
                     128, Arc::new(arrow::array::Float32Array::from(vec![0.0f32; 128])), None).unwrap()),
                Arc::new(arrow::array::StringArray::from(vec![Some(ready.hash.as_str())])),
            ],
        ).map_err(|e| e.to_string())?;

        let reader = arrow::record_batch::RecordBatchIterator::new(vec![Ok(batch)], schema.clone());
        match table.add(Box::new(reader)).execute().await {
            Ok(_) => {
                // Also update LanceDB index for future deduplication
                let _ = state.lancedb.add_vault_item(&ready.hash, &vault_path, &category.to_string()).await;
                
                log::info!("[Vault] ✅ '{}' stored in LanceDB category '{}'", ready.filename, category);
                let _ = app.emit("fs-upload-progress", serde_json::json!({
                    "path": ready.path_str, "filename": ready.filename,
                    "status": "done", "progress": 100,
                }));
                results.push(UploadResult {
                    filename: ready.filename, status: "done".into(), error: None,
                });
            }
            Err(e) => {
                let err = format!("LanceDB insert: {}", e);
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
    let chunk_bytes = base64::engine::general_purpose::STANDARD
        .decode(&chunk_data_b64)
        .map_err(|e| format!("Base64 decode failed: {}", e))?;

    let table = state.lancedb.open_table("file_chunks").await.map_err(|e| e.to_string())?;
    let schema = table.schema().await.map_err(|e| e.to_string())?;
    
    let batch = RecordBatch::try_new(
        schema.clone(),
        vec![
            Arc::new(arrow::array::StringArray::from(vec![format!("{}_{}", doc_id, chunk_index)])),
            Arc::new(arrow::array::StringArray::from(vec![doc_id.clone()])),
            Arc::new(arrow::array::Int64Array::from(vec![chunk_index as i64])),
            Arc::new(arrow::array::Int64Array::from(vec![total_chunks as i64])),
            Arc::new(arrow::array::BinaryArray::from(vec![Some(chunk_bytes.as_slice())])),
            Arc::new(arrow::array::Int64Array::from(vec![None as Option<i64>])), // epoch_id
            Arc::new(arrow::array::StringArray::from(vec![chrono::Utc::now().to_rfc3339()])), // created_at
        ],
    ).map_err(|e| e.to_string())?;

    let reader = arrow::record_batch::RecordBatchIterator::new(vec![Ok(batch)], schema);
    table.add(Box::new(reader)).execute().await.map_err(|e| e.to_string())?;

    let mut stream = table.query().only_if(format!("doc_id = '{}'", doc_id)).execute().await.map_err(|e| e.to_string())?;
    let mut received: u32 = 0;
    while let Some(batch_res) = stream.next().await {
        let batch = batch_res.map_err(|e: lancedb::Error| e.to_string())?;
        received += batch.num_rows() as u32;
    }

    if received < total_chunks {
        log::info!("[Chunk] '{}' {}/{}", filename, received, total_chunks);
        return Ok(format!("CHUNK_OK:{}/{}", received, total_chunks));
    }

    // All chunks received — assemble
    let mut stream = table.query()
        .only_if(format!("doc_id = '{}'", doc_id))
        .execute().await.map_err(|e| e.to_string())?;

    let mut chunks: Vec<(i64, Vec<u8>)> = Vec::new();
    while let Some(batch_res) = stream.next().await {
        let batch = batch_res.map_err(|e: lancedb::Error| e.to_string())?;
        let idx_col = batch.column(2).as_any().downcast_ref::<arrow::array::Int64Array>().unwrap();
        let data_col = batch.column(4).as_any().downcast_ref::<arrow::array::BinaryArray>().unwrap();
        for i in 0..batch.num_rows() {
            chunks.push((idx_col.value(i), data_col.value(i).to_vec()));
        }
    }
    chunks.sort_by_key(|c| c.0);
    
    let mut assembled = Vec::new();
    for (_, data) in chunks {
        assembled.extend_from_slice(&data);
    }

    let assembled_len = assembled.len();
    let device_id = device::get_or_create_device_id(&state.lancedb).await?;
    
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
    let vault_key_snapshot = *state.vault_key.read().await;
    let encrypted = vault_key_snapshot.encrypt(&assembled);
    drop(assembled);

    let doc_table = state.lancedb.open_table("private_vault").await.map_err(|e| e.to_string())?;
    let doc_schema = doc_table.schema().await.map_err(|e| e.to_string())?;
    
    let doc_batch = RecordBatch::try_new(
        doc_schema.clone(),
        vec![
            Arc::new(arrow::array::StringArray::from(vec![doc_id.clone()])),
            Arc::new(arrow::array::StringArray::from(vec![filename.clone()])),
            Arc::new(arrow::array::BinaryArray::from(vec![Some(crdt_doc.automerge_state.as_slice())])),
            Arc::new(arrow::array::StringArray::from(vec![None as Option<&str>])), // 3: text_content
            Arc::new(arrow::array::BinaryArray::from(vec![Some(encrypted.as_slice())])), // 4: binary_content
            Arc::new(arrow::array::StringArray::from(vec![safe_content_type])), // 5: content_type
            Arc::new(arrow::array::StringArray::from(vec![None as Option<&str>])), // 6: vault_path
            Arc::new(arrow::array::StringArray::from(vec![device_id])), // 7: device_id
            Arc::new(arrow::array::Int64Array::from(vec![1])), // 8: version
            Arc::new(arrow::array::StringArray::from(vec![now.clone()])), // 9: created_at
            Arc::new(arrow::array::StringArray::from(vec![now.clone()])), // 10: updated_at
            Arc::new(arrow::array::Int64Array::from(vec![assembled_len as i64])), // 11: file_size
            Arc::new(arrow::array::StringArray::from(vec!["private"])), // 12: vault_category
            Arc::new(arrow::array::StringArray::from(vec!["pending"])), // 13: status
            Arc::new(arrow::array::FixedSizeListArray::try_new(
                Arc::new(arrow::datatypes::Field::new("item", arrow::datatypes::DataType::Float32, true)),
                 128, Arc::new(arrow::array::Float32Array::from(vec![0.0f32; 128])), None).unwrap()), // 14: vector
            Arc::new(arrow::array::StringArray::from(vec![None as Option<&str>])), // 15: content_hash
        ],
    ).map_err(|e| e.to_string())?;

    let doc_reader = arrow::record_batch::RecordBatchIterator::new(vec![Ok(doc_batch)], doc_schema);
    doc_table.add(Box::new(doc_reader)).execute().await.map_err(|e| e.to_string())?;

    // Cleanup chunks
    table.delete(format!("doc_id = '{}'", doc_id).as_str()).await.map_err(|e| e.to_string())?;

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
    vault_name: String,
    _tags: Vec<String>,
    state: tauri::State<'_, AppState>,
    app: AppHandle,
) -> Result<(), String> {
    let doc_id = Uuid::new_v4().to_string();
    let device_id = device::get_or_create_device_id(&state.lancedb).await?;

    let crdt_doc = CRDTDocument::new(
        doc_id.clone(),
        filename.clone(),
        text_content.clone(),
        device_id.clone(),
    )?;

    let now = chrono::Utc::now().to_rfc3339();
    let table = state.lancedb.open_table(&vault_name).await.map_err(|e| e.to_string())?;
    let schema = table.schema().await.map_err(|e| e.to_string())?;

    // Determine vault_category from vault_name
    let vault_category = if vault_name.contains("private") { "private" }
                             else if vault_name.contains("social") { "social" }
                             else { "personal" };
    
    let batch = RecordBatch::try_new(
        schema.clone(),
        vec![
            Arc::new(arrow::array::StringArray::from(vec![doc_id.clone()])),
            Arc::new(arrow::array::StringArray::from(vec![filename])),
            Arc::new(arrow::array::BinaryArray::from(vec![crdt_doc.automerge_state.as_slice()])),
            Arc::new(arrow::array::StringArray::from(vec![Some(text_content.as_str())])),
            Arc::new(arrow::array::BinaryArray::from(vec![None as Option<&[u8]>])), // binary_content
            Arc::new(arrow::array::StringArray::from(vec!["text/plain"])),
            Arc::new(arrow::array::StringArray::from(vec![None as Option<&str>])), // vault_path
            Arc::new(arrow::array::StringArray::from(vec![device_id])),
            Arc::new(arrow::array::Int64Array::from(vec![1])), // version
            Arc::new(arrow::array::StringArray::from(vec![now.clone()])),
            Arc::new(arrow::array::StringArray::from(vec![now])),
            Arc::new(arrow::array::Int64Array::from(vec![text_content.len() as i64])),
            Arc::new(arrow::array::StringArray::from(vec![vault_category])), // 12: vault_category
            Arc::new(arrow::array::StringArray::from(vec!["pending"])), // 13: status
            Arc::new(arrow::array::FixedSizeListArray::try_new(
                Arc::new(arrow::datatypes::Field::new("item", arrow::datatypes::DataType::Float32, true)),
                 128, Arc::new(arrow::array::Float32Array::from(vec![0.0f32; 128])), None).unwrap()), // 14: vector
            Arc::new(arrow::array::StringArray::from(vec![None as Option<&str>])), // 15: content_hash
        ],
    ).map_err(|e| e.to_string())?;

    let reader = arrow::record_batch::RecordBatchIterator::new(vec![Ok(batch)], schema);
    table.add(Box::new(reader)).execute().await.map_err(|e| e.to_string())?;

    log::info!("✅ [Text] Document created in LanceDB (ID: {})", doc_id);
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
    vault_name: String,
    state: tauri::State<'_, AppState>,
    app: AppHandle,
) -> Result<(), String> {
    let device_id = device::get_or_create_device_id(&state.lancedb).await?;
    log::info!("✏️  [CRDT] Updating document '{}' in LanceDB table '{}'", id, vault_name);

    let table = state.lancedb.open_table(&vault_name).await.map_err(|e| e.to_string())?;
    let mut stream = table.query().only_if(format!("id = '{}'", id)).execute().await.map_err(|e| e.to_string())?;

    if let Some(batch_res) = stream.next().await {
        let batch = batch_res.map_err(|e| e.to_string())?;
        if batch.num_rows() == 0 { return Err("Document not found".to_string()); }
        
        let automerge_state = batch.column(2).as_any().downcast_ref::<arrow::array::BinaryArray>().unwrap().value(0).to_vec();
        let filename = batch.column(1).as_any().downcast_ref::<arrow::array::StringArray>().unwrap().value(0).to_string();
        let version = batch.column(8).as_any().downcast_ref::<arrow::array::Int64Array>().unwrap().value(0);

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

        // LanceDB update is actually a delete + insert for now (or use update API if available)
        // Let's use delete and add for safety in this version of lancedb-rs
        table.delete(format!("id = '{}'", id).as_str()).await.map_err(|e| e.to_string())?;
        
        let schema = table.schema().await.map_err(|e| e.to_string())?;
        let new_batch = RecordBatch::try_new(
            schema.clone(),
            vec![
                Arc::new(arrow::array::StringArray::from(vec![id.clone()])),
                Arc::new(arrow::array::StringArray::from(vec![batch.column(1).as_any().downcast_ref::<arrow::array::StringArray>().unwrap().value(0)])),
                Arc::new(arrow::array::BinaryArray::from(vec![new_automerge_state.as_slice()])),
                Arc::new(arrow::array::StringArray::from(vec![Some(text_content.as_str())])),
                Arc::new(arrow::array::BinaryArray::from(vec![None as Option<&[u8]>])), // binary_content
                Arc::new(arrow::array::StringArray::from(vec!["text/plain"])),
                Arc::new(arrow::array::StringArray::from(vec![None as Option<&str>])), // vault_path
                Arc::new(arrow::array::StringArray::from(vec![device_id])),
                Arc::new(arrow::array::Int64Array::from(vec![version + 1])),
                Arc::new(arrow::array::StringArray::from(vec![batch.column(9).as_any().downcast_ref::<arrow::array::StringArray>().unwrap().value(0)])),
                Arc::new(arrow::array::StringArray::from(vec![batch.column(11).as_any().downcast_ref::<arrow::array::StringArray>().unwrap().value(0)])), // updated_at
                Arc::new(arrow::array::Int64Array::from(vec![text_content.len() as i64])),
                Arc::new(arrow::array::StringArray::from(vec!["pending"])), // status
                Arc::new(arrow::array::StringArray::from(vec![batch.column(13).as_any().downcast_ref::<arrow::array::StringArray>().unwrap().value(0)])), // vault_category
                Arc::new(arrow::array::FixedSizeListArray::try_new(
                    Arc::new(arrow::datatypes::Field::new("item", arrow::datatypes::DataType::Float32, true)),
                     128, Arc::new(arrow::array::Float32Array::from(vec![0.0f32; 128])), None).unwrap()),
                Arc::new(arrow::array::StringArray::from(vec![None as Option<&str>])), // hash
            ],
        ).map_err(|e| e.to_string())?;

        let reader = arrow::record_batch::RecordBatchIterator::new(vec![Ok(new_batch)], schema);
        table.add(Box::new(reader)).execute().await.map_err(|e| e.to_string())?;

        log::info!("✅ [CRDT] Document updated in LanceDB");
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
    vault_name: String,
    state: tauri::State<'_, AppState>,
) -> Result<(), String> {
    log::info!("🗑️  Soft-deleting document {} from LanceDB table '{}'", id, vault_name);
    let table = state.lancedb.open_table(&vault_name).await.map_err(|e| e.to_string())?;
    let mut stream = table.query().only_if(format!("id = '{}'", id)).execute().await.map_err(|e| e.to_string())?;

    if let Some(batch_res) = stream.next().await {
        let batch = batch_res.map_err(|e| e.to_string())?;
        if batch.num_rows() == 0 { return Err("Document not found".to_string()); }
        
        let schema = table.schema().await.map_err(|e| e.to_string())?;
        
        // Mark as deleted for sync engine
        let mut columns = batch.columns().to_vec();
        columns[13] = Arc::new(arrow::array::StringArray::from(vec!["deleted"]));
        columns[10] = Arc::new(arrow::array::StringArray::from(vec![chrono::Utc::now().to_rfc3339()]));
        let old_ver = batch.column(8).as_any().downcast_ref::<arrow::array::Int64Array>().unwrap().value(0);
        columns[8] = Arc::new(arrow::array::Int64Array::from(vec![old_ver + 1]));

        // Delete old record and insert tombstone
        table.delete(format!("id = '{}'", id).as_str()).await.map_err(|e| e.to_string())?;
        
        let new_batch = RecordBatch::try_new(schema.clone(), columns).map_err(|e| e.to_string())?;
        let reader = arrow::record_batch::RecordBatchIterator::new(vec![Ok(new_batch)], schema);
        table.add(Box::new(reader)).execute().await.map_err(|e| e.to_string())?;
        
        log::info!("✅ Document marked as deleted (tombstone created)");
        Ok(())
    } else {
        Err("Document not found".to_string())
    }
}

// ══════════════════════════════════════════════════════════════════════════
// rename_document
// ══════════════════════════════════════════════════════════════════════════

#[tauri::command]
pub async fn rename_document(
    id: String,
    new_name: String,
    vault_name: String,
    state: tauri::State<'_, AppState>,
    app: AppHandle,
) -> Result<(), String> {
    log::info!("✏️  Renaming document {} to '{}' in LanceDB table '{}'", id, new_name, vault_name);

    let table = state.lancedb.open_table(&vault_name).await.map_err(|e| e.to_string())?;
    let mut stream = table.query().only_if(format!("id = '{}'", id)).execute().await.map_err(|e| e.to_string())?;

    if let Some(batch_res) = stream.next().await {
        let batch = batch_res.map_err(|e| e.to_string())?;
        if batch.num_rows() == 0 { return Err("Document not found".to_string()); }
        
        // LanceDB doesn't support easy column updates yet, so we delete and re-insert
        table.delete(format!("id = '{}'", id).as_str()).await.map_err(|e| e.to_string())?;
        
        let schema = table.schema().await.map_err(|e| e.to_string())?;
        let mut columns = batch.columns().to_vec();
        
        // Update filename (idx 1), updated_at (idx 10), version (idx 8), status (idx 13)
        columns[1] = Arc::new(arrow::array::StringArray::from(vec![new_name]));
        columns[10] = Arc::new(arrow::array::StringArray::from(vec![chrono::Utc::now().to_rfc3339()]));
        let old_ver = batch.column(8).as_any().downcast_ref::<arrow::array::Int64Array>().unwrap().value(0);
        columns[8] = Arc::new(arrow::array::Int64Array::from(vec![old_ver + 1]));
        columns[13] = Arc::new(arrow::array::StringArray::from(vec!["pending"]));

        let new_batch = RecordBatch::try_new(schema.clone(), columns).map_err(|e| e.to_string())?;
        let reader = arrow::record_batch::RecordBatchIterator::new(vec![Ok(new_batch)], schema);
        table.add(Box::new(reader)).execute().await.map_err(|e| e.to_string())?;

        log::info!("✅ Document renamed in LanceDB");
        tokio::spawn(async move { let _ = engine::run_sync_cycle(&app).await; });
        Ok(())
    } else {
        Err("Document not found".to_string())
    }
}

// ══════════════════════════════════════════════════════════════════════════
// get_file_bytes — decrypt a vault document and return raw bytes to the
// frontend for download (avoids needing fs:read permissions on the frontend).
// ══════════════════════════════════════════════════════════════════════════

#[tauri::command]
pub async fn get_file_bytes(
    id: String,
    vault_name: String,
    state: tauri::State<'_, AppState>,
) -> Result<Vec<u8>, String> {
    let table = state.lancedb.open_table(&vault_name).await.map_err(|e| e.to_string())?;
    let mut stream = table.query().only_if(format!("id = '{}'", id)).execute().await.map_err(|e| e.to_string())?;

    if let Some(batch_res) = stream.next().await {
        let batch = batch_res.map_err(|e| e.to_string())?;
        if batch.num_rows() == 0 { return Err("File not found".to_string()); }

        let binary_col = batch.column(4).as_any().downcast_ref::<arrow::array::BinaryArray>().unwrap();
        let path_col = batch.column(6).as_any().downcast_ref::<arrow::array::StringArray>().unwrap();

        let binary_content = if !binary_col.is_null(0) { Some(binary_col.value(0).to_vec()) } else { None };
        let vault_path_str = if !path_col.is_null(0) { Some(path_col.value(0).to_string()) } else { None };

        let vault_key_snapshot = *state.vault_key.read().await;
        if let Some(vp) = vault_path_str {
            vault::decrypt_file_any(std::path::Path::new(&vp), &vault_key_snapshot)
                .map_err(|e| format!("Decrypt failed: {}", e))
        } else if let Some(ref enc) = binary_content {
            vault_key_snapshot.decrypt(enc)
                .map_err(|e| format!("Decrypt failed: {}", e))
        } else {
            Err("No file content found".to_string())
        }
    } else {
        Err("Document not found".to_string())
    }
}

// ══════════════════════════════════════════════════════════════════════════
// open_file_for_edit
// ══════════════════════════════════════════════════════════════════════════

#[tauri::command]
pub async fn open_file_for_edit(
    id: String,
    filename: String,
    vault_name: String,
    state: tauri::State<'_, AppState>,
    app: AppHandle,
) -> Result<String, String> {
    let table = state.lancedb.open_table(&vault_name).await.map_err(|e| e.to_string())?;
    let mut stream = table.query().only_if(format!("id = '{}'", id)).execute().await.map_err(|e| e.to_string())?;

    if let Some(batch_res) = stream.next().await {
        let batch = batch_res.map_err(|e| e.to_string())?;
        if batch.num_rows() == 0 { return Err("File not found. Please sync first.".to_string()); }

        let binary_col = batch.column(4).as_any().downcast_ref::<arrow::array::BinaryArray>().unwrap();
        let path_col = batch.column(6).as_any().downcast_ref::<arrow::array::StringArray>().unwrap();

        let binary_content = if !binary_col.is_null(0) { Some(binary_col.value(0).to_vec()) } else { None };
        let vault_path_str = if !path_col.is_null(0) { Some(path_col.value(0).to_string()) } else { None };

        let vault_key_snapshot = *state.vault_key.read().await;
        // Decrypt: prefer vault file (streaming), fall back to legacy blob
        let bytes = if let Some(vp) = vault_path_str {
            vault::decrypt_file_any(std::path::Path::new(&vp), &vault_key_snapshot)
                .map_err(|e| format!("Vault decrypt failed: {}", e))?
        } else if let Some(ref enc) = binary_content {
            vault_key_snapshot.decrypt(enc)
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

        log::info!("📂 Opened for editing from LanceDB: {:?}", local_path);
        Ok(local_path.to_string_lossy().to_string())
    } else {
        Err("Document not found".to_string())
    }
}

// ══════════════════════════════════════════════════════════════════════════
// save_edited_file
// ══════════════════════════════════════════════════════════════════════════

#[tauri::command]
pub async fn save_edited_file(
    id: String,
    local_path: String,
    current_version: i64,
    vault_name: String,
    state: tauri::State<'_, AppState>,
    app: AppHandle,
) -> Result<String, String> {
    let new_bytes = fs::read(&local_path).map_err(|e| format!("Failed to read file: {}", e))?;

    let table = state.lancedb.open_table(&vault_name).await.map_err(|e| e.to_string())?;
    let mut stream = table.query().only_if(format!("id = '{}'", id)).execute().await.map_err(|e: lancedb::Error| e.to_string())?;

    if let Some(batch_res) = stream.next().await {
        let batch = batch_res.map_err(|e| e.to_string())?;
        if batch.num_rows() == 0 { return Err("Document deleted".to_string()); }

        let binary_col = batch.column(4).as_any().downcast_ref::<arrow::array::BinaryArray>().unwrap();
        let path_col = batch.column(6).as_any().downcast_ref::<arrow::array::StringArray>().unwrap();
        let version_col = batch.column(8).as_any().downcast_ref::<arrow::array::Int64Array>().unwrap();

        let binary_content_opt = if !binary_col.is_null(0) { Some(binary_col.value(0).to_vec()) } else { None };
        let server_version = version_col.value(0);
        let vault_path_opt = if !path_col.is_null(0) { Some(path_col.value(0).to_string()) } else { None };

        let vault_key_snapshot = *state.vault_key.read().await;
        // Decrypt current version for comparison
        let current_bytes = if let Some(ref vp) = vault_path_opt {
            vault::decrypt_file_any(std::path::Path::new(vp), &vault_key_snapshot)
                .map_err(|e| format!("Vault decrypt failed: {}", e))?
        } else if let Some(ref enc) = binary_content_opt {
            vault_key_snapshot.decrypt(enc)
                .map_err(|e| format!("Vault decrypt failed: {}", e))?
        } else {
            return Err("No binary content found in LanceDB".to_string());
        };

        if current_bytes == new_bytes {
            return Ok("NO_CHANGES".to_string());
        }

        if server_version != current_version {
            return handle_conflict(&state.lancedb, &id, &local_path, current_version, &vault_key_snapshot, &vault_name).await;
        }

        let new_version = current_version + 1;

        // Re-encrypt: vault file if available, otherwise blob
        if let Some(ref vp) = vault_path_opt {
            let epoch_snap = *state.epoch_key.read().await;
            match epoch_snap {
                Some(ref ek) => vault::encrypt_file_v2(
                    std::path::Path::new(&local_path),
                    std::path::Path::new(vp),
                    &vault_key_snapshot, ek, |_, _| {},
                ).map(|_| ()).map_err(|e| format!("Re-encrypt failed: {}", e))?,
                None => vault::encrypt_file(
                    std::path::Path::new(&local_path),
                    std::path::Path::new(vp),
                    &vault_key_snapshot, |_, _| {},
                ).map(|_| ()).map_err(|e| format!("Re-encrypt failed: {}", e))?,
            };
        }

        // Update in LanceDB (delete + insert)
        table.delete(format!("id = '{}' AND version = {}", id, current_version).as_str()).await.map_err(|e| e.to_string())?;
        
        let schema = table.schema().await.map_err(|e| e.to_string())?;
        let mut columns = batch.columns().to_vec();
        
        if vault_path_opt.is_none() {
            let encrypted_new = vault_key_snapshot.encrypt(&new_bytes);
            columns[4] = Arc::new(BinaryArray::from(vec![Some(encrypted_new.as_slice())]));
        }
        
        columns[8] = Arc::new(Int64Array::from(vec![new_version]));
        columns[10] = Arc::new(StringArray::from(vec![chrono::Utc::now().to_rfc3339()]));
        columns[13] = Arc::new(StringArray::from(vec!["pending"]));
        columns[11] = Arc::new(Int64Array::from(vec![new_bytes.len() as i64]));

        let new_batch = RecordBatch::try_new(schema.clone(), columns).map_err(|e| e.to_string())?;
        let reader = RecordBatchIterator::new(vec![Ok(new_batch)], schema);
        table.add(Box::new(reader)).execute().await.map_err(|e| e.to_string())?;

        log::info!("✅ [Edit] Saved version {} to LanceDB", new_version);
        tokio::spawn(async move { let _ = engine::run_sync_cycle(&app).await; });
        Ok("SUCCESS".to_string())
    } else {
        Err("Document not found".to_string())
    }
}


// ══════════════════════════════════════════════════════════════════════════
// handle_conflict
// ══════════════════════════════════════════════════════════════════════════

async fn handle_conflict(
    ldb: &crate::db::lancedb::LanceDBManager,
    original_id: &str,
    local_path: &str,
    _base_version: i64,
    vault_key: &crate::vault::VaultKey,
    vault_name: &str,
) -> Result<String, String> {
    log::warn!("⚠️ Conflict detected for {}. Creating copy in LanceDB table {}.", original_id, vault_name);

    let plaintext = fs::read(local_path).map_err(|e| e.to_string())?;
    let bytes     = vault_key.encrypt(&plaintext);

    let table = ldb.open_table(&vault_name).await.map_err(|e: anyhow::Error| e.to_string())?;
    let conflict_id = Uuid::new_v4().to_string();
    let now         = chrono::Utc::now().to_rfc3339();

    let _schema = table.schema().await.map_err(|e| e.to_string())?;
    let mut stream = table.query().only_if(format!("id = '{}'", original_id)).execute().await.map_err(|e| e.to_string())?;

    let (filename, ctype, text_content, category) = if let Some(batch_res) = stream.next().await {
        let batch = batch_res.map_err(|e: lancedb::Error| e.to_string())?;
        if batch.num_rows() > 0 {
            (
                batch.column(1).as_any().downcast_ref::<arrow::array::StringArray>().unwrap().value(0).to_string(),
                batch.column(5).as_any().downcast_ref::<arrow::array::StringArray>().unwrap().value(0).to_string(),
                if batch.column(3).is_null(0) { String::new() } else { batch.column(3).as_any().downcast_ref::<arrow::array::StringArray>().unwrap().value(0).to_string() },
                batch.column(12).as_any().downcast_ref::<arrow::array::StringArray>().unwrap().value(0).to_string(),
            )
        } else {
            ("conflict_file".to_string(), "application/octet-stream".to_string(), String::new(), "personal".to_string())
        }
    } else {
        ("conflict_file".to_string(), "application/octet-stream".to_string(), String::new(), "personal".to_string())
    };

    let schema = table.schema().await.map_err(|e| e.to_string())?;
    let batch = RecordBatch::try_new(
        schema.clone(),
        vec![
            Arc::new(StringArray::from(vec![conflict_id.clone()])),
            Arc::new(StringArray::from(vec![format!("{} (Conflict Copy)", filename)])),
            Arc::new(BinaryArray::from(vec![None as Option<&[u8]>])), // automerge
            Arc::new(StringArray::from_iter(vec![Some(text_content.as_str())])),
            Arc::new(BinaryArray::from(vec![Some(bytes.as_slice())])),
            Arc::new(StringArray::from(vec![ctype])),
            Arc::new(StringArray::from(vec![None as Option<&str>])), // vault_path
            Arc::new(StringArray::from(vec!["conflict_resolver"])),
            Arc::new(Int64Array::from(vec![1])), // version
            Arc::new(StringArray::from(vec![now.clone()])),
            Arc::new(StringArray::from(vec![now])),
            Arc::new(Int64Array::from(vec![plaintext.len() as i64])),
            Arc::new(StringArray::from(vec!["pending"])),
            Arc::new(StringArray::from(vec![category])),
            Arc::new(FixedSizeListArray::try_new(
                Arc::new(Field::new("item", DataType::Float32, true)),
                 128, Arc::new(Float32Array::from(vec![0.0f32; 128])), None).unwrap()),
            Arc::new(StringArray::from(vec![None as Option<&str>])), // hash
        ],
    ).map_err(|e| e.to_string())?;

    let reader = RecordBatchIterator::new(vec![Ok(batch)], schema);
    table.add(Box::new(reader)).execute().await.map_err(|e| e.to_string())?;

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
    let token = crate::vault::load_token_from_keyring()?.ok_or_else(|| "Not logged in".to_string())?;
    let url   = state.lancedb.get_server_url().await.map_err(|e| e.to_string())?.unwrap_or_else(|| "http://172.235.18.126:4201".to_string());

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
    _app: AppHandle,
) -> Result<PullResult, String> {
    let token = state.lancedb.get_access_token().await?;
    let url   = state.lancedb.get_server_url().await.map_err(|e| e.to_string())?.unwrap_or_else(|| "http://172.235.18.126:4201".to_string());

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

    // Default to private_vault for incoming from server if no mapping provided
    let table = state.lancedb.open_table("private_vault").await.map_err(|e| e.to_string())?;

    for doc in &changes {
        let doc_id   = doc["id"].as_str().unwrap_or("").to_string();
        let filename = doc["filename"].as_str().unwrap_or("unknown").to_string();

        let mut stream = table.query().only_if(format!("id = '{}'", doc_id)).execute().await.map_err(|e| e.to_string())?;
        let exists = if let Some(batch_res) = stream.next().await {
            batch_res.map(|b: arrow::record_batch::RecordBatch| b.num_rows() > 0).unwrap_or(false)
        } else {
            false
        };

        if exists {
            skipped += 1;
            continue;
        }

        // Download + store
        match download_and_store(&state.lancedb, doc, &token).await {
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
    _app: AppHandle,
) -> Result<String, String> {
    let token = state.lancedb.get_access_token().await?;
    let url   = state.lancedb.get_server_url().await.map_err(|e| e.to_string())?.unwrap_or_else(|| "http://172.235.18.126:4201".to_string());

    // Get presigned download URL from server
    let resp = reqwest::Client::new()
        .get(format!("{}/api/v1/sync/download/{}", url, doc_id))
        .bearer_auth(&token)
        .send()
        .await
        .map_err(|e| format!("Download request failed: {}", e))?;

    let meta: serde_json::Value = resp.json().await.map_err(|e| e.to_string())?;

    match download_and_store(&state.lancedb, &meta, &token).await {
        Ok(()) => Ok(meta["filename"].as_str().unwrap_or("file").to_string()),
        Err(e) => Err(e),
    }
}

async fn download_and_store(
    ldb: &crate::db::lancedb::LanceDBManager,
    doc: &serde_json::Value,
    _token: &str,
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

    // Pulled documents from server go into private_vault by default
    let table = ldb.open_table("private_vault").await.map_err(|e| e.to_string())?;
    
    // Check if exists to handle conflict/update
    let mut stream = table.query().only_if(format!("id = '{}'", doc_id)).execute().await.map_err(|e| e.to_string())?;
    let exists = if let Some(batch_res) = stream.next().await {
        batch_res.map(|b| b.num_rows() > 0).unwrap_or(false)
    } else {
        false
    };

    if exists {
        table.delete(format!("id = '{}'", doc_id).as_str()).await.map_err(|e| e.to_string())?;
    }

    let schema = table.schema().await.map_err(|e| e.to_string())?;
    let batch = RecordBatch::try_new(
        schema.clone(),
        vec![
            Arc::new(arrow::array::StringArray::from(vec![doc_id])),
            Arc::new(arrow::array::StringArray::from(vec![filename])),
            Arc::new(arrow::array::BinaryArray::from(vec![None as Option<&[u8]>])), // automerge
            Arc::new(arrow::array::StringArray::from(vec![None as Option<&str>])), // text
            Arc::new(arrow::array::BinaryArray::from(vec![Some(bytes.as_slice())])),
            Arc::new(arrow::array::StringArray::from(vec![content_type])),
            Arc::new(arrow::array::StringArray::from(vec![None as Option<&str>])), // vault_path
            Arc::new(arrow::array::StringArray::from(vec!["server"])),
            Arc::new(arrow::array::Int64Array::from(vec![1])), // version
            Arc::new(arrow::array::StringArray::from(vec![now.clone()])),
            Arc::new(arrow::array::StringArray::from(vec![now])),
            Arc::new(arrow::array::Int64Array::from(vec![bytes.len() as i64])),
            Arc::new(arrow::array::StringArray::from(vec!["personal"])),
            Arc::new(arrow::array::StringArray::from(vec!["synced"])),
            Arc::new(arrow::array::FixedSizeListArray::try_new(
                Arc::new(arrow::datatypes::Field::new("item", arrow::datatypes::DataType::Float32, true)),
                 128, Arc::new(arrow::array::Float32Array::from(vec![0.0f32; 128])), None).unwrap()),
            Arc::new(arrow::array::StringArray::from(vec![None as Option<&str>])), // hash
        ],
    ).map_err(|e| e.to_string())?;

    let reader = arrow::record_batch::RecordBatchIterator::new(vec![Ok(batch)], schema);
    table.add(Box::new(reader)).execute().await.map_err(|e| e.to_string())?;

    Ok(())
}

// legacy helpers removed
