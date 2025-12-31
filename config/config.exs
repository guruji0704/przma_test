import Config

config :alem,
  ecto_repos: [Alem.Repo],
  generators: [timestamp_type: :utc_datetime]

# Database
config :alem, Alem.Repo,
  database: "alem_#{config_env()}",
  username: "postgres",
  password: "postgres",
  hostname: "172.235.17.68",
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# Endpoint
config :alem, AlemWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AlemWeb.ErrorHTML, json: AlemWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Alem.PubSub,
  live_view: [signing_salt: "lvhRER8G"],
http: [
    thousand_island_options: [
      read_timeout: 600_000
    ],
    http_1_options: [
      max_request_line_length: 10_000,
      max_header_length: 10_000
    ]
  ]
