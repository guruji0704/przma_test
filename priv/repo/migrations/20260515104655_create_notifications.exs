defmodule Alem.Repo.Migrations.CreateNotifications do
  use Ecto.Migration

  def change do
    create table(:notifications, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :string, null: false
      add :from_user_id, :string
      add :from_username, :string
      add :type, :string, null: false
      add :activity_id, references(:activities, type: :binary_id, on_delete: :delete_all)
      add :room_id, :binary_id
      add :read, :boolean, default: false
      add :read_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create index(:notifications, [:user_id])
    create index(:notifications, [:user_id, :read])
    create index(:notifications, [:user_id, :inserted_at])
  end
end