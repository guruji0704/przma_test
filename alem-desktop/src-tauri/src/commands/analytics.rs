// ══════════════════════════════════════════════════════════════════════════
// Analytics Commands
//
// Tauri commands that expose Arrow IPC serialization to the frontend:
//
//   get_documents_arrow      → query local DB → Arrow IPC (base64)
//   benchmark_serialization  → 1000 synthetic records → JSON vs Arrow stats
// ══════════════════════════════════════════════════════════════════════════

use std::time::Instant;

use arrow::array::{Array, Int32Array};
use base64::Engine as _;
use tauri::State;

use crate::AppState;
use crate::arrow as arrow_writer;
use crate::db::models::row_to_document;

// ── get_documents_arrow ───────────────────────────────────────────────────

/// Query all documents from the local libsql database and return them
/// serialized as Arrow IPC streaming format, base64-encoded.
///
/// The frontend can POST this directly to /api/v1/analytics/ingest.
/// The server (Elixir) calls Explorer.DataFrame.load_ipc/1 on the bytes
/// and converts to Parquet for S3 cold storage.
///
/// Arrow schema (see arrow/mod.rs):
///   doc_id, filename, file_size, content_type, status,
///   is_synced, needs_upload,
///   inserted_at (Timestamp ms UTC),
///   day (YYYY-MM-DD), week (1-53), month (1-12), year
#[tauri::command]
pub async fn get_documents_arrow(
    state: State<'_, AppState>,
) -> Result<ArrowBatchResult, String> {
    let conn = crate::db::connect(&state.db).await.map_err(|e| e.to_string())?;

    let mut rows = conn
        .query(
            "SELECT
                id,
                '' AS user_id,
                '' AS tenant_id,
                filename,
                content_type,
                file_size,
                NULL AS content_hash,
                vault_path AS local_path,
                NULL AS object_key,
                text_content,
                '{}' AS metadata,
                tags,
                status,
                version AS local_version,
                1 AS server_version,
                is_synced,
                needs_upload,
                0 AS needs_download,
                NULL AS sync_error,
                last_synced_at,
                created_at,
                updated_at
             FROM documents
             ORDER BY created_at DESC",
            (),
        )
        .await
        .map_err(|e| e.to_string())?;

    let mut docs = Vec::new();
    while let Some(row) = rows.next().await.map_err(|e| e.to_string())? {
        match row_to_document(&row) {
            Ok(d)  => docs.push(d),
            Err(e) => log::warn!("[Arrow] Row parse error: {}", e),
        }
    }

    let record_count = docs.len();
    let ipc_bytes    = arrow_writer::documents_to_ipc_bytes(&docs)?;
    let size_bytes   = ipc_bytes.len();
    let encoded      = base64::engine::general_purpose::STANDARD.encode(&ipc_bytes);

    log::info!(
        "[Arrow] Serialized {} documents → {} bytes IPC",
        record_count, size_bytes
    );

    Ok(ArrowBatchResult {
        record_count,
        size_bytes,
        ipc_base64: encoded,
    })
}

/// Result returned to the frontend after Arrow IPC serialization.
#[derive(serde::Serialize)]
pub struct ArrowBatchResult {
    pub record_count: usize,
    pub size_bytes:   usize,
    /// Arrow IPC streaming bytes, base64-encoded for JSON transport.
    /// POST this to /api/v1/analytics/ingest with Content-Type: application/json.
    pub ipc_base64:   String,
}

// ── benchmark_serialization ───────────────────────────────────────────────

/// Generate `count` synthetic Document records and measure serialization
/// performance across three formats:
///
///   1. JSON (serde_json)          — baseline, human-readable
///   2. MessagePack (rmp-serde)    — binary XRPC wire format
///   3. Arrow IPC (arrow crate)    — columnar, with timestamp partitions
///
/// Returns a comparison table with size (bytes), encode time (µs),
/// and what each format is best suited for in the PRZMA architecture.
///
/// Run from the frontend devtools:
///   await invoke('benchmark_serialization', { count: 1000 })
#[tauri::command]
pub async fn benchmark_serialization(
    count: Option<usize>,
) -> Result<BenchmarkReport, String> {
    let n = count.unwrap_or(1_000);
    log::info!("[Bench] Generating {} synthetic documents...", n);

    // ── Generate synthetic data ──────────────────────────────────────────
    let docs = arrow_writer::generate_synthetic_documents(n);

    // ── 1. JSON ──────────────────────────────────────────────────────────
    let t0      = Instant::now();
    let json_bytes = serde_json::to_vec(&docs)
        .map_err(|e| format!("JSON encode: {e}"))?;
    let json_encode_us = t0.elapsed().as_micros();

    let t1 = Instant::now();
    let _: Vec<crate::db::models::Document> = serde_json::from_slice(&json_bytes)
        .map_err(|e| format!("JSON decode: {e}"))?;
    let json_decode_us = t1.elapsed().as_micros();

    // ── 2. MessagePack ───────────────────────────────────────────────────
    let t2 = Instant::now();
    let msgpack_bytes = rmp_serde::to_vec_named(&docs)
        .map_err(|e| format!("MsgPack encode: {e}"))?;
    let msgpack_encode_us = t2.elapsed().as_micros();

    let t3 = Instant::now();
    let _: Vec<crate::db::models::Document> = rmp_serde::from_slice(&msgpack_bytes)
        .map_err(|e| format!("MsgPack decode: {e}"))?;
    let msgpack_decode_us = t3.elapsed().as_micros();

    // ── 3. Arrow IPC ─────────────────────────────────────────────────────
    let t4 = Instant::now();
    let arrow_bytes = arrow_writer::documents_to_ipc_bytes(&docs)?;
    let arrow_encode_us = t4.elapsed().as_micros();

    // Decode Arrow IPC back to RecordBatch and time it
    let t5    = Instant::now();
    let batch = decode_ipc_bytes(&arrow_bytes)?;
    let arrow_decode_us = t5.elapsed().as_micros();

    // ── 4. Timestamp partition query on Arrow RecordBatch ─────────────────
    // Columnar scan: only the target column bytes are touched.
    // This is what makes Arrow so much faster than JSON/MsgPack map iteration.

    // year == 2025
    let t6 = Instant::now();
    let year_arr = batch
        .column_by_name("year")
        .and_then(|c| c.as_any().downcast_ref::<Int32Array>())
        .ok_or("year column missing or wrong type")?;
    let _year_count: usize = (0..year_arr.len())
        .filter(|&i| !year_arr.is_null(i) && year_arr.value(i) == 2025)
        .count();
    let arrow_query_year_us = t6.elapsed().as_micros();

    // month == 11
    let t7 = Instant::now();
    let month_arr = batch
        .column_by_name("month")
        .and_then(|c| c.as_any().downcast_ref::<Int32Array>())
        .ok_or("month column missing")?;
    let _month_count: usize = (0..month_arr.len())
        .filter(|&i| !month_arr.is_null(i) && month_arr.value(i) == 11)
        .count();
    let arrow_query_month_us = t7.elapsed().as_micros();

    // week == 45
    let t8 = Instant::now();
    let week_arr = batch
        .column_by_name("week")
        .and_then(|c| c.as_any().downcast_ref::<Int32Array>())
        .ok_or("week column missing")?;
    let _week_count: usize = (0..week_arr.len())
        .filter(|&i| !week_arr.is_null(i) && week_arr.value(i) == 45)
        .count();
    let arrow_query_week_us = t8.elapsed().as_micros();

    // ── Compute ratios ────────────────────────────────────────────────────
    let json_kb    = json_bytes.len()    as f64 / 1024.0;
    let msgpack_kb = msgpack_bytes.len() as f64 / 1024.0;
    let arrow_kb   = arrow_bytes.len()   as f64 / 1024.0;

    log::info!(
        "[Bench] n={} | JSON={:.1}KB | MsgPack={:.1}KB ({:.1}x) | Arrow={:.1}KB ({:.1}x)",
        n,
        json_kb,
        msgpack_kb, json_kb / msgpack_kb,
        arrow_kb,   json_kb / arrow_kb
    );

    Ok(BenchmarkReport {
        record_count: n,

        json: FormatStats {
            format:     "JSON".into(),
            size_bytes: json_bytes.len(),
            encode_us:  json_encode_us,
            decode_us:  json_decode_us,
            note: "Baseline — human-readable. Used only for ActivityPub federation.".into(),
        },

        msgpack: FormatStats {
            format:     "MessagePack".into(),
            size_bytes: msgpack_bytes.len(),
            encode_us:  msgpack_encode_us,
            decode_us:  msgpack_decode_us,
            note: "Best for XRPC wire (device ↔ server). ~50% smaller than JSON.".into(),
        },

        arrow: ArrowStats {
            format:     "Arrow IPC".into(),
            size_bytes: arrow_bytes.len(),
            encode_us:  arrow_encode_us,
            decode_us:  arrow_decode_us,
            query_year_us:  arrow_query_year_us,
            query_month_us: arrow_query_month_us,
            query_week_us:  arrow_query_week_us,
            note: "Client analytics + server streaming. Zero-copy columnar queries. \
                   Timestamp partitioned: day/week/month/year. \
                   Sent to server → converted to Parquet for S3 cold storage.".into(),
        },

        compression: CompressionRatios {
            msgpack_vs_json: round2(json_bytes.len() as f64 / msgpack_bytes.len() as f64),
            arrow_vs_json:   round2(json_bytes.len() as f64 / arrow_bytes.len() as f64),
            arrow_vs_msgpack: round2(msgpack_bytes.len() as f64 / arrow_bytes.len() as f64),
        },
    })
}

// ── helpers ───────────────────────────────────────────────────────────────

fn decode_ipc_bytes(bytes: &[u8]) -> Result<arrow::record_batch::RecordBatch, String> {
    use arrow::ipc::reader::StreamReader;
    use std::io::Cursor;

    let cursor = Cursor::new(bytes);
    let mut reader = StreamReader::try_new(cursor, None)
        .map_err(|e| format!("IPC reader init: {e}"))?;

    reader.next()
        .ok_or_else(|| "Empty IPC stream — no batches".to_string())?
        .map_err(|e| format!("IPC read batch: {e}"))
}

fn round2(v: f64) -> f64 {
    (v * 100.0).round() / 100.0
}

// ── Result types ──────────────────────────────────────────────────────────

#[derive(serde::Serialize)]
pub struct BenchmarkReport {
    pub record_count: usize,
    pub json:         FormatStats,
    pub msgpack:      FormatStats,
    pub arrow:        ArrowStats,
    pub compression:  CompressionRatios,
}

#[derive(serde::Serialize)]
pub struct FormatStats {
    pub format:     String,
    pub size_bytes: usize,
    pub encode_us:  u128,
    pub decode_us:  u128,
    pub note:       String,
}

#[derive(serde::Serialize)]
pub struct ArrowStats {
    pub format:          String,
    pub size_bytes:      usize,
    pub encode_us:       u128,
    pub decode_us:       u128,
    pub query_year_us:   u128,
    pub query_month_us:  u128,
    pub query_week_us:   u128,
    pub note:            String,
}

#[derive(serde::Serialize)]
pub struct CompressionRatios {
    /// How many times smaller MessagePack is vs JSON
    pub msgpack_vs_json:   f64,
    /// How many times smaller Arrow IPC is vs JSON
    pub arrow_vs_json:     f64,
    /// How many times smaller Arrow IPC is vs MessagePack
    pub arrow_vs_msgpack:  f64,
}
