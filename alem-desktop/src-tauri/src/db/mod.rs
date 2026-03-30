pub mod schema;
pub mod models;

use libsql::Database;
use std::path::Path;

pub async fn open<P: AsRef<Path>>(path: P) -> Result<Database, libsql::Error> {
    log::info!("📂 Opening database at: {:?}", path.as_ref());

    let db = libsql::Builder::new_local(path).build().await?;
    let conn = db.connect()?;

    // WAL mode: allows concurrent readers alongside one writer.
    // busy_timeout: instead of immediately returning SQLITE_BUSY when another
    // connection holds the write lock, SQLite will spin-retry for up to 5 s.
    // Both are essential when multiple Tauri commands write concurrently.
    //
    // PRAGMA journal_mode returns a result row ("wal"), so use query() + drain.
    // The other two pragmas return nothing, so execute() is fine for them.
    // All three pragmas may return a result row — use query() + drain for each.
    let mut rows = conn.query("PRAGMA journal_mode = WAL", ()).await?;
    while rows.next().await?.is_some() {}

    let mut rows = conn.query("PRAGMA busy_timeout = 5000", ()).await?;
    while rows.next().await?.is_some() {}

    let mut rows = conn.query("PRAGMA synchronous = NORMAL", ()).await?;
    while rows.next().await?.is_some() {}

    schema::create_tables(&conn).await?;

    log::info!("✅ Database initialized (WAL mode, 5 s busy timeout)");
    Ok(db)
}

pub async fn ensure_schema(db: &Database) -> Result<(), libsql::Error> {
    let conn = db.connect()?;
    schema::create_tables(&conn).await?;
    Ok(())
}

/// Use this instead of `db.connect()` everywhere in the app.
/// Ensures every connection gets busy_timeout set — without it,
/// concurrent commands immediately return SQLITE_BUSY ("database is locked")
/// instead of waiting 5 s for the write lock to clear.
pub async fn connect(db: &Database) -> Result<libsql::Connection, libsql::Error> {
    let conn = db.connect()?;
    let mut rows = conn.query("PRAGMA busy_timeout = 5000", ()).await?;
    while rows.next().await?.is_some() {}
    Ok(conn)
}