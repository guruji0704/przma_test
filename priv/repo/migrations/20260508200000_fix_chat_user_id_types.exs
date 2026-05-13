defmodule Alem.Repo.Migrations.FixChatUserIdTypes do
  use Ecto.Migration

  def up do
    # Drop and recreate with correct string user_id types.
    # Safe because no successful inserts occurred with the old schema.
    drop table(:chat_messages)
    drop table(:chat_rooms)

    create table(:chat_rooms, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :string, null: false
      add :vault, :string, null: false
      add :owner_user_id, :string, null: false
      add :description, :text
      add :is_dm, :boolean, default: false, null: false
      add :dm_user_ids, {:array, :string}, default: []
      add :max_members, :integer, default: 50
      timestamps(type: :utc_datetime)
    end

    create index(:chat_rooms, [:vault])
    create index(:chat_rooms, [:owner_user_id])
    create index(:chat_rooms, [:is_dm])

    create table(:chat_messages, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :room_id, references(:chat_rooms, type: :uuid, on_delete: :delete_all), null: false
      add :user_id, :string, null: false
      add :username, :string, null: false
      add :body, :text
      add :msg_type, :string, null: false, default: "text"
      add :file_doc_id, :string
      add :file_name, :string
      add :file_type, :string
      add :vault, :string, null: false
      add :deleted_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create index(:chat_messages, [:room_id])
    create index(:chat_messages, [:user_id])
    create index(:chat_messages, [:vault])
    create index(:chat_messages, [:inserted_at])
  end

  def down do
    drop table(:chat_messages)
    drop table(:chat_rooms)
  end
end
