defmodule Alem.Storage.VaultCas do
  @moduledoc """
  Vault-isolated CAS. Each vault has its own CAS namespace and S3 path.
  No global CAS. No cross-vault content sharing.
  """

  import Ecto.Query
  alias Alem.Repo
  alias Alem.Storage.Paths
  alias Alem.Services.StorageProvider
  alias Alem.Cas.CasObject
  require Logger

  @doc """
  Store bytes in vault CAS. Returns {:ok, hash, s3_key}.
  For :private vault: pass encrypted bytes — this module does NOT encrypt.
  """
  def put(user, vault, bytes, content_type) do
    did      = user.did_id
    hash     = sha256(bytes)
    provider = StorageProvider.for_vault(user, vault)
    s3_key   = Paths.cas_path(did, vault, hash)
    ns_key   = Paths.namespace_key(did, vault)
    now      = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.get(CasObject, hash) do
      nil ->
        with :ok <- StorageProvider.put(provider, s3_key, bytes, content_type) do
          Repo.insert!(%CasObject{
            content_hash: hash, namespace_key: ns_key, actor_did: did,
            storage_backend: "s3", storage_key: s3_key, media_type: content_type,
            file_size: byte_size(bytes), ref_count: 1,
            is_current: true, is_corrupt: false, is_verified: false,
            effective_from: now
          })
          Logger.info("[VaultCas] NEW #{vault} #{String.slice(hash,0,12)}… #{byte_size(bytes)}b")
          {:ok, hash, s3_key}
        end

      _existing ->
        increment_ref(hash)
        Logger.info("[VaultCas] DEDUP #{vault} #{String.slice(hash,0,12)}…")
        {:ok, hash, s3_key}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def exists?(hash), do: Repo.exists?(from c in CasObject, where: c.content_hash == ^hash)

  def increment_ref(hash) do
    Repo.update_all(from(c in CasObject, where: c.content_hash == ^hash), inc: [ref_count: 1])
  end

  def get(hash), do: Repo.get(CasObject, hash)

  def presigned_url(user, hash, opts \\ []) do
    expires_in = Keyword.get(opts, :expires_in, 3600)
    provider   = StorageProvider.for_user(user)
    case get(hash) do
      nil -> {:error, :not_found}
      cas -> StorageProvider.presigned_url(provider, cas.storage_key, expires_in: expires_in)
    end
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
