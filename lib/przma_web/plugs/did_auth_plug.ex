defmodule PrzmaWeb.Plugs.DIDAuthPlug do
  import Plug.Conn
  def init(opts), do: opts
  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, claims}        <- Przma.Identity.JWT.verify(token),
         {:ok, user}          <- Przma.Identity.DIDRegistry.get_user(claims["sub"]) do
      conn
      |> assign(:current_did,  claims["sub"])
      |> assign(:current_user, user)
      |> assign(:token_claims, claims)
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.json(%{
             error:  "unauthorized",
             detail: "Valid DID JWT required. Obtain via POST /auth/did/verify"
           })
        |> halt()
    end
  end
end
