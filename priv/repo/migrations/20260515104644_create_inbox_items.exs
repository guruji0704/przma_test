defmodule Alem.Repo.Migrations.CreateInboxItems do
  use Ecto.Migration

  def change do
    create table(:inbox_items, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :string, null: false
      add :activity_id, references(:activities, type: :binary_id, on_delete: :delete_all),
          null: false
      add :read, :boolean, default: false
      add :read_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create index(:inbox_items, [:user_id])
    create index(:inbox_items, [:user_id, :read])
    create unique_index(:inbox_items, [:user_id, :activity_id])
  end
end