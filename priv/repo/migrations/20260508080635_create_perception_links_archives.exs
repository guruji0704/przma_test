defmodule Alem.Repo.Migrations.CreatePerceptionLinksArchives do
  use Ecto.Migration

  def change do
    # ── Perception Links (the universal share system) ─────────────────────
    create table(:perception_links, primary_key: false) do
      add :id,               :binary_id, primary_key: true
      add :link_type,        :string, null: false
      # personal | circle | forward
      add :content_hash,     :string, null: false
      # → cas_objects
      add :document_id,      :binary_id, null: false
      # → documents (owner's record)
      add :owner_did,        :string, null: false
      # ALWAYS the original uploader. NEVER changes.
      add :issuer_did,       :string, null: false
      # who created THIS specific link
      add :target_did,       :string
      # specific person (null if group)
      add :target_group_id,  :binary_id
      # specific group (null if person)
      add :conversation_id,  :binary_id
      # if shared inside a chat
      add :parent_link_id,   :binary_id
      # null=original, filled for forwards
      add :can_forward,      :boolean, default: false
      # owner decides
      add :forward_depth,    :integer, default: 0
      # 0=original, 1=one forward, max 2
      add :scope,            :string, default: "read"
      # read | annotate
      add :expires_at,       :utc_datetime, null: false
      add :revoked_at,       :utc_datetime
      add :revoked_by_did,   :string
      add :access_count,     :integer, default: 0
      add :last_accessed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:perception_links, [:owner_did])
    create index(:perception_links, [:issuer_did])
    create index(:perception_links, [:target_did])
    create index(:perception_links, [:document_id])
    create index(:perception_links, [:conversation_id])
    create index(:perception_links, [:parent_link_id])
    execute """
      CREATE INDEX idx_perception_links_active
      ON perception_links (expires_at, document_id)
      WHERE revoked_at IS NULL
    """,
    "DROP INDEX IF EXISTS idx_perception_links_active"

    # ── Archives (Delete for Me — 60 day recovery) ────────────────────────
    create table(:archives, primary_key: false) do
      add :id,              :binary_id, primary_key: true
      add :document_id,     :binary_id, null: false
      add :owner_did,       :string, null: false
      add :archived_at,     :utc_datetime, null: false
      add :expires_at,      :utc_datetime, null: false
      # archived_at + 60 days
      add :restored_at,     :utc_datetime
      # null = still archived or permanently deleted
      add :permanently_deleted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:archives, [:owner_did])
    create index(:archives, [:document_id])
    execute """
      CREATE INDEX idx_archives_active
      ON archives (expires_at)
      WHERE restored_at IS NULL AND permanently_deleted_at IS NULL
    """,
    "DROP INDEX IF EXISTS idx_archives_active"

    # ── Add soft delete fields to documents ───────────────────────────────
    alter table(:documents) do
      add_if_not_exists :deleted_for_me_at,       :utc_datetime
      add_if_not_exists :deleted_for_everyone_at,  :utc_datetime
      add_if_not_exists :is_archived,              :boolean, default: false
    end
  end
end
