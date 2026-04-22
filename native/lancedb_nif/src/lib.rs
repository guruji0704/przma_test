use rustler::{Atom, Binary, Env, ResourceArc, Term};
use std::sync::Arc;
use tokio::runtime::Runtime;
use lancedb::connection::Connection;
use lancedb::query::{Executable, Query};
use arrow::ipc::reader::StreamReader;
use arrow::record_batch::RecordBatch;
use std::io::Cursor;
use futures::StreamExt;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        not_found
    }
}

pub struct LanceDBResource {
    pub db_path: String,
    pub runtime: Runtime,
}

#[rustler::nif]
fn append_ipc(table_name: String, ipc_data: Binary) -> rustler::Atom {
    let rt = Runtime::new().unwrap();
    let db_uri = std::env::var("LANCEDB_URI").unwrap_or_else(|_| ".lancedb".to_string());
    
    let res: Result<(), String> = rt.block_on(async {
        let conn = lancedb::connect(&db_uri).execute().await.map_err(|e| e.to_string())?;
        let table = conn.open_table(&table_name).execute().await.map_err(|e| e.to_string())?;
        
        let cursor = Cursor::new(ipc_data.as_slice());
        let reader = StreamReader::try_new(cursor, None).map_err(|e| e.to_string())?;
        
        let mut batches = Vec::new();
        for batch in reader {
            batches.push(batch.map_err(|e| e.to_string())?);
        }
        
        table.add(batches).execute().await.map_err(|e| e.to_string())?;
        Ok(())
    });

    match res {
        Ok(_) => atoms::ok(),
        Err(_) => atoms::error(),
    }
}

#[rustler::nif]
fn query(table_name: String, filter: String, limit: i64) -> String {
    let rt = Runtime::new().unwrap();
    let db_uri = std::env::var("LANCEDB_URI").unwrap_or_else(|_| ".lancedb".to_string());
    
    let res: Result<String, String> = rt.block_on(async {
        let conn = lancedb::connect(&db_uri).execute().await.map_err(|e| e.to_string())?;
        let table = conn.open_table(&table_name).execute().await.map_err(|e| e.to_string())?;
        
        let mut query = table.query();
        if !filter.is_empty() {
            query = query.filter(filter);
        }
        if limit > 0 {
            query = query.limit(limit as usize);
        }
        
        let mut stream = query.execute().await.map_err(|e| e.to_string())?;
        let mut all_rows = Vec::new();
        
        while let Some(batch_res) = stream.next().await {
            let batch = batch_res.map_err(|e| e.to_string())?;
            // For now, convert to JSON for simplicity in the NIF
            // In a better version, we'd return Arrow IPC bytes
            let json_rows = arrow_json::writer::record_batches_to_json_rows(&[batch]).map_err(|e| e.to_string())?;
            all_rows.extend(json_rows);
        }
        
        serde_json::to_string(&all_rows).map_err(|e| e.to_string())
    });

    res.unwrap_or_else(|e| format!("{{\"error\": \"{}\"}}", e))
}

#[rustler::nif]
fn list_tables() -> Vec<String> {
    let rt = Runtime::new().unwrap();
    let db_uri = std::env::var("LANCEDB_URI").unwrap_or_else(|_| ".lancedb".to_string());
    
    rt.block_on(async {
        let conn = lancedb::connect(&db_uri).execute().await.unwrap();
        conn.table_names().execute().await.unwrap()
    })
}

#[rustler::nif]
fn delete(table_name: String, filter: String) -> rustler::Atom {
    let rt = Runtime::new().unwrap();
    let db_uri = std::env::var("LANCEDB_URI").unwrap_or_else(|_| ".lancedb".to_string());
    
    let res: Result<(), String> = rt.block_on(async {
        let conn = lancedb::connect(&db_uri).execute().await.map_err(|e| e.to_string())?;
        let table = conn.open_table(&table_name).execute().await.map_err(|e| e.to_string())?;
        
        table.delete(&filter).await.map_err(|e| e.to_string())?;
        Ok(())
    });

    match res {
        Ok(_) => atoms::ok(),
        Err(_) => atoms::error(),
    }
}

#[rustler::nif]
fn insert_json(table_name: String, json_data: String) -> rustler::Atom {
    let rt = Runtime::new().unwrap();
    let db_uri = std::env::var("LANCEDB_URI").unwrap_or_else(|_| ".lancedb".to_string());
    
    let res: Result<(), String> = rt.block_on(async {
        let conn = lancedb::connect(&db_uri).execute().await.map_err(|e| e.to_string())?;
        let table = conn.open_table(&table_name).execute().await.map_err(|e| e.to_string())?;
        
        // Parse JSON to RecordBatch
        let json_value: serde_json::Value = serde_json::from_str(&json_data).map_err(|e| e.to_string())?;
        let items = if json_value.is_array() {
            json_value.as_array().unwrap().clone()
        } else {
            vec![json_value]
        };
        
        // This is a simplification. Usually we'd use the table's schema.
        // For epoch keys, we'll assume the JSON matches the schema.
        let schema = table.schema().await.map_err(|e| e.to_string())?;
        let mut decoder = arrow_json::ReaderBuilder::new(schema).build_decoder().map_err(|e| e.to_string())?;
        decoder.serialize(&items).map_err(|e| e.to_string())?;
        let batch = decoder.flush().map_err(|e| e.to_string())?.ok_or_else(|| "No batch generated".to_string())?;

        table.add(vec![batch]).execute().await.map_err(|e| e.to_string())?;
        Ok(())
    });

    match res {
        Ok(_) => atoms::ok(),
        Err(_) => atoms::error(),
    }
}

rustler::init!("Elixir.Alem.LanceDB", [append_ipc, query, list_tables, delete, insert_json]);
