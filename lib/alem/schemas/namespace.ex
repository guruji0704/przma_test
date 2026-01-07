defmodule Alem.Schemas.Namespace do
  @moduledoc """
  Schema for namespace metadata.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime]

  schema "namespaces" do
    field :tenant_id, :string
    field :config, :map, default: %{}
    field :status, :string, default: "active"
    field :document_count, :integer, default: 0
    field :vector_count, :integer, default: 0
    field :storage_bytes, :integer, default: 0
    field :last_activity_at, :utc_datetime

    timestamps()
  end

  def changeset(namespace, attrs) do
    namespace
    |> cast(attrs, [:id, :tenant_id, :config, :status, :document_count, :vector_count,
                    :storage_bytes, :last_activity_at])
    |> validate_required([:id, :tenant_id])
    |> validate_inclusion(:status, ["active", "suspended", "deleted"])
  end
end
