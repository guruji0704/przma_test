defmodule PrzmaWeb.Auth.TokenController do
  use PrzmaWeb, :controller

  def refresh(conn, %{"token" => token}) do
    case Przma.Identity.JWT.verify(token) do
      {:ok, claims} ->
        {:ok, new_token} = Przma.Identity.JWT.issue(claims["sub"])
        json(conn, %{token: new_token, token_type: "Bearer", expires_in: 86_400})
      {:error, _} ->
        conn |> put_status(401) |> json(%{error: "invalid_token"})
    end
  end

  def revoke(conn, _params) do
    # Stub: JWT is stateless, real revocation needs a denylist
    json(conn, %{status: "revoked", message: "Token revocation logged (stub)"})
  end
end
