defmodule Alem.Repo.Migrations.AddDidIdToUsers do
  use Ecto.Migration

  @moduledoc """
  Add DID (Decentralized Identifier) to users.

  Each user gets exactly one DID at registration time.
  Format: did:przma:<base64url-sha256-fingerprint>

  The DID is the root identity used for:
  - Namespace creation (one namespace per DID)
  - PostgreSQL schema naming
  - Object storage bucket naming
  - Cross-service user identification
  """

  def change do
    alter table(:users) do
      # DID: "did:przma:<43-char-base64url-fingerprint>"
      # NULL until generated (existing users without DID)
      add :did_id, :string
    end

    # Unique — one DID per user, no sharing
    create unique_index(:users, [:did_id])
  end
end
