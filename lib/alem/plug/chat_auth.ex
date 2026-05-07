defmodule AlemWeb.Plugs.ChatAuth do
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    token = extract_token(conn)

    if is_nil(token) do
      conn
      |> put_status(401)
      |> json(%{error: "Unauthorized — Bearer token required"})
      |> halt()
    else
      # Token இருந்தா — assign பண்ணு
      # TODO: Pleroma verify_credentials call பண்ணலாம்
      conn
      |> assign(:token, token)
    end
  end

  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _                    -> nil
    end
  end
end
