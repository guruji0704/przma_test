defmodule Alem.DID do
  @moduledoc """
  Decentralized Identifier (DID) generation and management.
  Format: did:przma:<base64url-sha256-fingerprint>
  """

  @doc """
  Generate a new DID for a user.
  Creates a unique identifier using SHA-256 hash.
  """
  def generate(user_id) do
    # Create unique input: user_id + random nonce + timestamp
    nonce = :crypto.strong_rand_bytes(32)
    timestamp = System.system_time(:microsecond)

    input = "#{user_id}#{Base.encode64(nonce)}#{timestamp}"

    # Generate SHA-256 hash
    hash = :crypto.hash(:sha256, input)

    # Encode as base64url (no padding)
    fingerprint = Base.url_encode64(hash, padding: false)

    # Format as DID
    "did:przma:#{fingerprint}"
  end

  @doc """
  Extract the fingerprint from a DID.
  Returns {:ok, fingerprint} or {:error, :invalid_did}
  """
  def fingerprint(did) do
    case String.split(did, ":", parts: 3) do
      ["did", "przma", fp] when byte_size(fp) > 0 -> {:ok, fp}
      _ -> {:error, :invalid_did}
    end
  end

  @doc """
  Get namespace key from DID (first 16 characters of fingerprint).
  Used for tenant isolation in databases and S3.
  """
  def namespace_key(did) do
    case fingerprint(did) do
      {:ok, fp} -> String.slice(fp, 0, 16)
      {:error, _} -> nil
    end
  end

  @doc """
  Validate DID format.
  """
  def valid?(did) when is_binary(did) do
    case String.split(did, ":", parts: 3) do
      ["did", "przma", fp] when byte_size(fp) > 0 -> true
      _ -> false
    end
  end

  def valid?(_), do: false
end
