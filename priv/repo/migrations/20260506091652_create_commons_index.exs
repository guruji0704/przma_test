defmodule Alem.Repo.Migrations.CreateCommonsIndex do
  use Ecto.Migration

  @doc """
  PRZMA Commons Vault — stores ONLY references to users' public content.
  No file copies. PRZMA platform reads this for collective intelligence.
  User removes from public → removed_at set → PRZMA loses access immediately.
  """
  def change do
    create table(:commons_index, primary_key: false) do
      add :id,             :binary_id, primary_key: true
      add :content_hash,   :string, null: false
      add :document_id,    :binary_id, null: false
      add :owner_did,      :string, null: false
      add :source_ns_key,  :string, null: false  # user's public namespace key
      add :media_type,     :string
      add :media_category, :string               # images|videos|audio|documents
      add :filename,       :string
      add :indexed_at,     :utc_datetime, null: false
      add :removed_at,     :utc_datetime          # null = still in commons
    end

    create index(:commons_index, [:owner_did])
    create index(:commons_index, [:content_hash])
    create index(:commons_index, [:media_category])

    execute """
      CREATE INDEX idx_commons_active
      ON commons_index (indexed_at DESC)
      WHERE removed_at IS NULL
    """,
    "DROP INDEX IF EXISTS idx_commons_active"
  end
end
