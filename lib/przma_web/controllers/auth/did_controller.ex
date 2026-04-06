defmodule PrzmaWeb.Auth.DIDController do
  @moduledoc """
  DID registration and JWT token issuance.

  DEV STUB — Phase 2 will implement proper Ed25519 challenge-response.
  For now, any valid DID string is accepted and a JWT is issued directly.

  Flow for testing:
    1. POST /auth/did/register  {"did": "did:przma:user:alice"}
    2. POST /auth/did/verify    {"did": "did:przma:user:alice", "signature": "stub"}
       → returns {"token": "..."}  ← use this as Bearer token
  """
  use PrzmaWeb, :controller

  @doc "Register a new DID. In Phase 2, stores DID document."
  def register(conn, %{"did" => did} = _params) do
    if String.starts_with?(did, "did:przma:") do
      json(conn, %{
        did:     did,
        status:  "registered",
        message: "DID registered (stub). Use POST /auth/did/verify to get a token."
      })
    else
      conn
      |> put_status(400)
      |> json(%{error: "invalid_did", detail: "DID must start with did:przma:"})
    end
  end

  @doc "Issue a challenge nonce. In Phase 2, client signs this with their private key."
  def challenge(conn, %{"did" => did}) do
    nonce = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    json(conn, %{
      did:       did,
      nonce:     nonce,
      message:   "Sign this nonce with your DID private key, then POST to /auth/did/verify",
      expires_in: 300
    })
  end

  @doc "Verify the signed challenge and issue a JWT. STUB: accepts any signature."
  def verify(conn, %{"did" => did} = _params) do
    # Stub: accept any DID with did:przma: prefix
    if String.starts_with?(did, "did:przma:") do
      case Przma.Identity.JWT.issue(did) do
        {:ok, token} ->
          json(conn, %{
            token:      token,
            did:        did,
            token_type: "Bearer",
            expires_in: 86_400
          })

        {:error, reason} ->
          conn
          |> put_status(500)
          |> json(%{error: "token_issuance_failed", detail: inspect(reason)})
      end
    else
      conn
      |> put_status(401)
      |> json(%{error: "unauthorized", detail: "Invalid DID format"})
    end
  end

  def rotate_key(conn, _params) do
    json(conn, %{status: "stub", message: "Key rotation not yet implemented"})
  end

  def well_known(conn, _params) do
    json(conn, %{"@context" => "https://www.w3.org/ns/did/v1", "id" => "did:przma:server"})
  end
end
