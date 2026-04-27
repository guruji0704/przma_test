defmodule Alem.CAS.Ref do
  use Ecto.Schema
  import Ecto.Changeset

  schema "cas_refs" do
    field :cid,        :string
    field :user_did,   :string
    field :vault_tier, :string, default: "private"
    timestamps(type: :utc_datetime)
  end

  def changeset(ref, attrs) do
    ref
    |> cast(attrs, [:cid, :user_did, :vault_tier])
    |> validate_required([:cid, :user_did])
    |> validate_inclusion(:vault_tier, ["private", "vault", "federated"])
    |> unique_constraint([:cid, :user_did])
  end
end
