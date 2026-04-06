defmodule Przma.Identity.JWT do
  @moduledoc """
  DID JWT issue and verification.

  Issues HS256 JWTs signed with the configured jwt_secret.
  In production, switch to Ed25519 (ES256) signed with the DID key.

  Claims:
    sub  - the user's DID
    exp  - expiry (24 hours from issuance)
    iat  - issued at
  """

  @expiry_seconds 86_400  # 24 hours

  def issue(did) when is_binary(did) do
    now    = System.system_time(:second)
    claims = %{
      "sub" => did,
      "iat" => now,
      "exp" => now + @expiry_seconds
    }

    header  = Base.url_encode64(Jason.encode!(%{"alg" => "HS256", "typ" => "JWT"}), padding: false)
    payload = Base.url_encode64(Jason.encode!(claims), padding: false)
    sig     = sign_jwt("#{header}.#{payload}")
    token   = "#{header}.#{payload}.#{sig}"
    {:ok, token}
  end

  def verify(token) when is_binary(token) do
    with [header_b64, payload_b64, sig] <- String.split(token, "."),
         ^sig <- sign_jwt("#{header_b64}.#{payload_b64}"),
         {:ok, payload_json} <- Base.url_decode64(payload_b64, padding: false),
         {:ok, claims}       <- Jason.decode(payload_json) do
      now = System.system_time(:second)
      if claims["exp"] > now do
        {:ok, claims}
      else
        {:error, :token_expired}
      end
    else
      _ -> {:error, :invalid_token}
    end
  end

  defp sign_jwt(message) do
    secret = jwt_secret()
    :crypto.mac(:hmac, :sha256, secret, message)
    |> Base.url_encode64(padding: false)
  end

  defp jwt_secret do
    Application.fetch_env!(:przma, :jwt_secret)
  end
end
