use libsql::Connection;

pub async fn create_tables(conn: &Connection) -> Result<(), libsql::Error> {
    log::info!("🔨 Creating database tables...");

    // ── Documents ────────────────────────────────────────────────────────
    conn.execute(
        "CREATE TABLE IF NOT EXISTS documents (
            id                TEXT PRIMARY KEY NOT NULL,
            filename          TEXT NOT NULL,
            automerge_state   BLOB NOT NULL DEFAULT '',
            text_content      TEXT NOT NULL DEFAULT '',
            binary_content    BLOB,
            content_type      TEXT NOT NULL DEFAULT 'text/plain',
            tags              TEXT DEFAULT '[]',
            vault_path        TEXT,
            device_id         TEXT NOT NULL DEFAULT 'unknown',
            version           INTEGER NOT NULL DEFAULT 1,
            conflict_copy_of  TEXT,
            created_at        TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at        TEXT NOT NULL DEFAULT (datetime('now')),
            last_modified_at  TEXT NOT NULL DEFAULT (datetime('now')),
            last_synced_at    TEXT,
            is_synced         INTEGER DEFAULT 0,
            needs_upload      INTEGER DEFAULT 1,
            status            TEXT DEFAULT 'pending' CHECK(status IN ('pending', 'synced', 'failed'))
        )",
        (),
    ).await?;

    // ── Schema migrations (add missing columns to existing tables) ────────
    let schema_migrations = vec![
        "ALTER TABLE documents ADD COLUMN binary_content BLOB",
        "ALTER TABLE documents ADD COLUMN content_type TEXT NOT NULL DEFAULT 'text/plain'",
        "ALTER TABLE documents ADD COLUMN version INTEGER NOT NULL DEFAULT 1",
        "ALTER TABLE documents ADD COLUMN conflict_copy_of TEXT",
        "ALTER TABLE documents ADD COLUMN automerge_state BLOB NOT NULL DEFAULT ''",
        "ALTER TABLE documents ADD COLUMN device_id TEXT NOT NULL DEFAULT 'unknown'",
        "ALTER TABLE documents ADD COLUMN last_modified_at TEXT NOT NULL DEFAULT (datetime('now'))",
        "ALTER TABLE documents ADD COLUMN last_synced_at TEXT",
        "ALTER TABLE documents ADD COLUMN needs_upload INTEGER DEFAULT 1",
        "ALTER TABLE documents ADD COLUMN status TEXT DEFAULT 'pending'",
        "ALTER TABLE documents ADD COLUMN updated_at TEXT NOT NULL DEFAULT (datetime('now'))",
        "ALTER TABLE documents ADD COLUMN tags TEXT DEFAULT '[]'",
        "ALTER TABLE documents ADD COLUMN vault_path TEXT",
    ];

    for sql in schema_migrations {
        match conn.execute(sql, ()).await {
            Ok(_) => log::info!("  ✅ Schema migration: {}", &sql[..60.min(sql.len())]),
            Err(e) if e.to_string().contains("duplicate column") => {
                // Column already exists — skip silently
            }
            Err(e) => log::warn!("  ⚠️  Schema migration skipped: {}", e),
        }
    }

    // ── Data migrations (fix bad data in existing rows) ───────────────────
    // Fix empty content_type — old rows created before the column existed
    let data_migrations = vec![
        "UPDATE documents SET content_type = 'text/plain' WHERE content_type IS NULL OR content_type = ''",
        "UPDATE documents SET version = 1 WHERE version IS NULL OR version = 0",
        "UPDATE documents SET text_content = '' WHERE text_content IS NULL",
        "UPDATE documents SET needs_upload = 1 WHERE needs_upload IS NULL",
        "UPDATE documents SET is_synced = 0 WHERE is_synced IS NULL",
        "UPDATE documents SET status = 'pending' WHERE status IS NULL OR status = ''",
        "UPDATE documents SET updated_at = created_at WHERE updated_at IS NULL OR updated_at = ''",
        "UPDATE documents SET last_modified_at = created_at WHERE last_modified_at IS NULL OR last_modified_at = ''",
    ];

    for sql in data_migrations {
        match conn.execute(sql, ()).await {
            Ok(_) => log::info!("  ✅ Data migration: {}", &sql[..60.min(sql.len())]),
            Err(e) => log::warn!("  ⚠️  Data migration skipped: {}", e),
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

    log::info!("  ✅ documents table ready");

    // ── file_chunks (chunked upload assembly) ────────────────────────────
    conn.execute(
        "CREATE TABLE IF NOT EXISTS file_chunks (
            id           TEXT PRIMARY KEY NOT NULL,
            doc_id       TEXT NOT NULL,
            chunk_index  INTEGER NOT NULL,
            total_chunks INTEGER NOT NULL,
            data         BLOB NOT NULL,
            created_at   TEXT NOT NULL DEFAULT (datetime('now')),
            UNIQUE(doc_id, chunk_index)
        )",
        (),
    ).await?;

    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_file_chunks_doc_id ON file_chunks(doc_id)",
        (),
    ).await?;

    log::info!("  ✅ file_chunks table ready");

    // ── device_identity ──────────────────────────────────────────────────
    conn.execute(
        "CREATE TABLE IF NOT EXISTS device_identity (
            id          TEXT PRIMARY KEY DEFAULT 'singleton',
            device_id   TEXT UNIQUE NOT NULL,
            device_name TEXT,
            created_at  TEXT NOT NULL DEFAULT (datetime('now'))
        )",
        (),
    ).await?;

    log::info!("  ✅ device_identity table ready");

    // ── local_identity ───────────────────────────────────────────────────
    conn.execute(
        "CREATE TABLE IF NOT EXISTS local_identity (
            id           TEXT PRIMARY KEY DEFAULT 'singleton',
            did          TEXT UNIQUE,
            user_id      TEXT,
            username     TEXT,
            email        TEXT,
            server_url   TEXT NOT NULL DEFAULT 'http://localhost:4000',
            access_token TEXT,
            sqld_url     TEXT,
            s3_bucket    TEXT,
            s3_prefix    TEXT,
            last_sync_at TEXT,
            vault_key    TEXT,
            created_at   TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at   TEXT NOT NULL DEFAULT (datetime('now'))
        )",
        (),
    ).await?;

    // Add vault_key column if it doesn't exist (existing installs)
    match conn.execute(
        "ALTER TABLE local_identity ADD COLUMN vault_key TEXT",
        (),
    ).await {
        Ok(_) => log::info!("  ✅ Schema migration: vault_key column added to local_identity"),
        Err(e) if e.to_string().contains("duplicate column") => {}
        Err(e) => log::warn!("  ⚠️  vault_key migration skipped: {}", e),
    }

    // Add key_salt column for future Argon2 password-based key derivation
    // Stores the 32-byte salt (base64-encoded) alongside the derived key
    match conn.execute(
        "ALTER TABLE local_identity ADD COLUMN key_salt TEXT",
        (),
    ).await {
        Ok(_) => log::info!("  ✅ Schema migration: key_salt column added to local_identity"),
        Err(e) if e.to_string().contains("duplicate column") => {}
        Err(e) => log::warn!("  ⚠️  key_salt migration skipped: {}", e),
    }

    log::info!("  ✅ local_identity table ready");

    Ok(())
}