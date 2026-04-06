defmodule PrzmaWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :przma

  socket "/socket", PrzmaWeb.UserSocket,
    websocket: [
      connect_info:   [:peer_data, :x_headers, :uri],
      compress:       true,
      check_origin:   :conn,
      max_frame_size: 1_000_000
    ],
    longpoll: false

  socket "/sync", PrzmaWeb.SyncSocket,
    websocket: [connect_info: [:peer_data, :x_headers], compress: true],
    longpoll: true

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers:      [:urlencoded, :multipart, :json],
    pass:         ["application/json", "application/activity+json", "application/ld+json"],
    json_decoder: Jason,
    body_reader:  {PrzmaWeb.Plugs.CacheBodyReader, :read_body, []}

  plug Plug.MethodOverride
  plug Plug.Head
  plug PrzmaWeb.Plugs.ActivityPubContentNegotiation
  plug PrzmaWeb.Router
end
