import Config

config :alem, AlemWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json",
  # PORT comes from environment — allows running multiple instances on different ports
  http:   [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4000"))],
  # PHX_HOST is used to build full URLs (e.g., in password reset emails)
  url:    [host: System.get_env("PHX_HOST", "localhost"),
           port: String.to_integer(System.get_env("PORT", "4000"))],
  server: true

config :swoosh, api_client: Swoosh.ApiClient.Req
config :swoosh, local: false

config :logger, level: :info
