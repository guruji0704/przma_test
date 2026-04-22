use uuid::Uuid;
use crate::db::lancedb::LanceDBManager;
use arrow::array::{RecordBatch, StringArray};
use std::sync::Arc;
use arrow::record_batch::RecordBatchIterator;
use futures::StreamExt;

pub async fn get_or_create_device_id(db: &LanceDBManager) -> Result<String, String> {
    let table = db.open_table("device_identity").await.map_err(|e| e.to_string())?;
    
    let mut stream = table.query()
        .filter("id = 'singleton'")
        .execute().await.map_err(|e| e.to_string())?;

    if let Some(batch_res) = stream.next().await {
        let batch = batch_res.map_err(|e| e.to_string())?;
        if batch.num_rows() > 0 {
            let col = batch.column(1).as_any().downcast_ref::<StringArray>()
                .ok_or_else(|| "Invalid device_identity schema".to_string())?;
            return Ok(col.value(0).to_string());
        }
    }
    
    let device_id = Uuid::new_v4().to_string();
    let device_name = format!("{}-{}",
        std::env::var("COMPUTERNAME")
            .or_else(|_| std::env::var("HOSTNAME"))
            .unwrap_or_else(|_| "unknown".to_string()),
        chrono::Utc::now().format("%Y%m%d")
    );
    
    let now = chrono::Utc::now().to_rfc3339();
    
    let schema = table.schema().await.map_err(|e| e.to_string())?;
    let batch = RecordBatch::try_new(
        schema.clone(),
        vec![
            Arc::new(StringArray::from(vec!["singleton"])),
            Arc::new(StringArray::from(vec![device_id.clone()])),
            Arc::new(StringArray::from(vec![Some(device_name.as_str())])),
            Arc::new(StringArray::from(vec![now])),
        ],
    ).map_err(|e| e.to_string())?;

    let reader = RecordBatchIterator::new(vec![Ok(batch)], schema);
    table.add(Box::new(reader)).execute().await.map_err(|e| e.to_string())?;
    
    log::info!("✅ Created device ID in LanceDB: {} ({})", device_id, device_name);
    Ok(device_id)
}