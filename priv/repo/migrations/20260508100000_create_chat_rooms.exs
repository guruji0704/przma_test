defmodule Alem.Repo.Migrations.CreateChatRooms do
  use Ecto.Migration

  def change do
    create table(:chat_rooms, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :string, null: false
      add :vault, :string, null: false
      add :owner_user_id, :integer, null: false
      add :description, :text
      add :is_dm, :boolean, default: false, null: false
      add :dm_user_ids, {:array, :integer}, default: []
      add :max_members, :integer, default: 50
      timestamps(type: :utc_datetime)
    end

    create index(:chat_rooms, [:vault])
    create index(:chat_rooms, [:owner_user_id])
    create index(:chat_rooms, [:is_dm])
  end
end
