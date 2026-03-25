defmodule Alem.Repo.Migrations.CreateVaults do
  use Ecto.Migration

  def change do
    create table(:vaults, primary_key: false) do
      add :id,                          :binary_id, primary_key: true
      add :namespace_key,               references(:namespaces,
                                          column: :id, type: :string,
                                          on_delete: :delete_all), null: false
      add :did,                         :string, null: false
      add :sqld_url,                    :string
      add :sqld_database,               :string
      add :s3_bucket,                   :string
      add :s3_prefix,                   :string
      add :encrypted,                   :boolean, default: true
      add :encryption_key_fingerprint,  :string
      add :last_sync_at,                :utc_datetime
      add :sync_status,                 :string, default: "synced"
      add :vault_size_bytes,            :bigint, default: 0
      add :status,                      :string, default: "active"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:vaults, [:namespace_key])
    create unique_index(:vaults, [:did])
    create index(:vaults, [:status])
  end
end
