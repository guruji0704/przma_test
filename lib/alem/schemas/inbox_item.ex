defmodule Alem.Schemas.InboxItem do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "inbox_items" do
    field :user_id, :string
    field :read,    :boolean, default: false
    field :read_at, :utc_datetime

    belongs_to :activity, Alem.Schemas.Activity,
      foreign_key: :activity_id,
      type: :binary_id

    timestamps(type: :utc_datetime)
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [:user_id, :activity_id, :read, :read_at])
    |> validate_required([:user_id, :activity_id])
    |> unique_constraint([:user_id, :activity_id])
  end
end