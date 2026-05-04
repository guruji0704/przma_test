// ══════════════════════════════════════════════════════════════════════════
// Analytics Commands
// Phase 2: Native Arrow Pipelines — stream data directly as Arrow IPC bytes
// ══════════════════════════════════════════════════════════════════════════

use tauri::State;
use crate::AppState;
use lancedb::query::{ExecutableQuery, QueryBase};
use serde::Serialize;
use futures::StreamExt;

// ──────────────────────────────────────────────────────────────────────────
// Shared types
// ──────────────────────────────────────────────────────────────────────────

#[derive(Serialize)]
pub struct ArrowBatchResult {
    pub record_count: usize,
    pub size_bytes:   usize,
    pub ipc_base64:   String,
}

#[derive(Serialize)]
pub struct BenchmarkReport {
    pub record_count: usize,
}

// ──────────────────────────────────────────────────────────────────────────
// get_documents_arrow
// Returns all (non-deleted) documents from a vault as Arrow IPC bytes.
// Frontend can decode these natively via the Apache Arrow JS library,
// enabling zero-copy "Instant Scroll" for large lists.
// ──────────────────────────────────────────────────────────────────────────

#[tauri::command]
pub async fn get_documents_arrow(
    state: State<'_, AppState>,
    vault_name: String,
) -> Result<ArrowBatchResult, String> {
    stream_vault_to_arrow(&state, &vault_name, "status != 'deleted'", None).await
}

// ──────────────────────────────────────────────────────────────────────────
// get_documents_arrow_filtered
// Phase 2 enhancement — filter by status, content_type, or date range
// while still returning native Arrow IPC for zero-copy delivery.
// ──────────────────────────────────────────────────────────────────────────

#[tauri::command]
pub async fn get_documents_arrow_filtered(
    state: State<'_, AppState>,
    vault_name: String,
    status_filter: Option<String>,   // e.g. "pending", "synced"
    content_type_filter: Option<String>, // e.g. "image/jpeg"
    limit: Option<usize>,
) -> Result<ArrowBatchResult, String> {
    let mut conditions = vec!["status != 'deleted'".to_string()];

    if let Some(ref st) = status_filter {
        conditions.push(format!("status = '{}'", st.replace("'", "''")));
    }
    if let Some(ref ct) = content_type_filter {
        conditions.push(format!("content_type = '{}'", ct.replace("'", "''")));
    }

    let filter = conditions.join(" AND ");
    stream_vault_to_arrow(&state, &vault_name, &filter, limit).await
}

// ──────────────────────────────────────────────────────────────────────────
// get_all_vaults_arrow
// Aggregates and returns all three vault documents as a single Arrow IPC stream.
// Useful for global dashboards and cross-vault analytics.
// ──────────────────────────────────────────────────────────────────────────

#[tauri::command]
pub async fn get_all_vaults_arrow(
    state: State<'_, AppState>,
    limit: Option<usize>,
) -> Result<ArrowBatchResult, String> {
    let vaults = ["personal_vault", "private_vault", "social_vault"];
    let mut all_batches = Vec::new();
    let mut total_rows = 0usize;
    let mut schema = None;

    for vault in &vaults {
        let table = state.lancedb.open_table(vault).await.map_err(|e| e.to_string())?;
        let mut stream = table
            .query()
            .only_if("status != 'deleted'")
            .execute()
            .await
            .map_err(|e| e.to_string())?;

        while let Some(batch_res) = stream.next().await {
            let batch = batch_res.map_err(|e| e.to_string())?;
            total_rows += batch.num_rows();
            if schema.is_none() { schema = Some(batch.schema()); }
            all_batches.push(batch);

            if let Some(lim) = limit {
                if total_rows >= lim { break; }
            }
        }
    }

    if all_batches.is_empty() {
        return Ok(ArrowBatchResult { record_count: 0, size_bytes: 0, ipc_base64: String::new() });
    }

    let schema = schema.unwrap();
    let mut buffer = Vec::new();
    {
        let mut writer = arrow::ipc::writer::StreamWriter::try_new(&mut buffer, &schema)
            .map_err(|e| e.to_string())?;
        for batch in all_batches {
            writer.write(&batch).map_err(|e| e.to_string())?;
        }
        writer.finish().map_err(|e| e.to_string())?;
    }

    log::info!("📊 [Arrow] All-vaults stream: {} rows, {} bytes", total_rows, buffer.len());
    Ok(ArrowBatchResult {
        record_count: total_rows,
        size_bytes:   buffer.len(),
        ipc_base64:   base64::Engine::encode(&base64::engine::general_purpose::STANDARD, &buffer),
    })
}

// ──────────────────────────────────────────────────────────────────────────
// Internal helper — streams a vault table into Arrow IPC base64
// ──────────────────────────────────────────────────────────────────────────

async fn stream_vault_to_arrow(
    state: &State<'_, AppState>,
    vault_name: &str,
    filter: &str,
    limit: Option<usize>,
) -> Result<ArrowBatchResult, String> {
    let table = state.lancedb.open_table(vault_name).await.map_err(|e| e.to_string())?;
    let mut stream = table.query().only_if(filter).execute().await.map_err(|e| e.to_string())?;

    let mut total_rows = 0;
    let mut batches = Vec::new();

    while let Some(batch_res) = stream.next().await {
        let batch = batch_res.map_err(|e| e.to_string())?;
        total_rows += batch.num_rows();
        batches.push(batch);
        if let Some(lim) = limit {
            if total_rows >= lim { break; }
        }
    }

    if batches.is_empty() {
        return Ok(ArrowBatchResult { record_count: 0, size_bytes: 0, ipc_base64: String::new() });
    }

    let schema = batches[0].schema();
    let mut buffer = Vec::new();
    {
        let mut writer = arrow::ipc::writer::StreamWriter::try_new(&mut buffer, &schema)
            .map_err(|e| e.to_string())?;
        for batch in batches {
            writer.write(&batch).map_err(|e| e.to_string())?;
        }
        writer.finish().map_err(|e| e.to_string())?;
    }

    log::info!("📊 [Arrow] '{}' stream: {} rows, {} bytes", vault_name, total_rows, buffer.len());
    Ok(ArrowBatchResult {
        record_count: total_rows,
        size_bytes:   buffer.len(),
        ipc_base64:   base64::Engine::encode(&base64::engine::general_purpose::STANDARD, &buffer),
    })
}

// ──────────────────────────────────────────────────────────────────────────
// benchmark_serialization (placeholder)
// ──────────────────────────────────────────────────────────────────────────

#[tauri::command]
pub async fn benchmark_serialization(
    _count: Option<usize>,
) -> Result<BenchmarkReport, String> {
    log::info!("[Bench] Base benchmark placeholder");
    Ok(BenchmarkReport { record_count: 0 })
}
