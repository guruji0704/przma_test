defmodule Alem.Repo.Migrations.CreateCasObjects do
  use Ecto.Migration

  def change do
    create table(:cas_objects, primary_key: false) do
      # PK = content_hash (TEXT) — BLAKE3 hash IS the identity
      # Never use generic "id" here — hash itself is the key
      # JOIN reads: ON o.content_hash = r.content_hash (self-documenting)
      add :content_hash, :string, primary_key: true

      # ── Tenant context — all 3 types use same columns ────────────────────
      # tenant_type = individual | family | organization lives on tenants table
      add :tenant_id, :string
      add :namespace_key, references(:namespaces,
            column: :id, type: :string, on_delete: :nilify_all),
          null: false
      add :actor_did, :string, null: false
      # NOT FK — DID may be deactivated but file must persist
      add :user_id, references(:users,
            type: :string, on_delete: :nilify_all),
          null: false

      # ── Storage ──────────────────────────────────────────────────────────
      add :storage_backend, :string, null: false, default: "s3"
      # s3 | local | turso
      add :storage_key, :string, null: false
      # S3 key: cas/a7/f8/a7f8e9d2... (2-level prefix, max 10k per prefix)
      add :media_type, :string
      add :file_size, :bigint, default: 0, null: false
      add :ref_count, :integer, default: 1, null: false
      # S3 bytes deleted ONLY when ref_count = 0

      # ── Integrity ────────────────────────────────────────────────────────
      add :is_corrupt, :boolean, default: false, null: false
      # TRUE if BLAKE3 re-verification fails -> API returns 422
      add :is_verified, :boolean, default: false, null: false
      # TRUE after first successful BLAKE3 integrity check
      add :verified_at, :utc_datetime

      # ── Content metadata ─────────────────────────────────────────────────
      add :extracted_text, :text
      # Extracted on ingest — full-text search uses this, no S3 fetch needed
      add :duration_seconds, :integer
      add :width_px, :integer
      add :height_px, :integer
      add :page_count, :integer

      # ── Effective-date — file version history ────────────────────────────
      # When user uploads new version:
      #   SET old.effective_to=NOW(), old.is_current=FALSE,
      #       old.superseded_by=new_hash, old.superseded_reason='update'
      #   INSERT new with effective_from=NOW(), is_current=TRUE
      # Query active: WHERE is_current = TRUE
      # Query history: WHERE actor_did=$did ORDER BY effective_from DESC
      add :effective_from, :utc_datetime, null: false
      add :effective_to, :utc_datetime
      # NULL = currently active version
      add :is_current, :boolean, default: true, null: false
      add :superseded_by, :string
      # Self-FK added below via execute
      add :superseded_reason, :string
      # update | replace | correction | deletion

      timestamps(type: :utc_datetime)
    end

    # ── Indexes ───────────────────────────────────────────────────────────
    create index(:cas_objects, [:namespace_key, :inserted_at])
    create index(:cas_objects, [:tenant_id])
    create index(:cas_objects, [:actor_did])
    create index(:cas_objects, [:storage_backend])
    create index(:cas_objects, [:superseded_by])

    # One active version per storage path per namespace
    execute """
      CREATE UNIQUE INDEX idx_cas_objects_current_path
      ON cas_objects (namespace_key, storage_key)
      WHERE is_current = TRUE
    """,
    "DROP INDEX IF EXISTS idx_cas_objects_current_path"

    # Nightly verification queue
    execute """
      CREATE INDEX idx_cas_objects_unverified
      ON cas_objects (inserted_at)
      WHERE is_verified = FALSE
    """,
    "DROP INDEX IF EXISTS idx_cas_objects_unverified"

    # Full-text search
    execute """
      CREATE INDEX idx_cas_objects_fts
      ON cas_objects USING GIN (to_tsvector('english', coalesce(extracted_text, '')))
    """,
    "DROP INDEX IF EXISTS idx_cas_objects_fts"

    # Self-referential FK for version chain
    execute """
      ALTER TABLE cas_objects
      ADD CONSTRAINT cas_objects_superseded_by_fkey
      FOREIGN KEY (superseded_by)
      REFERENCES cas_objects(content_hash)
      ON DELETE SET NULL
    """,
    "ALTER TABLE cas_objects DROP CONSTRAINT IF EXISTS cas_objects_superseded_by_fkey"
  end
end
