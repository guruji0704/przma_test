defmodule Alem.Storage.Paths do
  @moduledoc """
  Centralized path generation. ALL paths must come from here.
  Never hardcode "cas/", "user/", "personal/" anywhere else.

  S3 layout:
    home/{prefix}/personal/cas/{ab}/{cd}/{hash}
    home/{prefix}/personal/documents/{doc_id}/{filename}
    home/{prefix}/private/cas/{ab}/{cd}/{hash}     <- encrypted bytes only
    home/{prefix}/private/encrypted/{doc_id}/{filename}
    home/{prefix}/public/cas/{ab}/{cd}/{hash}
    home/{prefix}/public/documents/{doc_id}/{filename}
    home/{prefix}/shared/documents/{doc_id}/{filename}
  """

  # ── DID prefix ─────────────────────────────────────────────────────────────

  def did_prefix(did) when is_binary(did) do
    did |> String.split(":") |> List.last() |> String.slice(0, 20)
  end

  # ── Vault roots ────────────────────────────────────────────────────────────

  def home_root(did),     do: "home/#{did_prefix(did)}"
  def personal_root(did), do: "home/#{did_prefix(did)}/personal"
  def private_root(did),  do: "home/#{did_prefix(did)}/private"
  def public_root(did),   do: "home/#{did_prefix(did)}/public"
  def shared_root(did),   do: "home/#{did_prefix(did)}/shared"

  def vault_root(did, :personal), do: personal_root(did)
  def vault_root(did, :private),  do: private_root(did)
  def vault_root(did, :public),   do: public_root(did)
  def vault_root(did, :shared),   do: shared_root(did)
  def vault_root(did, v) when is_binary(v),
    do: vault_root(did, String.to_existing_atom(v))

  # ── CAS paths (isolated per vault) ────────────────────────────────────────

  def personal_cas_path(did, hash),
    do: "#{personal_root(did)}/cas/#{shard(hash)}/#{hash}"
  def private_cas_path(did, hash),
    do: "#{private_root(did)}/cas/#{shard(hash)}/#{hash}"
  def public_cas_path(did, hash),
    do: "#{public_root(did)}/cas/#{shard(hash)}/#{hash}"

  def cas_path(did, :personal, hash), do: personal_cas_path(did, hash)
  def cas_path(did, :private,  hash), do: private_cas_path(did, hash)
  def cas_path(did, :public,   hash), do: public_cas_path(did, hash)
  def cas_path(did, v, hash) when is_binary(v),
    do: cas_path(did, String.to_existing_atom(v), hash)

  # ── Document paths ─────────────────────────────────────────────────────────

  def personal_doc_path(did, doc_id, fn_),
    do: "#{personal_root(did)}/documents/#{doc_id}/#{fn_}"
  def public_doc_path(did, doc_id, fn_),
    do: "#{public_root(did)}/documents/#{doc_id}/#{fn_}"
  def private_encrypted_path(did, doc_id, fn_),
    do: "#{private_root(did)}/encrypted/#{doc_id}/#{fn_}"
  def shared_doc_path(did, doc_id, fn_),
    do: "#{shared_root(did)}/documents/#{doc_id}/#{fn_}"
  def chat_file_path(did, vault, conv_id, doc_id, fn_),
    do: "#{vault_root(did, vault)}/chat/#{conv_id}/#{doc_id}/#{fn_}"

  def doc_path(did, :personal, doc_id, fn_), do: personal_doc_path(did, doc_id, fn_)
  def doc_path(did, :public,   doc_id, fn_), do: public_doc_path(did, doc_id, fn_)
  def doc_path(did, :private,  doc_id, fn_), do: private_encrypted_path(did, doc_id, fn_)
  def doc_path(did, :shared,   doc_id, fn_), do: shared_doc_path(did, doc_id, fn_)
  def doc_path(did, v, doc_id, fn_) when is_binary(v),
    do: doc_path(did, String.to_existing_atom(v), doc_id, fn_)

  # ── Vector / Preview / Activity ────────────────────────────────────────────

  def vector_path(did, vault),           do: "#{vault_root(did, vault)}/vectors"
  def preview_path(did, vault, doc_id),  do: "#{vault_root(did, vault)}/previews/#{doc_id}"
  def activity_path(did, vault),         do: "#{vault_root(did, vault)}/activity"
  def metadata_path(did, vault),         do: "#{vault_root(did, vault)}/metadata"
  def export_path(did, vault, export_id),do: "#{vault_root(did, vault)}/exports/#{export_id}"

  # ── Namespace key (used as tenant_id in DB) ────────────────────────────────

  def namespace_key(did, vault) when is_atom(vault),
    do: "#{did_prefix(did)}-#{vault}"
  def namespace_key(did, vault) when is_binary(vault),
    do: "#{did_prefix(did)}-#{vault}"

  # ── Vault helpers ──────────────────────────────────────────────────────────

  def vaults, do: [:personal, :private, :public, :shared]

  def parse_vault(v) when v in ["personal", "private", "public", "shared"],
    do: {:ok, String.to_existing_atom(v)}
  def parse_vault(_), do: {:error, :invalid_vault}

  def valid_vault?(v) when is_atom(v),   do: v in vaults()
  def valid_vault?(v) when is_binary(v), do: v in Enum.map(vaults(), &to_string/1)

  # ── Private ────────────────────────────────────────────────────────────────

  defp shard(hash) when is_binary(hash) and byte_size(hash) >= 4 do
    "#{String.slice(hash, 0, 2)}/#{String.slice(hash, 2, 2)}"
  end
  defp shard(_), do: "00/00"
end
