defmodule Alem.Repo.Migrations.CreateCasDedupRefs do
  use Ecto.Migration

  def change do
    create table(:cas_dedup_refs, primary_key: false) do
      # PK = dedup_ref_id (not id)
      # SELECT r.dedup_ref_id, o.storage_key FROM cas_dedup_refs r
      # JOIN cas_objects o ON o.content_hash = r.content_hash
      add :dedup_ref_id, :binary_id, primary_key: true

      # ── Tenant context ────────────────────────────────────────────────
      add :tenant_id, :string, null: false
      add :namespace_key, references(:namespaces,
            column: :id, type: :string, on_delete: :restrict),
          null: false
      add :actor_did, :string, null: false
      add :user_id, references(:users,
            type: :string, on_delete: :restrict),
          null: false

      # ── Links — BOTH are ON DELETE RESTRICT ──────────────────────────
      # content_hash RESTRICT:
      #   Cannot delete CAS bytes while any user references them
      #   App flow when user deletes:
      #     1. SET is_active=FALSE, deactivated_at=NOW()
      #     2. DECREMENT cas_objects.ref_count
      #     3. IF ref_count=0 THEN DELETE cas_objects + S3 bytes
      add :content_hash, references(:cas_objects,
            column: :content_hash, type: :string, on_delete: :restrict),
          null: false

      # document_id RESTRICT:
      #   Must deactivate ref before deleting document
      add :document_id, references(:documents,
            type: :binary_id, on_delete: :restrict),
          null: false

      # ── Per-user private metadata ─────────────────────────────────────
      # Same S3 bytes — different names/paths/tags per user
      add :vault_path, :string
      add :user_filename, :string
      add :user_tags, {:array, :string}, default: []
      add :version_label, :string
      # v1.0|draft|final|archived

      # ── Soft-delete ───────────────────────────────────────────────────
      # Hard delete NEVER happens here — rows kept for audit trail
      add :is_active, :boolean, default: true, null: false
      add :deactivated_at, :utc_datetime
      add :deactivated_by_did, :string

      timestamps(type: :utc_datetime)
    end

    # Prevent duplicate refs
    create unique_index(:cas_dedup_refs,
      [:content_hash, :namespace_key, :document_id])

    execute """
      CREATE INDEX idx_cdr_active_ns
      ON cas_dedup_refs (namespace_key, inserted_at DESC)
      WHERE is_active = TRUE
    """,
    "DROP INDEX IF EXISTS idx_cdr_active_ns"

    execute """
      CREATE INDEX idx_cdr_active_actor
      ON cas_dedup_refs (actor_did, inserted_at DESC)
      WHERE is_active = TRUE
    """,
    "DROP INDEX IF EXISTS idx_cdr_active_actor"

    create index(:cas_dedup_refs, [:content_hash])
    create index(:cas_dedup_refs, [:namespace_key, :vault_path])

    execute """
      CREATE INDEX idx_cdr_user_tags
      ON cas_dedup_refs USING GIN (user_tags)
    """,
    "DROP INDEX IF EXISTS idx_cdr_user_tags"

    execute """
      CREATE INDEX idx_cdr_deactivated
      ON cas_dedup_refs (namespace_key, deactivated_at)
      WHERE is_active = FALSE
    """,
    "DROP INDEX IF EXISTS idx_cdr_deactivated"
  end
end
