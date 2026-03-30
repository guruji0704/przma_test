// ══════════════════════════════════════════════════════════════════════════
// Arrow IPC Writer — Client-Side Columnar Analytics
//
// Converts local Document records (from libsql) into Apache Arrow IPC
// streaming format with a rich timestamp schema:
//
//   Schema
//   ──────────────────────────────────────────────────────────────────
//   doc_id          Utf8
//   filename        Utf8
//   file_size       Int64
//   content_type    Utf8
//   status          Utf8
//   is_synced       Boolean
//   needs_upload    Boolean
//   inserted_at     Timestamp(Millisecond, UTC)   ← ISO-8601 created_at
//   day             Utf8   "YYYY-MM-DD"            ← for daily partitioning
//   week            Int32  ISO week number (1-53)  ← weekly rollup
//   month           Int32  1-12                    ← monthly rollup
//   year            Int32  e.g. 2025               ← yearly rollup
//
// Flow:
//   libsql (device) ──► Arrow IPC bytes ──► server ──► Parquet (S3/MinIO)
//                                      └──► DuckDB query (direct from IPC)
//
// The IPC bytes are returned as base64 to the Tauri frontend so they can
// be sent via XRPC to the server's /api/v1/analytics/ingest endpoint.
// ══════════════════════════════════════════════════════════════════════════

use std::io::Cursor;
use std::sync::Arc;

use arrow::array::{
    ArrayRef, BooleanBuilder, Int32Builder, Int64Builder,
    StringBuilder, TimestampMillisecondBuilder,
};
use arrow::datatypes::{DataType, Field, Schema, TimeUnit};
use arrow::ipc::writer::StreamWriter;
use arrow::record_batch::RecordBatch;
use chrono::{DateTime, Datelike, Utc};

use crate::db::models::Document;

// ── Schema ────────────────────────────────────────────────────────────────

/// Build the canonical Arrow schema for Document analytics.
/// All timestamp columns are UTC. Partition columns (day/week/month/year)
/// are pre-computed so DuckDB can skip entire file groups without decoding.
pub fn document_schema() -> Schema {
    Schema::new(vec![
        Field::new("doc_id",       DataType::Utf8,                                   false),
        Field::new("filename",     DataType::Utf8,                                   false),
        Field::new("file_size",    DataType::Int64,                                  true),
        Field::new("content_type", DataType::Utf8,                                   true),
        Field::new("status",       DataType::Utf8,                                   false),
        Field::new("is_synced",    DataType::Boolean,                                false),
        Field::new("needs_upload", DataType::Boolean,                                false),
        Field::new(
            "inserted_at",
            DataType::Timestamp(TimeUnit::Millisecond, Some("UTC".into())),
            true,
        ),
        Field::new("day",   DataType::Utf8,  true),   // "YYYY-MM-DD"
        Field::new("week",  DataType::Int32, true),   // ISO week 1-53
        Field::new("month", DataType::Int32, true),   // 1-12
        Field::new("year",  DataType::Int32, true),   // e.g. 2025
    ])
}

// ── ISO-8601 timestamp → partition components ────────────────────────────

/// Parse an ISO-8601 string like "2025-11-01T14:30:00Z" and return
/// (unix_ms, day_str, iso_week, month, year).
/// Returns None on parse failure — callers store None columns as Arrow null.
fn parse_timestamp(s: &str) -> Option<(i64, String, i32, i32, i32)> {
    // Try RFC3339 / ISO-8601 with timezone first
    let dt: DateTime<Utc> = s.parse().ok()
        .or_else(|| {
            // Try "YYYY-MM-DD HH:MM:SS" (SQLite default without T/Z)
            chrono::NaiveDateTime::parse_from_str(s, "%Y-%m-%d %H:%M:%S")
                .ok()
                .map(|ndt| ndt.and_utc())
        })?;

    let unix_ms  = dt.timestamp_millis();
    let date     = dt.date_naive();
    let day_str  = date.format("%Y-%m-%d").to_string();
    let iso_week = date.iso_week().week() as i32;
    let month    = dt.month() as i32;
    let year     = dt.year();

    Some((unix_ms, day_str, iso_week, month, year))
}

// ── RecordBatch builder ───────────────────────────────────────────────────

/// Convert a slice of Documents into an Arrow RecordBatch.
///
/// All timestamp partition columns (day/week/month/year) are derived from
/// `document.created_at` at build time — DuckDB can prune on these columns
/// without decoding the timestamp column at all.
pub fn documents_to_record_batch(docs: &[Document]) -> Result<RecordBatch, arrow::error::ArrowError> {
    let schema = Arc::new(document_schema());
    let n      = docs.len();

    let mut doc_id_b       = StringBuilder::with_capacity(n, n * 36);
    let mut filename_b     = StringBuilder::with_capacity(n, n * 32);
    let mut file_size_b    = Int64Builder::with_capacity(n);
    let mut content_type_b = StringBuilder::with_capacity(n, n * 20);
    let mut status_b       = StringBuilder::with_capacity(n, n * 8);
    let mut is_synced_b    = BooleanBuilder::with_capacity(n);
    let mut needs_upload_b = BooleanBuilder::with_capacity(n);
    let mut inserted_at_b  = TimestampMillisecondBuilder::with_capacity(n)
        .with_timezone("UTC");
    let mut day_b          = StringBuilder::with_capacity(n, n * 10);
    let mut week_b         = Int32Builder::with_capacity(n);
    let mut month_b        = Int32Builder::with_capacity(n);
    let mut year_b         = Int32Builder::with_capacity(n);

    for doc in docs {
        doc_id_b.append_value(&doc.id);
        filename_b.append_value(&doc.filename);

        match doc.file_size {
            Some(s) => file_size_b.append_value(s),
            None    => file_size_b.append_null(),
        }

        match &doc.content_type {
            Some(ct) => content_type_b.append_value(ct),
            None     => content_type_b.append_null(),
        }

        status_b.append_value(&doc.status);
        is_synced_b.append_value(doc.is_synced);
        needs_upload_b.append_value(doc.needs_upload);

        // Parse created_at → timestamp + partition columns
        match parse_timestamp(&doc.created_at) {
            Some((ms, day, week, month, year)) => {
                inserted_at_b.append_value(ms);
                day_b.append_value(day);
                week_b.append_value(week);
                month_b.append_value(month);
                year_b.append_value(year);
            }
            None => {
                inserted_at_b.append_null();
                day_b.append_null();
                week_b.append_null();
                month_b.append_null();
                year_b.append_null();
            }
        }
    }

    let columns: Vec<ArrayRef> = vec![
        Arc::new(doc_id_b.finish()),
        Arc::new(filename_b.finish()),
        Arc::new(file_size_b.finish()),
        Arc::new(content_type_b.finish()),
        Arc::new(status_b.finish()),
        Arc::new(is_synced_b.finish()),
        Arc::new(needs_upload_b.finish()),
        Arc::new(inserted_at_b.finish()),
        Arc::new(day_b.finish()),
        Arc::new(week_b.finish()),
        Arc::new(month_b.finish()),
        Arc::new(year_b.finish()),
    ];

    RecordBatch::try_new(schema, columns)
}

// ── IPC serialiser ────────────────────────────────────────────────────────

/// Serialize a RecordBatch to Arrow IPC **streaming** format bytes.
///
/// The streaming format is preferred over file format because:
///   - No seek required — can be piped over HTTP/WebSocket
///   - Compatible with zero-copy memory mapping on the server
///   - Explorer.DataFrame.load_ipc/1 on the Elixir server reads this format
pub fn record_batch_to_ipc(batch: &RecordBatch) -> Result<Vec<u8>, String> {
    let mut buf    = Cursor::new(Vec::<u8>::new());
    let schema_ref = batch.schema();

    let mut writer = StreamWriter::try_new(&mut buf, &schema_ref)
        .map_err(|e| format!("IPC writer init failed: {e}"))?;

    writer.write(batch)
        .map_err(|e| format!("IPC write failed: {e}"))?;

    writer.finish()
        .map_err(|e| format!("IPC finish failed: {e}"))?;

    Ok(buf.into_inner())
}

// ── High-level entry point ────────────────────────────────────────────────

/// Full pipeline: Documents → RecordBatch → Arrow IPC bytes.
///
/// Returns raw bytes. The caller (Tauri command) base64-encodes them
/// for JSON transport to the frontend, which then forwards to the server.
pub fn documents_to_ipc_bytes(docs: &[Document]) -> Result<Vec<u8>, String> {
    let batch = documents_to_record_batch(docs)
        .map_err(|e| format!("RecordBatch build failed: {e}"))?;
    record_batch_to_ipc(&batch)
}

// ── Single-document metadata snapshot → Arrow IPC ────────────────────────
//
// Produces a ONE-ROW Arrow RecordBatch carrying document metadata only.
// Sent inside the MsgPack XRPC body as `arrow_metadata_ipc` (raw bin).
// The server writes this to Parquet on S3 for the analytics backup path:
//
//   Device  ──MsgPack──►  Server  ──Arrow→Parquet──►  S3
//   { file_content: <bin>,                             .parquet shard
//     arrow_metadata_ipc: <bin> }
//
// File bytes travel as a SEPARATE bin field — NOT embedded in Arrow columns.

/// Metadata carried per upload — all fields are string/numeric, no file bytes.
pub struct UploadMeta<'a> {
    pub doc_id:       &'a str,
    pub filename:     &'a str,
    pub content_type: &'a str,
    pub file_size:    i64,       // bytes, for the analytics column
    pub status:       &'a str,
    pub created_at:   &'a str,  // ISO-8601
}

/// Build a one-row Arrow IPC batch from document metadata.
/// Returns raw IPC bytes (streaming format) — caller puts them in MsgPack bin field.
pub fn upload_meta_to_ipc(meta: &UploadMeta<'_>) -> Result<Vec<u8>, String> {
    let schema = Arc::new(document_schema());

    let mut doc_id_b       = StringBuilder::with_capacity(1, meta.doc_id.len());
    let mut filename_b     = StringBuilder::with_capacity(1, meta.filename.len());
    let mut file_size_b    = Int64Builder::with_capacity(1);
    let mut content_type_b = StringBuilder::with_capacity(1, meta.content_type.len());
    let mut status_b       = StringBuilder::with_capacity(1, 8);
    let mut is_synced_b    = BooleanBuilder::with_capacity(1);
    let mut needs_upload_b = BooleanBuilder::with_capacity(1);
    let mut inserted_at_b  = TimestampMillisecondBuilder::with_capacity(1).with_timezone("UTC");
    let mut day_b          = StringBuilder::with_capacity(1, 10);
    let mut week_b         = Int32Builder::with_capacity(1);
    let mut month_b        = Int32Builder::with_capacity(1);
    let mut year_b         = Int32Builder::with_capacity(1);

    doc_id_b.append_value(meta.doc_id);
    filename_b.append_value(meta.filename);
    file_size_b.append_value(meta.file_size);
    content_type_b.append_value(meta.content_type);
    status_b.append_value(meta.status);
    is_synced_b.append_value(false);
    needs_upload_b.append_value(true);

    match parse_timestamp(meta.created_at) {
        Some((ms, day, week, month, year)) => {
            inserted_at_b.append_value(ms);
            day_b.append_value(day);
            week_b.append_value(week);
            month_b.append_value(month);
            year_b.append_value(year);
        }
        None => {
            inserted_at_b.append_null();
            day_b.append_null();
            week_b.append_null();
            month_b.append_null();
            year_b.append_null();
        }
    }

    let columns: Vec<ArrayRef> = vec![
        Arc::new(doc_id_b.finish()),
        Arc::new(filename_b.finish()),
        Arc::new(file_size_b.finish()),
        Arc::new(content_type_b.finish()),
        Arc::new(status_b.finish()),
        Arc::new(is_synced_b.finish()),
        Arc::new(needs_upload_b.finish()),
        Arc::new(inserted_at_b.finish()),
        Arc::new(day_b.finish()),
        Arc::new(week_b.finish()),
        Arc::new(month_b.finish()),
        Arc::new(year_b.finish()),
    ];

    let batch = RecordBatch::try_new(schema, columns)
        .map_err(|e| format!("Arrow batch build failed: {e}"))?;

    record_batch_to_ipc(&batch)
}

// ── Benchmark helper ──────────────────────────────────────────────────────

/// Stats returned by `benchmark_serialization`.
#[derive(serde::Serialize, Clone)]
pub struct SerializationStats {
    pub format:     String,
    pub records:    usize,
    pub size_bytes: usize,
    pub encode_us:  u128,
    pub decode_us:  u128,
}

/// Generate `n` synthetic Document records for benchmarking.
/// Timestamps are spread across the last 180 days.
pub fn generate_synthetic_documents(n: usize) -> Vec<Document> {
    let content_types = ["image/jpeg", "image/png", "application/pdf", "video/mp4", "text/plain"];
    let statuses      = ["pending", "synced", "failed", "uploading"];

    // 2025-09-01 00:00:00 UTC  Unix seconds
    let base_sec: i64 = 1_756_684_800;

    (1..=n).map(|i| {
        let offset_sec = ((i as i64).wrapping_mul(1_543_217)) % (180 * 86_400);
        let ts_sec     = base_sec + offset_sec;
        let dt         = DateTime::from_timestamp(ts_sec, 0)
            .unwrap_or_else(Utc::now);
        let created_at = dt.format("%Y-%m-%dT%H:%M:%SZ").to_string();

        Document {
            id:             format!("doc-{:06}", i),
            user_id:        "bench-user-001".into(),
            tenant_id:      "bench-tenant".into(),
            filename:       format!("file_{}.{}", i,
                                ["jpg","png","pdf","mp4","txt"][i % 5]),
            content_type:   Some(content_types[i % content_types.len()].into()),
            file_size:      Some(1024 * (1 + (i as i64 * 7) % 50_000)),
            content_hash:   Some(format!("sha256-bench-{:064x}", i)),
            local_path:     None,
            object_key:     None,
            text_content:   None,
            metadata:       serde_json::json!({}),
            tags:           vec![],
            status:         statuses[i % statuses.len()].into(),
            local_version:  1,
            server_version: 1,
            is_synced:      i % 4 != 0,
            needs_upload:   i % 4 == 0,
            needs_download: false,
            sync_error:     None,
            last_synced_at: Some(created_at.clone()),
            created_at:     created_at.clone(),
            updated_at:     created_at,
        }
    }).collect()
}
