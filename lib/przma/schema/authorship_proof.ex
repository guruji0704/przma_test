defmodule Przma.Schema.AuthorshipProof do
  @moduledoc """
  Ecto schema for content authorship proofs.

  Stores the Ed25519 signature proving a DID authored a given CID.
  Used during federation, estate activation, and circle sharing.
  Created by migration 002.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "authorship_proofs" do
    field :cid,       :string
    field :owner_did, :string
    field :sig,       :string

    timestamps(type: :utc_datetime)
  end

  def changeset(proof, attrs) do
    proof
    |> cast(attrs, [:cid, :owner_did, :sig])
    |> validate_required([:cid, :owner_did, :sig])
    |> unique_constraint([:cid, :owner_did])
  end
end
