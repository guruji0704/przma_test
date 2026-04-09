defmodule Alem.LocalFirst.LibSQLRepo.Migrations.CreateLocalFirstTables do
  use Ecto.Migration

  def change do
    create table(:local_users, primary_key: false) do
      add :id, :string, primary_key: true
      add :tenant_id, :string, null: false, default: "default"
      add :username, :string
      add :display_name, :string
      add :email, :string
      add :avatar_url, :string
      add :oauth_token, :string
      add :oauth_refresh_token, :string
      add :oauth_expires_at, :utc_datetime
      add :pleroma_account_id, :string
      add :did, :string
      add :did_keypair, :map
      add :identity_type, :string, default: "hybrid"
      add :last_sync_at, :utc_datetime
      add :sync_token, :string
      add :is_online, :boolean, default: false
      add :settings, :map, default: %{}
      add :status, :string, default: "active"
      timestamps(type: :utc_datetime)
    end

    create unique_index(:local_users, [:pleroma_account_id],
             where: "pleroma_account_id IS NOT NULL"
           )
    create unique_index(:local_users, [:did], where: "did IS NOT NULL")

    create table(:local_documents, primary_key: false) do
      add :id, :string, primary_key: true
      add :user_id, :string, null: false
      add :tenant_id, :string, null: false, default: "default"
      add :filename, :string, null: false
      add :content_type, :string
      add :file_size, :integer
      add :content_hash, :string
      add :local_path, :string
      add :is_cached_locally, :boolean, default: false
      add :local_version, :integer, default: 1
      add :object_key, :string
      add :server_version, :integer, default: 1
      add :is_synced, :boolean, default: false
      add :last_synced_at, :utc_datetime
      add :text_content, :text
      add :metadata, :map, default: %{}
      add :tags, {:array, :string}, default: []
      add :status, :string, default: "local"
      add :sync_error, :string
      add :needs_upload, :boolean, default: true
      add :needs_download, :boolean, default: false
      timestamps(type: :utc_datetime)
    end

    create index(:local_documents, [:user_id])
    create index(:local_documents, [:user_id, :status])

    create table(:offline_operations, primary_key: false) do
      add :id, :string, primary_key: true
      add :user_id, :string, null: false
      add :type, :string, null: false
      add :data, :map, null: false
      add :status, :string, default: "pending", null: false
      add :retry_count, :integer, default: 0, null: false
      add :error_message, :string
      add :last_retry_at, :utc_datetime
      add :processed_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create index(:offline_operations, [:user_id, :status])
    create index(:offline_operations, [:inserted_at])
  end
end
