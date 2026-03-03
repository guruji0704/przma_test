use libsql::Connection;
use uuid::Uuid;

pub async fn get_or_create_device_id(conn: &Connection) -> Result<String, String> {
    let mut rows = conn
        .query("SELECT device_id FROM device_identity WHERE id = 'singleton'", ())
        .await
        .map_err(|e| e.to_string())?;
    
    if let Some(row) = rows.next().await.map_err(|e| e.to_string())? {
        if let Ok(libsql::Value::Text(device_id)) = row.get_value(0) {
            return Ok(device_id);
        }
    }
    
    let device_id = Uuid::new_v4().to_string();
    let device_name = format!("{}-{}",
        std::env::var("COMPUTERNAME")
            .or_else(|_| std::env::var("HOSTNAME"))
            .unwrap_or_else(|_| "unknown".to_string()),
        chrono::Utc::now().format("%Y%m%d")
    );
    
    // Clone values before moving them
    let device_name_clone = device_name.clone();
    
    conn.execute(
        "INSERT INTO device_identity (id, device_id, device_name) VALUES (?, ?, ?)",
        libsql::params!["singleton", device_id.clone(), device_name],
    )
    .await
    .map_err(|e| e.to_string())?;
    
    log::info!("✅ Created device ID: {} ({})", device_id, device_name_clone);
    Ok(device_id)
}