defmodule Alem.Schemas.ChatMessage do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "chat_messages" do
    field :room_id,     :binary_id
    field :user_id,     :string
    field :username,    :string
    field :body,        :string
    field :msg_type,    :string, default: "text"
    field :file_doc_id, :string
    field :file_name,   :string
    field :file_type,   :string
    field :vault,       :string
    field :deleted_at,  :utc_datetime

    belongs_to :room, Alem.Schemas.ChatRoom,
      foreign_key: :room_id,
      references:  :id,
      define_field: false

    timestamps(type: :utc_datetime)
  end

  def changeset(msg, attrs) do
    msg
    |> cast(attrs, [:room_id, :user_id, :username, :body, :msg_type,
                    :file_doc_id, :file_name, :file_type, :vault])
    |> validate_required([:room_id, :user_id, :username, :vault])
    |> validate_inclusion(:msg_type, ["text", "file", "image"])
    |> validate_inclusion(:vault, ["personal", "private", "social"])
    |> validate_length(:body, max: 4000)
  end
end
