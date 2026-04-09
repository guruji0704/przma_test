defmodule Alem.Schemas.LocalUser do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime]

  schema "local_users" do
    field :user_id, :string
    field :client_id, :string
    field :device_info, :map
    field :last_sync_at, :utc_datetime
    field :status, :string, default: "active"

    timestamps()
  end

  def changeset(local_user, attrs) do
    local_user
    |> cast(attrs, [:id, :user_id, :client_id, :device_info, :last_sync_at, :status])
    |> validate_required([:id, :user_id])
  end
end
