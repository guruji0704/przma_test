defmodule AlemWeb.EpochController do
  use AlemWeb, :controller
  require Logger

  alias Alem.Vault.EpochKeyManager

  # ══════════════════════════════════════════════════════════════════════════
  # GET /api/v1/vault/epoch/current
  #
  # Returns the server's current epoch x25519 public key.
  # PUBLIC endpoint — no authentication required.
  # Clients fetch this at startup and after login to enable v2 vault encryption.
  #
  # Response: { epoch_id: integer, public_key: "base64 x25519 key" }
  # ══════════════════════════════════════════════════════════════════════════

  def current(conn, _params) do
    case EpochKeyManager.current_public_key() do
      {:ok, epoch_id, public_key_b64} ->
        Logger.info("[EpochController] Serving epoch_id=#{epoch_id}")
        json(conn, %{epoch_id: epoch_id, public_key: public_key_b64})

      {:error, reason} ->
        Logger.error("[EpochController] Failed to get current epoch key: #{inspect(reason)}")
        conn |> put_status(503) |> json(%{error: "Epoch key unavailable"})
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # GET /.well-known/did.json
  #
  # DID document for did:web identity resolution (ATProto-style).
  # Publishes the current epoch public key as the key agreement method.
  # The DID document also serves as the authoritative source of the epoch key
  # for any DID-aware resolver.
  #
  # Conforms to: https://www.w3.org/TR/did-core/
  # Key type:    X25519KeyAgreementKey2020
  # ══════════════════════════════════════════════════════════════════════════

  def did_document(conn, _params) do
    base_url = AlemWeb.Endpoint.url()
    # did:web uses the host as the identifier
    host = URI.parse(base_url).host || "przma.app"
    did  = "did:web:#{host}"

    case EpochKeyManager.current_public_key() do
      {:ok, epoch_id, public_key_b64} ->
        # Convert base64 → multibase (z-prefix = base58btc) for DID spec compliance
        # For simplicity we use base64url here (u-prefix = base64url no padding)
        multibase_key = "u" <> Base.url_encode64(Base.decode64!(public_key_b64), padding: false)

        doc = %{
          "@context" => [
            "https://www.w3.org/ns/did/v1",
            "https://w3id.org/security/suites/x25519-2020/v1"
          ],
          "id"                  => did,
          "verificationMethod"  => [
            %{
              "id"                 => "#{did}#epoch-#{epoch_id}",
              "type"               => "X25519KeyAgreementKey2020",
              "controller"         => did,
              "publicKeyMultibase" => multibase_key,
            }
          ],
          "keyAgreement"  => ["#{did}#epoch-#{epoch_id}"],
          "service"       => [
            %{
              "id"              => "#{did}#przma-sync",
              "type"            => "PrzmaSync",
              "serviceEndpoint" => base_url
            }
          ]
        }

        conn
        |> put_resp_content_type("application/did+json")
        |> json(doc)

      {:error, _} ->
        conn |> put_status(503) |> json(%{error: "DID document temporarily unavailable"})
    end
  end
end
