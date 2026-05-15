defmodule Alem.Schemas.Activity do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @valid_types ~w(Invite Join Leave Create Delete Mention)

  schema "activities" do
    field :type,           :string
    field :actor_id,       :string
    field :actor_username, :string
    field :object_type,    :string
    field :object_id,      :string
    field :object_data,    :map, default: %{}
    field :to,             {:array, :string}, default: []
    field :cc,             {:array, :string}, default: []
    field :room_id,        :binary_id
    field :vault,          :string
    field :local,          :boolean, default: true
    field :published_at,   :utc_datetime

    has_many :inbox_items,   Alem.Schemas.InboxItem,    foreign_key: :activity_id
    has_many :notifications, Alem.Schemas.Notification, foreign_key: :activity_id

    timestamps(type: :utc_datetime)
  end

  def changeset(activity, attrs) do
    activity
    |> cast(attrs, [
      :type, :actor_id, :actor_username, :object_type, :object_id,
      :object_data, :to, :cc, :room_id, :vault, :local, :published_at
    ])
    |> validate_required([:type, :actor_id, :object_type, :published_at])
    |> validate_inclusion(:type, @valid_types)
  end
end