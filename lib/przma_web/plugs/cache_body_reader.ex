defmodule PrzmaWeb.Plugs.CacheBodyReader do
  @moduledoc """
  Reads the request body and caches it in conn.assigns[:raw_body]
  so HTTP Signature verification can access the original bytes,
  while still allowing Plug.Parsers to parse it normally.
  """

  def read_body(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)
    conn = update_in(conn.assigns[:raw_body], fn existing ->
      (existing || "") <> body
    end)
    {:ok, body, conn}
  end
end
