-- Documents table
-- Metadata + CRDT stored in SQLd
-- Actual file content stored in S3 (referenced by s3_content_key)
CREATE TABLE IF NOT EXISTS documents (
    id TEXT PRIMARY KEY NOT NULL,
    user_id TEXT NOT NULL,
    filename TEXT NOT NULL,
    device_id TEXT NOT NULL,
    last_modified_at TEXT NOT NULL,
    
    -- ✅ CRDT State stored directly in DB (Binary Large Object)
    automerge_state BLOB,
    
    -- ✅ S3 Pointer: Only points to the actual file content
    s3_content_key TEXT,
    
    -- File info
    file_size INTEGER DEFAULT 0,
    
    -- Status
    status TEXT DEFAULT 'synced' CHECK(status IN ('synced', 'pending', 'failed')),
    
    -- Timestamps
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_documents_user_id ON documents(user_id);
CREATE INDEX IF NOT EXISTS idx_documents_updated_at ON documents(updated_at);
CREATE INDEX IF NOT EXISTS idx_documents_device_id ON documents(device_id);