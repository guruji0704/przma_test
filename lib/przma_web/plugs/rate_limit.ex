defmodule PrzmaWeb.Plugs.RateLimit do
  import Plug.Conn
  def init(opts), do: opts
  def call(conn, opts) do
    limit          = Keyword.get(opts, :limit, 100)
    window_seconds = Keyword.get(opts, :window_seconds, 60)
    ip             = conn.remote_ip |> Tuple.to_list() |> Enum.join(".")
    key            = "rate_limit:#{ip}"
    case Hammer.check_rate(key, window_seconds * 1_000, limit) do
      {:allow, _count} ->
        conn
      {:deny, _limit} ->
        conn
        |> put_status(429)
        |> Phoenix.Controller.json(%{error: "too_many_requests"})
        |> halt()
    end
  end
end
