defmodule Przma.Identity.DIDRegistry do
  @moduledoc """
  STUB: DID document storage and resolution.

  TODO Phase 2: Implement with Ecto schema + migration 001.
  Tables: did_documents (did, document, inserted_at, updated_at)
          did_keys (did, key_id, key_type, public_key, purpose)
  """
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_), do: {:ok, %{}}

  @doc "Register a new DID with its document."
  def register(did, document) when is_binary(did) and is_map(document) do
    {:ok, %{did: did, document: document}}
  end

  @doc "Resolve a DID to its document."
  def resolve(did) when is_binary(did) do
    {:ok, %{
      "id"                  => did,
      "verificationMethod"  => [],
      "authentication"      => [],
      "assertionMethod"     => []
    }}
  end

  @doc "Get a user record by DID (used by DIDAuthPlug)."
  def get_user(did) when is_binary(did) do
    # Stub: accept any DID that matches our format
    if String.starts_with?(did, "did:przma:") do
      {:ok, %{did: did, active: true}}
    else
      {:error, :not_found}
    end
  end

  @doc "Rotate the key for a DID."
  def rotate_key(did, new_public_key) do
    {:ok, %{did: did, key: new_public_key}}
  end
end
