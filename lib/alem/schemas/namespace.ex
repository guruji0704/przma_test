defmodule Alem.Schemas.Namespace do
  @moduledoc "Schema for namespace metadata — one row per user."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime]

  schema "namespaces" do
    field :tenant_id,          :string
    field :config,             :map,    default: %{}
    field :status,             :string, default: "active"
    field :document_count,     :integer, default: 0
    field :vector_count,       :integer, default: 0
    field :storage_bytes,      :integer, default: 0
    field :last_activity_at,   :utc_datetime

    # DID / identity — added by migration 20260330114109
    field :did,                :string
    field :pleroma_account_id, :string
    field :identity_type,      :string, default: "did"
    # did | pleroma | hybrid

    timestamps()
  end

  @castable [:id, :tenant_id, :config, :status, :document_count, :vector_count,
             :storage_bytes, :last_activity_at, :did, :pleroma_account_id, :identity_type]

  def changeset(namespace, attrs) do
    namespace
    |> cast(attrs, @castable)
    |> validate_required([:id, :tenant_id])
    |> validate_inclusion(:status, ["active", "suspended", "deleted"])
    |> unique_constraint(:did, name: :namespaces_did_index)
    |> unique_constraint(:pleroma_account_id, name: :namespaces_pleroma_account_id_index)
  end
end
