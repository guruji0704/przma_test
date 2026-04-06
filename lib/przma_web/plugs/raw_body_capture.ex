defmodule PrzmaWeb.Plugs.RawBodyCapture do
  def init(opts), do: opts
  def call(conn, _opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, length: 5_000_000)
    Plug.Conn.assign(conn, :raw_body, body)
  end
end
