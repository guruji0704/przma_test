defmodule Przma.Vault.ContentStore do
  @moduledoc """
  Sovereign user content storage.

  Provides four plain functions over S3 + PostgreSQL.
  No GenServer. No CAS service process. No Horde registration.
  """

  require Logger

  alias Przma.Vault.{VaultManager, S3Client}
  alias Przma.Vault.NamespaceIndex

  # ── WRITE ─────────────────────────────────────────────────────────────────

  def store(content, owner_did, ns_path, opts \\ []) when is_binary(content) do
    tier = Keyword.get(opts, :tier, :personal)
    cid  = compute_cid(content)

    with :ok <- upload(cid, content, owner_did, tier, opts),
         :ok <- maybe_store_authorship(cid, owner_did, tier),
         :ok <- NamespaceIndex.upsert(ns_path, cid, owner_did, opts) do
      {:ok, cid}
    end
  end

  # ── READ ──────────────────────────────────────────────────────────────────

  def fetch(cid, owner_did) do
    key = s3_key(cid, owner_did)

    case S3Client.get(key) do
      {:ok, encrypted} ->
        with {:ok, decrypted} <- decrypt(encrypted, owner_did),
             ^cid             <- compute_cid(decrypted) do
          {:ok, decrypted}
        else
          {:error, _} = err -> err
          _                 -> {:error, :integrity_violation}
        end

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        Logger.warning("[ContentStore] S3 fetch failed for #{cid}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ── AUTHORSHIP ────────────────────────────────────────────────────────────

  def verify_authorship(cid, claimed_did, provided_sig) do
    case Przma.Repo.get_by(Przma.Schema.AuthorshipProof,
      cid: cid, owner_did: claimed_did
    ) do
      nil   -> {:error, :no_proof_on_record}
      proof ->
        if proof.sig == provided_sig do
          Przma.Identity.DIDKeyring.verify(
            claimed_did,
            cid <> claimed_did,
            provided_sig
          )
        else
          {:error, :signature_mismatch}
        end
    end
  end

  def compute_cid(content) when is_binary(content) do
    "blake3:" <> Base.url_encode64(:blake3.hash(content), padding: false)
  end

  # ── GC ────────────────────────────────────────────────────────────────────

  def gc_orphans do
    Przma.Vault.ContentGC.run()
  end

  # ── PRIVATE HELPERS ───────────────────────────────────────────────────────

  defp upload(cid, content, owner_did, tier, opts) do
    key = s3_key(cid, owner_did, tier)

    case S3Client.head(key) do
      {:ok, _} ->
        :ok

      {:error, :not_found} ->
        with {:ok, vault_key} <- VaultManager.get_vault_key(owner_did),
             {:ok, encrypted} <- encrypt(content, vault_key) do
          S3Client.put(key, encrypted, content_type: Keyword.get(opts, :mime_type))
        end
    end
  end

  defp maybe_store_authorship(cid, owner_did, :social) do
    with {:ok, sig} <- Przma.Identity.DIDKeyring.sign(owner_did, cid <> owner_did) do
      Przma.Repo.insert(
        %Przma.Schema.AuthorshipProof{
          cid:       cid,
          owner_did: owner_did,
          sig:       sig
        },
        on_conflict: :nothing,
        conflict_target: [:cid, :owner_did]
      )
      :ok
    end
  end
  defp maybe_store_authorship(_cid, _owner_did, _tier), do: :ok

  defp s3_key(cid, owner_did, tier \\ :personal) do
    case tier do
      :social -> "shared/#{cid}"
      _       -> "users/#{owner_did}/#{cid}"
    end
  end

  defp encrypt(content, vault_key) do
    nonce = :crypto.strong_rand_bytes(12)
    case :crypto.crypto_one_time_aead(:aes_256_gcm, vault_key, nonce, content, "", true) do
      {ciphertext, tag} -> {:ok, nonce <> tag <> ciphertext}
      error             -> {:error, error}
    end
  end

  defp decrypt(<<nonce::binary-12, tag::binary-16, ciphertext::binary>>, owner_did) do
    with {:ok, vault_key} <- VaultManager.get_vault_key(owner_did) do
      case :crypto.crypto_one_time_aead(:aes_256_gcm, vault_key, nonce, ciphertext, "", tag, false) do
        plaintext when is_binary(plaintext) -> {:ok, plaintext}
        :error -> {:error, :decryption_failed}
      end
    end
  end
  defp decrypt(_malformed, _did), do: {:error, :malformed_ciphertext}
end
