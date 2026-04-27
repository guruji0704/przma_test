defmodule Alem.Repo.Migrations.CreateLanceCasTables do
  use Ecto.Migration

  def change do
    create table(:cas_global_index, primary_key: false) do
      add :cid,        :text, primary_key: true
      add :size_bytes, :bigint, null: false
      add :mime_type,  :text, default: "application/octet-stream"
      add :s3_key,     :text
      add :ref_count,  :integer, default: 0, null: false
      add :status,     :text, default: "uploading", null: false
      add :first_seen, :utc_datetime
      add :last_seen,  :utc_datetime
    end

    create index(:cas_global_index, [:status])
    create index(:cas_global_index, [:last_seen])

    create table(:cas_refs) do
      add :cid,        :text, null: false
      add :user_did,   :text, null: false
      add :vault_tier, :text, default: "private", null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:cas_refs, [:cid, :user_did])
    create index(:cas_refs, [:user_did])

    create table(:did_registry, primary_key: false) do
      add :did,             :text, primary_key: true
      add :did_document,    :map, null: false, default: %{}
      add :lance_s3_prefix, :text
      add :cas_namespace,   :text
      add :status,          :text, default: "active"
      add :created_at,      :utc_datetime
      add :updated_at,      :utc_datetime
    end

    create index(:did_registry, [:status])
  end
end
