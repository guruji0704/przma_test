defmodule Alem.Repo.Migrations.CreateCasDedupRefs do
  use Ecto.Migration

  def change do
    create table(:cas_dedup_refs, primary_key: false) do
      add :dedup_ref_id,       :binary_id, primary_key: true

      add :tenant_id,          :string, null: false
      add :namespace_key,      references(:namespaces, column: :id, type: :string, on_delete: :restrict), null: false
      add :actor_did,          :string, null: false
      add :user_id,            references(:users, type: :string, on_delete: :restrict), null: false

      add :content_hash,       references(:cas_objects, column: :content_hash, type: :string, on_delete: :restrict), null: false
      # add :document_id,        references(:documents, type: :string, on_delete: :restrict)
      add :document_id, references(:documents, type: :binary_id, on_delete: :restrict), null: false

      add :vault_path,         :string
      add :user_filename,      :string
      add :user_tags,          {:array, :string}, default: []
      add :version_label,      :string

      add :is_active,          :boolean, default: true, null: false
      add :deactivated_at,     :utc_datetime
      add :deactivated_by_did, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cas_dedup_refs, [:content_hash, :namespace_key, :document_id])
    create index(:cas_dedup_refs, [:content_hash])
    create index(:cas_dedup_refs, [:namespace_key, :vault_path])

    execute """
      CREATE INDEX idx_cdr_active_ns
      ON cas_dedup_refs (namespace_key, inserted_at DESC)
      WHERE is_active = TRUE
    """,
    "DROP INDEX IF EXISTS idx_cdr_active_ns"
  end
end
