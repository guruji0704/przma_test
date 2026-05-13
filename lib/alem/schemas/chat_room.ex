defmodule Alem.Schemas.ChatRoom do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "chat_rooms" do
    field :name,          :string
    field :vault,         :string
    field :owner_user_id, :string
    field :description,   :string
    field :is_dm,         :boolean, default: false
    field :dm_user_ids,   {:array, :string}, default: []
    field :max_members,   :integer, default: 50
    field :join_token,    :string

    has_many :messages, Alem.Schemas.ChatMessage, foreign_key: :room_id, references: :id

    timestamps(type: :utc_datetime)
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [:name, :vault, :owner_user_id, :description, :is_dm, :dm_user_ids, :max_members, :join_token])
    |> validate_required([:name, :vault, :owner_user_id])
    |> validate_inclusion(:vault, ["personal", "private", "social"])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_number(:max_members, greater_than: 0, less_than_or_equal_to: 500)
    |> generate_join_token()
    |> unique_constraint(:join_token)
  end

  defp generate_join_token(changeset) do
    if get_field(changeset, :is_dm) or get_field(changeset, :join_token) do
      changeset
    else
      token = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
      put_change(changeset, :join_token, token)
    end
  end
end
