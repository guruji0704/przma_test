defmodule Alem.Schemas.SyncLog do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime]

  schema "sync_logs" do
    field :user_id, :string
    field :operation, :string
    field :resource_id, :string
    field :status, :string
    field :metadata, :map, default: %{}
    field :error_message, :string
    field :duration_ms, :integer

    timestamps()
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [:user_id, :operation, :resource_id, :status, :metadata, :error_message, :duration_ms])
    |> validate_required([:user_id, :operation, :status])
    |> validate_inclusion(:status, ["success", "error", "conflict_resolved", "conflict_failed"])
  end
end
