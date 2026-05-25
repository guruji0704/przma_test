use arrow_array::{
    FixedSizeListArray, Float32Array, Int32Array,
    RecordBatch, RecordBatchIterator, StringArray,
};
use arrow_schema::{DataType, Field, Schema};
use futures::TryStreamExt;
use lancedb::connect;
use rustler::{Atom, Error as NifError, NifResult};
use std::sync::Arc;
use tokio::runtime::Runtime;

mod atoms {
    rustler::atoms! { ok, error }
}

fn runtime() -> Runtime {
    Runtime::new().expect("Failed to create Tokio runtime")
}

// ─────────────────────────────────────────
// Helper: build the schema once
// ─────────────────────────────────────────
fn make_schema() -> Arc<Schema> {
    Arc::new(Schema::new(vec![
        Field::new("id",   DataType::Int32, false),
        Field::new("name", DataType::Utf8,  false),
        Field::new(
            "vector",
            DataType::FixedSizeList(
                Arc::new(Field::new("item", DataType::Float32, true)),
                3,
            ),
            false,
        ),
    ]))
}

// ─────────────────────────────────────────
// Helper: build one RecordBatch row
// ─────────────────────────────────────────
fn make_batch(schema: Arc<Schema>, id: i32, name: &str) -> Result<RecordBatch, String> {
    let vector_data = Float32Array::from(vec![0.1_f32, 0.2, 0.3]);
    let vector_col  = FixedSizeListArray::try_new_from_values(vector_data, 3)
        .map_err(|e| e.to_string())?;

    RecordBatch::try_new(
        schema,
        vec![
            Arc::new(Int32Array::from(vec![id])),
            Arc::new(StringArray::from(vec![name])),
            Arc::new(vector_col),
        ],
    )
    .map_err(|e| e.to_string())
}

// ─────────────────────────────────────────
// NIF 1: Write a record to Linode S3
// ─────────────────────────────────────────
#[rustler::nif]
fn write_record(
    bucket:     String,   // "perkeep"
    endpoint:   String,   // "https://in-maa-1.linodeobjects.com"
    region:     String,   // "in-maa-1"
    access_key: String,
    secret_key: String,
    id:         i32,
    name:       String,
) -> NifResult<Atom> {
    // s3://perkeep/lancedb_data
    let s3_uri = format!("s3://{}/lancedb_data", bucket);

    runtime().block_on(async move {
        // Connect to LanceDB with Linode credentials passed as storage options.
        // This is how version 0.12 passes credentials — no env vars needed.
        let db = connect(&s3_uri)
            .storage_options([
                ("aws_access_key_id",     access_key.as_str()),
                ("aws_secret_access_key", secret_key.as_str()),
                ("aws_default_region",    region.as_str()),
                ("aws_endpoint",          endpoint.as_str()),
                // Tell the S3 client to allow path-style URLs
                // (required for Linode, Minio, and most non-AWS S3 providers)
                ("allow_http",            "true"),
                ("aws_virtual_hosted_style_request", "false"),
            ])
            .execute()
            .await
            .map_err(|e| NifError::Term(Box::new(e.to_string())))?;

        let schema = make_schema();
        let batch  = make_batch(schema.clone(), id, &name)
            .map_err(|e| NifError::Term(Box::new(e)))?;

        let reader = RecordBatchIterator::new(
            vec![Ok(batch)].into_iter(),
            schema.clone(),
        );

        // Try to create the table.
        // If it already exists, open it and append instead.
        match db.create_table("records", reader).execute().await {
            Ok(_) => {
                // Table created and row written — done!
            }
            Err(_) => {
                // Table already exists — open and append
                let tbl = db
                    .open_table("records")
                    .execute()
                    .await
                    .map_err(|e| NifError::Term(Box::new(e.to_string())))?;

                let batch2 = make_batch(schema.clone(), id, &name)
                    .map_err(|e| NifError::Term(Box::new(e)))?;

                tbl.add(RecordBatchIterator::new(
                    vec![Ok(batch2)].into_iter(),
                    schema,
                ))
                .execute()
                .await
                .map_err(|e| NifError::Term(Box::new(e.to_string())))?;
            }
        }

        Ok(atoms::ok())
    })
}

// ─────────────────────────────────────────
// NIF 2: Read all records from Linode S3
// ─────────────────────────────────────────
#[rustler::nif]
fn read_records(
    bucket:     String,
    endpoint:   String,
    region:     String,
    access_key: String,
    secret_key: String,
) -> NifResult<Vec<String>> {
    let s3_uri = format!("s3://{}/lancedb_data", bucket);

    runtime().block_on(async move {
        let db = connect(&s3_uri)
            .storage_options([
                ("aws_access_key_id",     access_key.as_str()),
                ("aws_secret_access_key", secret_key.as_str()),
                ("aws_default_region",    region.as_str()),
                ("aws_endpoint",          endpoint.as_str()),
                ("allow_http",            "true"),
                ("aws_virtual_hosted_style_request", "false"),
            ])
            .execute()
            .await
            .map_err(|e| NifError::Term(Box::new(e.to_string())))?;

        let table = db
            .open_table("records")
            .execute()
            .await
            .map_err(|e| NifError::Term(Box::new(e.to_string())))?;

        // SELECT * FROM records
        let stream = table
            .query()
            .execute_stream()
            .await
            .map_err(|e| NifError::Term(Box::new(e.to_string())))?;

        let batches: Vec<RecordBatch> = stream
            .try_collect()
            .await
            .map_err(|e| NifError::Term(Box::new(e.to_string())))?;

        let mut results = vec![];
        for batch in batches {
            let col = batch
                .column_by_name("name")
                .unwrap()
                .as_any()
                .downcast_ref::<StringArray>()
                .unwrap();
            for i in 0..col.len() {
                results.push(col.value(i).to_string());
            }
        }

        Ok(results)
    })
}

rustler::init!("Elixir.LancedbNif", [write_record, read_records]);