#![recursion_limit = "512"]

use rustler::{Binary, Env, NewBinary, Encoder};
use tokio::runtime::Runtime;
use lancedb::query::{ExecutableQuery, QueryBase};
use arrow::ipc::reader::StreamReader;
use arrow::ipc::writer::StreamWriter;
use arrow::array::RecordBatchIterator;
use std::io::Cursor;
use futures::StreamExt;

mod atoms {
    rustler::atoms! { ok, error, not_found }
}

fn get_runtime() -> Runtime {
    Runtime::new().unwrap()
}

fn get_db_uri() -> String {
    std::env::var("LANCEDB_URI")
        .unwrap_or_else(|_| "s3://perkeep/lancedb/".to_string())
}

#[rustler::nif(schedule = "DirtyIo")]
fn append_ipc(table_name: String, ipc_data: Binary) -> rustler::Atom {
    let rt = get_runtime();
    let db_uri = get_db_uri();

    let res: Result<(), String> = rt.block_on(async {
        let conn = lancedb::connect(&db_uri)
            .execute().await
            .map_err(|e| e.to_string())?;

        let table = conn.open_table(&table_name)
            .execute().await
            .map_err(|e| e.to_string())?;

        let cursor = Cursor::new(ipc_data.as_slice());
        let reader = StreamReader::try_new(cursor, None)
            .map_err(|e| e.to_string())?;

        let schema = reader.schema();
        let batches: Vec<_> = reader
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| e.to_string())?;

        let iter = RecordBatchIterator::new(
            batches.into_iter().map(Ok),
            schema,
        );

        table.add(iter)
            .execute().await
            .map_err(|e| e.to_string())?;

        Ok(())
    });

    match res {
        Ok(_) => atoms::ok(),
        Err(_) => atoms::error(),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn query<'a>(env: Env<'a>, table_name: String, filter: String, limit: i64) -> rustler::Term<'a> {
    let rt = get_runtime();
    let db_uri = get_db_uri();

    let res: Result<Vec<u8>, String> = rt.block_on(async {
        let conn = lancedb::connect(&db_uri)
            .execute().await
            .map_err(|e| e.to_string())?;

        let table = conn.open_table(&table_name)
            .execute().await
            .map_err(|e| e.to_string())?;

        let mut q = table.query();

        if !filter.is_empty() {
            q = q.only_if(&filter);
        }

        if limit > 0 {
            q = q.limit(limit as usize);
        }

        let mut stream = q.execute().await
            .map_err(|e| e.to_string())?;

        let mut batches = Vec::new();
        while let Some(batch) = stream.next().await {
            batches.push(batch.map_err(|e| e.to_string())?);
        }

        if batches.is_empty() {
            return Ok(vec![]);
        }

        let schema = batches[0].schema();
        let mut buf = Vec::new();
        {
            let mut writer = StreamWriter::try_new(&mut buf, &schema)
                .map_err(|e| e.to_string())?;
            for batch in &batches {
                writer.write(batch).map_err(|e| e.to_string())?;
            }
            writer.finish().map_err(|e| e.to_string())?;
        }

        Ok(buf)
    });

    match res {
        Ok(data) => {
            let mut binary = NewBinary::new(env, data.len());
            binary.as_mut_slice().copy_from_slice(&data);
            let binary: Binary = binary.into();
            (atoms::ok(), binary.to_term(env)).encode(env)
        }
        Err(e) => (atoms::error(), e).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn list_tables() -> Result<Vec<String>, String> {
    let rt = get_runtime();
    let db_uri = get_db_uri();

    rt.block_on(async {
        let conn = lancedb::connect(&db_uri)
            .execute().await
            .map_err(|e| e.to_string())?;

        conn.table_names()
            .execute().await
            .map_err(|e| e.to_string())
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn delete(table_name: String, filter: String) -> rustler::Atom {
    let rt = get_runtime();
    let db_uri = get_db_uri();

    let res: Result<(), String> = rt.block_on(async {
        let conn = lancedb::connect(&db_uri)
            .execute().await
            .map_err(|e| e.to_string())?;

        let table = conn.open_table(&table_name)
            .execute().await
            .map_err(|e| e.to_string())?;

        table.delete(&filter).await
            .map_err(|e| e.to_string())
    });

    match res {
        Ok(_) => atoms::ok(),
        Err(_) => atoms::error(),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn insert_json(table_name: String, json_data: String) -> rustler::Atom {
    let rt = get_runtime();
    let db_uri = get_db_uri();

    let res: Result<(), String> = rt.block_on(async {
        let conn = lancedb::connect(&db_uri)
            .execute().await
            .map_err(|e| e.to_string())?;

        let table = conn.open_table(&table_name)
            .execute().await
            .map_err(|e| e.to_string())?;

        let schema = table.schema().await
            .map_err(|e| e.to_string())?;

        let json_value: serde_json::Value = serde_json::from_str(&json_data)
            .map_err(|e| e.to_string())?;

        let items = if json_value.is_array() {
            json_value.as_array().unwrap().clone()
        } else {
            vec![json_value]
        };

        let mut decoder = arrow_json::ReaderBuilder::new(schema.clone())
            .build_decoder()
            .map_err(|e| e.to_string())?;

        decoder.serialize(&items).map_err(|e| e.to_string())?;

        let batch = decoder.flush()
            .map_err(|e| e.to_string())?
            .ok_or_else(|| "No batch generated".to_string())?;

        let iter = RecordBatchIterator::new(
            vec![Ok(batch)].into_iter(),
            schema,
        );

        table.add(iter)
            .execute().await
            .map_err(|e| e.to_string())?;

        Ok(())
    });

    match res {
        Ok(_) => atoms::ok(),
        Err(_) => atoms::error(),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn vector_search<'a>(
    env: Env<'a>,
    table_name: String,
    query_vector: Vec<f32>,
    limit: i64
) -> rustler::Term<'a> {
    let rt = get_runtime();
    let db_uri = get_db_uri();

    let res: Result<Vec<u8>, String> = rt.block_on(async {
        let conn = lancedb::connect(&db_uri)
            .execute().await
            .map_err(|e| e.to_string())?;

        let table = conn.open_table(&table_name)
            .execute().await
            .map_err(|e| e.to_string())?;

        let mut stream = table
            .vector_search(query_vector)
            .map_err(|e| e.to_string())?
            .limit(limit as usize)
            .execute().await
            .map_err(|e| e.to_string())?;

        let mut batches = Vec::new();
        while let Some(batch) = stream.next().await {
            batches.push(batch.map_err(|e| e.to_string())?);
        }

        if batches.is_empty() { return Ok(vec![]); }

        let schema = batches[0].schema();
        let mut buf = Vec::new();
        {
            let mut writer = StreamWriter::try_new(&mut buf, &schema)
                .map_err(|e| e.to_string())?;
            for batch in &batches {
                writer.write(batch).map_err(|e| e.to_string())?;
            }
            writer.finish().map_err(|e| e.to_string())?;
        }
        Ok(buf)
    });

    match res {
        Ok(data) => {
            let mut binary = NewBinary::new(env, data.len());
            binary.as_mut_slice().copy_from_slice(&data);
            let binary: Binary = binary.into();
            (atoms::ok(), binary.to_term(env)).encode(env)
        }
        Err(e) => (atoms::error(), e).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn insert_with_vector(
    table_name: String,
    vector: Vec<f32>,
    metadata_json: String
) -> rustler::Atom {
    let rt = get_runtime();
    let db_uri = get_db_uri();

    let res: Result<(), String> = rt.block_on(async {
        use arrow::array::{Float32Array, StringArray, FixedSizeListArray, ArrayRef};
        use arrow::datatypes::{DataType, Field, Schema};
        use std::sync::Arc;

        let conn = lancedb::connect(&db_uri)
            .execute().await
            .map_err(|e| e.to_string())?;

        let meta: serde_json::Value = serde_json::from_str(&metadata_json)
            .map_err(|e| e.to_string())?;

        let id         = meta["id"].as_str().unwrap_or("").to_string();
        let verb       = meta["verb"].as_str().unwrap_or("").to_string();
        let media_type = meta["media_type"].as_str().unwrap_or("").to_string();
        let filename   = meta["filename"].as_str().unwrap_or("").to_string();
        let seven_p    = meta["seven_p_primary"].as_str().unwrap_or("").to_string();
        let preserve   = meta["preserve_primary"].as_str().unwrap_or("").to_string();
        let light      = meta["light_element"].as_str().unwrap_or("").to_string();
        let altruistic = meta["altruistic_axis"].as_str().unwrap_or("").to_string();
        let vault_tier = meta["vault_tier"].as_str().unwrap_or("").to_string();
        let user_did   = meta["user_did"].as_str().unwrap_or("").to_string();

        let dim = vector.len() as i32;

        let schema = Arc::new(Schema::new(vec![
            Field::new("id",               DataType::Utf8, false),
            Field::new("vector",           DataType::FixedSizeList(
                Arc::new(Field::new("item", DataType::Float32, true)), dim,
            ), false),
            Field::new("verb",             DataType::Utf8, true),
            Field::new("media_type",       DataType::Utf8, true),
            Field::new("filename",         DataType::Utf8, true),
            Field::new("seven_p_primary",  DataType::Utf8, true),
            Field::new("preserve_primary", DataType::Utf8, true),
            Field::new("light_element",    DataType::Utf8, true),
            Field::new("altruistic_axis",  DataType::Utf8, true),
            Field::new("vault_tier",       DataType::Utf8, true),
            Field::new("user_did",         DataType::Utf8, true),
        ]));

        let float_array  = Float32Array::from(vector);
        let vector_array = FixedSizeListArray::try_new(
            Arc::new(Field::new("item", DataType::Float32, true)),
            dim,
            Arc::new(float_array) as ArrayRef,
            None,
        ).map_err(|e| e.to_string())?;

        let columns: Vec<ArrayRef> = vec![
            Arc::new(StringArray::from(vec![id])),
            Arc::new(vector_array),
            Arc::new(StringArray::from(vec![verb])),
            Arc::new(StringArray::from(vec![media_type])),
            Arc::new(StringArray::from(vec![filename])),
            Arc::new(StringArray::from(vec![seven_p])),
            Arc::new(StringArray::from(vec![preserve])),
            Arc::new(StringArray::from(vec![light])),
            Arc::new(StringArray::from(vec![altruistic])),
            Arc::new(StringArray::from(vec![vault_tier])),
            Arc::new(StringArray::from(vec![user_did])),
        ];

        let batch = arrow::record_batch::RecordBatch::try_new(schema.clone(), columns)
            .map_err(|e| e.to_string())?;

        let iter = RecordBatchIterator::new(vec![Ok(batch)].into_iter(), schema.clone());

        match conn.open_table(&table_name).execute().await {
            Ok(table) => {
                table.add(iter).execute().await.map_err(|e| e.to_string())?;
            }
            Err(_) => {
                conn.create_table(&table_name, iter)
                    .execute().await
                    .map_err(|e| e.to_string())?;
            }
        }

        Ok(())
    });

    match res {
        Ok(_) => atoms::ok(),
        Err(_) => atoms::error(),
    }

}

#[rustler::nif(schedule = "DirtyIo")]
fn drop_table(table_name: String) -> rustler::Atom {
    let rt = get_runtime();
    let db_uri = get_db_uri();
    let res: Result<(), String> = rt.block_on(async {
        let conn = lancedb::connect(&db_uri)
            .execute().await
            .map_err(|e| e.to_string())?;
        conn.drop_table(&table_name).await
            .map_err(|e| e.to_string())
    });
    match res {
        Ok(_) => atoms::ok(),
        Err(_) => atoms::error(),
    }
}

rustler::init!("Elixir.Alem.LanceDB", [
    append_ipc,
    query,
    list_tables,
    delete,
    insert_json,
    vector_search,
    insert_with_vector,
    drop_table
]);
