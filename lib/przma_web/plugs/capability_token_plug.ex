defmodule PrzmaWeb.Plugs.CapabilityTokenPlug do
  import Plug.Conn
  def init(opts), do: opts
  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, cap}           <- Przma.Identity.CapabilityToken.verify_agent(token) do
      conn
      |> assign(:current_did, cap.owner_did)
      |> assign(:agent_cap,   cap)
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.json(%{error: "invalid_capability_token"})
        |> halt()
    end
  end
end
