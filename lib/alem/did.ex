# =============================================================================
# Alem.DID — Decentralized Identifier Generation
# =============================================================================
# W3C DID Core spec: https://www.w3.org/TR/did-core/
#
# Format: did:przma:<base64url-fingerprint>
#
# Each user gets exactly ONE DID, created at registration.
# The DID never changes. It is the root identity for namespace creation.
# Namespace for user = derived from their DID.
# =============================================================================

defmodule Alem.DID do
  @moduledoc """
  Decentralized Identifier (DID) generation for the PRZMA/ALEM system.

  ## Format

      did:przma:<base64url-encoded-sha256-fingerprint>

  Example:

      did:przma:K7mF2xQ9rPvN3wLtZoYeA8hCbDsJuGiMnRkXpWqTcVlH

  ## How it works

  1. User registers → `Alem.DID.generate(user_id)` is called
  2. A SHA-256 fingerprint is computed from user_id + random nonce + timestamp
  3. The DID is stored in `users.did_id` — ONE DID per user, forever
  4. All namespaces for that user are derived from their DID

  ## Why DID matters

  - Globally unique — no two users share a DID
  - Cryptographically random — cannot be guessed or enumerated
  - Self-sovereign — user owns the identifier
  - Namespace root — `did:przma:<fp>` → namespace `ns:<fp>` → pg schema `user_<fp[:12]>`
  """

  @did_method "przma"

  @doc """
  Generate a new unique DID for a user.

  Combines user_id + random 32 bytes + microsecond timestamp,
  hashes with SHA-256, encodes as base64url.

  Returns: `"did:przma:<fingerprint>"`
  """
  def generate(user_id) when is_binary(user_id) do
    # Random nonce — prevents any two users getting same DID even if registered same microsecond
    nonce = :crypto.strong_rand_bytes(32)

    # Microsecond timestamp — adds temporal uniqueness
    ts = System.system_time(:microsecond) |> Integer.to_string()

    # SHA-256 over: user_id + nonce + timestamp
    # Result: 32 bytes = 43 chars in base64url (no padding)
    fingerprint =
      :crypto.hash(:sha256, user_id <> nonce <> ts)
      |> Base.url_encode64(padding: false)

    "did:#{@did_method}:#{fingerprint}"
  end

  @doc """
  Validate that a string is a valid PRZMA DID.

  Returns true if the DID starts with `did:przma:` and has a non-empty fingerprint.
  """
  def valid?(did) when is_binary(did) do
    case String.split(did, ":", parts: 3) do
      ["did", @did_method, fp] when byte_size(fp) > 0 -> true
      _ -> false
    end
  end
  def valid?(_), do: false

  @doc """
  Extract the fingerprint portion from a DID.

      iex> Alem.DID.fingerprint("did:przma:K7mF2x...")
      {:ok, "K7mF2x..."}

      iex> Alem.DID.fingerprint("invalid")
      {:error, :invalid_did}
  """
  def fingerprint(did) when is_binary(did) do
    case String.split(did, ":", parts: 3) do
      ["did", @did_method, fp] when byte_size(fp) > 0 -> {:ok, fp}
      _ -> {:error, :invalid_did}
    end
  end

  @doc """
  Derive a short namespace key from a DID (first 16 chars of fingerprint).
  Used for PostgreSQL schema names and bucket prefixes.

      iex> Alem.DID.namespace_key("did:przma:K7mF2xQ9rPvN3wLt...")
      "K7mF2xQ9rPvN3wLt"
  """
  def namespace_key(did) when is_binary(did) do
    case fingerprint(did) do
      {:ok, fp} -> String.slice(fp, 0, 16) |> String.downcase()
      _ -> nil
    end
  end
end
