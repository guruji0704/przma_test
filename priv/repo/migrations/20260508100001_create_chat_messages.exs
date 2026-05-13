defmodule Alem.Repo.Migrations.CreateChatMessages do
  use Ecto.Migration

  def change do
    create table(:chat_messages, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :room_id, references(:chat_rooms, type: :uuid, on_delete: :delete_all), null: false
      add :user_id, :integer, null: false
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
end
