defmodule Alem.Repo.Migrations.CreateCasDedupRefs do
  use Ecto.Migration

  def change do
    create table(:cas_dedup_refs, primary_key: false) do
      add :id,            :binary_id, primary_key: true
      add :content_hash,  references(:cas_objects,
                            column: :content_hash, type: :string,
                            on_delete: :restrict), null: false
      add :actor_did,     :string, null: false
      add :namespace_key, :string, null: false
      add :document_id,   :string, null: false
      add :vault_path,    :string
      add :user_filename, :string
      add :user_tags,     {:array, :string}, default: []

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:cas_dedup_refs, [:content_hash, :document_id])
    create index(:cas_dedup_refs, [:actor_did])
    create index(:cas_dedup_refs, [:namespace_key])
    create index(:cas_dedup_refs, [:content_hash])
  end
end
