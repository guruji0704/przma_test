defmodule Alem.Repo.Migrations.CreateChatRoomMembers do
  use Ecto.Migration

  def change do
    create table(:chat_room_members, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :room_id, references(:chat_rooms, type: :uuid, on_delete: :delete_all), null: false
      add :user_id, :string, null: false
      add :username, :string, null: false
      add :role, :string, default: "member", null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:chat_room_members, [:room_id, :user_id])
    create index(:chat_room_members, [:user_id])
    create index(:chat_room_members, [:room_id])
  end
end
