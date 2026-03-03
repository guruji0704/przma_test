defmodule Alem.Repo.Migrations.CreateSyncLogs do
  use Ecto.Migration

  def change do
    create table(:sync_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :string, null: false
      add :operation, :string, null: false
      add :resource_id, :string
      add :status, :string, null: false
      add :metadata, :map, default: %{}
      add :error_message, :text
      add :duration_ms, :integer

      timestamps()
    end

    create index(:sync_logs, [:user_id])
    create index(:sync_logs, [:inserted_at])
    create index(:sync_logs, [:user_id, :inserted_at])
  end
end
