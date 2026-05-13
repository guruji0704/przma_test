defmodule Alem.Schemas.ChatRoomMember do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "chat_room_members" do
    field :room_id, :binary_id
    field :user_id, :string
    field :username, :string
    field :role,     :string, default: "member"

    belongs_to :room, Alem.Schemas.ChatRoom,
      foreign_key: :room_id,
      references:  :id,
      define_field: false

    timestamps(type: :utc_datetime)
  end

  def changeset(member, attrs) do
    member
    |> cast(attrs, [:room_id, :user_id, :username, :role])
    |> validate_required([:room_id, :user_id, :username])
    |> validate_inclusion(:role, ["owner", "member"])
    |> unique_constraint([:room_id, :user_id])
  end
end
