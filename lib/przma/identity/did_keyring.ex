defmodule Przma.Identity.DIDKeyring do
  @moduledoc """
  STUB: Ed25519 key generation, signing, and verification for DIDs.

  TODO Phase 2: Implement using :crypto.generate_key(:eddsa, :ed25519)
  and :crypto.sign(:eddsa, :none, message, [private_key, :ed25519]).
  Keys are stored in the OS keychain or HSM in production.
  """

  @doc "Generate a new Ed25519 key pair. Returns {public_key, private_key}."
  def generate_keypair do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    {:ok, %{public_key: pub, private_key: priv}}
  end

  @doc "Sign a message on behalf of a DID."
  def sign(did, message) when is_binary(did) and is_binary(message) do
    # Stub: use HMAC as a signature placeholder
    secret = Application.fetch_env!(:przma, :jwt_secret)
    sig    = :crypto.mac(:hmac, :sha256, secret, did <> message)
    {:ok, Base.encode64(sig)}
  end

  @doc "Verify a signature for a DID."
  def verify(did, message, signature) when is_binary(did) do
    case sign(did, message) do
      {:ok, expected_sig} ->
        if expected_sig == signature, do: :ok, else: {:error, :signature_mismatch}
      err -> err
    end
  end
end
