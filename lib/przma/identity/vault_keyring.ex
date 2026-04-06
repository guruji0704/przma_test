defmodule Przma.Identity.VaultKeyring do
  @moduledoc """
  STUB: Derives a per-user AES-256-GCM vault encryption key.

  TODO Phase 2: Derive the vault key from the user's DID private key
  using HKDF-SHA256. The key is derived — never stored — so losing
  the DID private key means losing vault access (by design).

  Key derivation path:
    HKDF(ikm: did_private_key, salt: did, info: "przma-vault-key-v1")
  """

  @doc "Derive the 32-byte AES-256 vault key for a DID."
  def derive_vault_key(did) when is_binary(did) do
    # Stub: derive a deterministic key from the DID using HMAC-SHA256
    # In production, this MUST use the actual Ed25519 private key as IKM
    secret = Application.fetch_env!(:przma, :jwt_secret)
    key    = :crypto.mac(:hmac, :sha256, secret, "vault-key-v1:" <> did)
    {:ok, key}
  end
end
