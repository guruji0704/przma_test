defmodule Przma.Vault.NamespaceIndex do
  @moduledoc """
  STUB: Maps namespace paths to CIDs in PostgreSQL.

  TODO Phase 2: Implement with Ecto schema and migration 002.
  Table: namespace_index (path, cid, owner_did, tier, inserted_at)
  """

  def upsert(_ns_path, _cid, _owner_did, _opts \\ []), do: :ok

  def get(_ns_path, _owner_did), do: {:error, :not_found}

  def list(_owner_did, _prefix, _opts \\ []), do: {:ok, []}

  def delete(_ns_path, _owner_did), do: :ok
end
