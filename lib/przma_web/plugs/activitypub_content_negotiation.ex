defmodule PrzmaWeb.Plugs.ActivityPubContentNegotiation do
  import Plug.Conn
  @ap_types ["application/activity+json", "application/ld+json"]
  def init(opts), do: opts
  def call(conn, _opts) do
    ap? =
      get_req_header(conn, "accept")
      |> Enum.any?(&Enum.any?(@ap_types, fn t -> String.contains?(&1, t) end))
    assign(conn, :activity_pub_request?, ap?)
  end
end
