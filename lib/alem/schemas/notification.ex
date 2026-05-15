defmodule Alem.Schemas.Notification do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @valid_types ~w(invite join leave mention dm_request room_deleted)

  schema "notifications" do
    field :user_id,       :string
    field :from_user_id,  :string
    field :from_username, :string
    field :type,          :string
    field :room_id,       :binary_id
    field :read,          :boolean, default: false
    field :read_at,       :utc_datetime

    belongs_to :activity, Alem.Schemas.Activity,
      foreign_key: :activity_id,
      type: :binary_id

    timestamps(type: :utc_datetime)
  end

  def changeset(n, attrs) do
    n
    |> cast(attrs, [
      :user_id, :from_user_id, :from_username, :type,
      :activity_id, :room_id, :read, :read_at
    ])
    |> validate_required([:user_id, :type])
    |> validate_inclusion(:type, @valid_types)
  end
end