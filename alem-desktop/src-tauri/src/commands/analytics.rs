// ══════════════════════════════════════════════════════════════════════════
// Analytics Commands
// ══════════════════════════════════════════════════════════════════════════

use tauri::State;
use crate::AppState;

#[tauri::command]
pub async fn get_documents_arrow(
    _state: State<'_, AppState>,
) -> Result<ArrowBatchResult, String> {
    log::info!("[Analytics] Placeholder for Arrow IPC export (migrations in progress)");
    Ok(ArrowBatchResult {
        record_count: 0,
        size_bytes:   0,
        ipc_base64:   String::new(),
    })
}

#[derive(serde::Serialize)]
pub struct ArrowBatchResult {
    pub record_count: usize,
    pub size_bytes:   usize,
    pub ipc_base64:   String,
}

#[derive(serde::Serialize)]
pub struct BenchmarkReport {
    pub record_count: usize,
}

#[tauri::command]
pub async fn benchmark_serialization(
    _count: Option<usize>,
) -> Result<BenchmarkReport, String> {
    log::info!("[Bench] Base benchmark placeholder");
    Ok(BenchmarkReport { record_count: 0 })
}
