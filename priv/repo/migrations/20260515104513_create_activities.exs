defmodule Alem.Repo.Migrations.CreateActivities do
  use Ecto.Migration

  def change do
    create table(:activities, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :type, :string, null: false
      add :actor_id, :string, null: false
      add :actor_username, :string
      add :object_type, :string, null: false
      add :object_id, :string
      add :object_data, :map, default: %{}
      add :to, {:array, :string}, default: []
      add :cc, {:array, :string}, default: []
      add :room_id, :binary_id
      add :vault, :string
      add :local, :boolean, default: true
      add :published_at, :utc_datetime, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:activities, [:actor_id])
    create index(:activities, [:room_id])
    create index(:activities, [:type])
    create index(:activities, [:published_at])
  end
end