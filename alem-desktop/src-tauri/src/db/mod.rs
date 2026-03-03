pub mod schema;

use libsql::Database;
use std::path::Path;

pub async fn open<P: AsRef<Path>>(path: P) -> Result<Database, libsql::Error> {
    log::info!("📂 Opening database at: {:?}", path.as_ref());
    
    let db = libsql::Builder::new_local(path).build().await?;
    let conn = db.connect()?;
    
    // Create tables directly (no migrations needed for now)
    schema::create_tables(&conn).await?;
    
    log::info!("✅ Database initialized successfully");
    Ok(db)
}

pub async fn ensure_schema(db: &Database) -> Result<(), libsql::Error> {
    let conn = db.connect()?;
    schema::create_tables(&conn).await?;
    Ok(())
}