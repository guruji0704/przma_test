use libsql::Connection;

pub async fn create_tables(conn: &Connection) -> Result<(), libsql::Error> {
    log::info!("🔨 Creating database tables with CRDT support...");
    
    // Documents table with CRDT support
    conn.execute(
        "CREATE TABLE IF NOT EXISTS documents (
            id TEXT PRIMARY KEY NOT NULL,
            filename TEXT NOT NULL,
            automerge_state BLOB NOT NULL,
            text_content TEXT NOT NULL DEFAULT '',
            tags TEXT DEFAULT '[]',
            device_id TEXT NOT NULL,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            last_modified_at TEXT NOT NULL DEFAULT (datetime('now')),
            last_synced_at TEXT,
            is_synced INTEGER DEFAULT 0,
            needs_upload INTEGER DEFAULT 1,
            status TEXT DEFAULT 'pending' CHECK(status IN ('pending', 'synced', 'failed'))
        )",
        (),
    ).await?;

    // Migrate existing tables that are missing new columns
    let migrations = vec![
        "ALTER TABLE documents ADD COLUMN automerge_state BLOB NOT NULL DEFAULT ''",
        "ALTER TABLE documents ADD COLUMN device_id TEXT NOT NULL DEFAULT 'unknown'",
        "ALTER TABLE documents ADD COLUMN last_modified_at TEXT NOT NULL DEFAULT (datetime('now'))",
        "ALTER TABLE documents ADD COLUMN last_synced_at TEXT",
        "ALTER TABLE documents ADD COLUMN needs_upload INTEGER DEFAULT 1",
        "ALTER TABLE documents ADD COLUMN status TEXT DEFAULT 'pending'",
    ];

    for sql in migrations {
        match conn.execute(sql, ()).await {
            Ok(_) => log::info!("  ✅ Migration applied: {}", &sql[..50]),
            Err(e) if e.to_string().contains("duplicate column") => {
                // Column already exists — skip silently
            }
            Err(e) => log::warn!("  ⚠️  Migration skipped: {}", e),
        }
    }
    
    
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_documents_status ON documents(status)",
        (),
    ).await?;
    
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_documents_needs_upload ON documents(needs_upload)",
        (),
    ).await?;
    
    log::info!("  ✅ Created table: documents");
    
    // Device identity
    conn.execute(
        "CREATE TABLE IF NOT EXISTS device_identity (
            id TEXT PRIMARY KEY DEFAULT 'singleton',
            device_id TEXT UNIQUE NOT NULL,
            device_name TEXT,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
        )",
        (),
    ).await?;
    
    log::info!("  ✅ Created table: device_identity");
    
    // Local identity
    conn.execute(
        "CREATE TABLE IF NOT EXISTS local_identity (
            id TEXT PRIMARY KEY DEFAULT 'singleton',
            did TEXT UNIQUE,
            user_id TEXT,
            username TEXT,
            email TEXT,
            server_url TEXT NOT NULL DEFAULT 'http://localhost:4000',
            access_token TEXT,
            sqld_url TEXT,
            s3_bucket TEXT,
            s3_prefix TEXT,
            last_sync_at TEXT,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at TEXT NOT NULL DEFAULT (datetime('now'))
        )",
        (),
    ).await?;
    
    log::info!("  ✅ Created table: local_identity");
    
    Ok(())
}