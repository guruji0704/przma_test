defmodule Alem.Repo.Migrations.CreateCasObjects do
  use Ecto.Migration

  def change do
    create table(:cas_objects, primary_key: false) do
      add :content_hash,    :string, primary_key: true
      # SHA-256 hex IS the identity — no separate id needed

      add :tenant_id,       :string
      add :namespace_key,   references(:namespaces, column: :id, type: :string, on_delete: :nilify_all)
      add :actor_did,       :string, null: false
      add :user_id,         references(:users, type: :string, on_delete: :nilify_all), null: false

      add :storage_backend, :string, null: false, default: "s3"
      add :storage_key,     :string, null: false
      add :media_type,      :string
      add :file_size,       :bigint, default: 0, null: false
      add :ref_count,       :integer, default: 1, null: false

      add :is_corrupt,      :boolean, default: false, null: false
      add :is_verified,     :boolean, default: false, null: false
      add :verified_at,     :utc_datetime

      add :extracted_text,  :text
      add :duration_seconds,:integer
      add :width_px,        :integer
      add :height_px,       :integer
      add :page_count,      :integer

      add :effective_from,  :utc_datetime, null: false
      add :effective_to,    :utc_datetime
      add :is_current,      :boolean, default: true, null: false
      add :superseded_by,   :string
      add :superseded_reason,:string

      timestamps(type: :utc_datetime)
    end

    create index(:cas_objects, [:namespace_key, :inserted_at])
    create index(:cas_objects, [:tenant_id])
    create index(:cas_objects, [:actor_did])
    create index(:cas_objects, [:storage_backend])

    execute """
      CREATE UNIQUE INDEX idx_cas_objects_current_path
      ON cas_objects (namespace_key, storage_key)
      WHERE is_current = TRUE
    """,
    "DROP INDEX IF EXISTS idx_cas_objects_current_path"

    execute """
      CREATE INDEX idx_cas_objects_fts
      ON cas_objects USING GIN (to_tsvector('english', coalesce(extracted_text, '')))
    """,
    "DROP INDEX IF EXISTS idx_cas_objects_fts"

    # Self-referential FK for version chain
    execute """
      ALTER TABLE cas_objects
      ADD CONSTRAINT cas_objects_superseded_by_fkey
      FOREIGN KEY (superseded_by) REFERENCES cas_objects(content_hash) ON DELETE SET NULL
    """,
    "ALTER TABLE cas_objects DROP CONSTRAINT IF EXISTS cas_objects_superseded_by_fkey"
  end
end
