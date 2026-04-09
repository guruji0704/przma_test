import Config

if System.get_env("PHX_SERVER") do
  config :alem, AlemWeb.Endpoint, server: true
end

config :alem, AlemWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# S3 / Object Storage Configuration — all from env vars at runtime
config :ex_aws,
  access_key_id:     [{:system, "AWS_ACCESS_KEY_ID"}],
  secret_access_key: [{:system, "AWS_SECRET_ACCESS_KEY"}],
  timeout:           600_000,
  recv_timeout:      600_000

s3_host = System.get_env("AWS_S3_ENDPOINT", "in-maa-1.linodeobjects.com")
config :ex_aws, :s3,
  scheme:       "https",
  host:         s3_host,
  region:       System.get_env("AWS_S3_REGION", "in-maa-1"),
  virtual_host: false

config :ex_aws, :hackney,
  timeout:      600_000,
  recv_timeout: 600_000,
  expect:       false

# Pleroma API
pleroma_base_url =
  System.get_env("PLEROMA_BASE_URL") ||
  case config_env() do
    :dev -> "http://localhost:4001"
    _    -> "https://pleroma.social"
  end
config :alem, :pleroma, base_url: pleroma_base_url

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :alem, Alem.Repo,
    url:            database_url,
    pool_size:      String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "localhost"

  config :alem, AlemWeb.Endpoint,
    http: [
      ip:   {0, 0, 0, 0},
      port: String.to_integer(System.get_env("PORT", "4000")),
      thousand_island_options: [read_timeout: 300_000]
    ],
    url:    [host: host, port: 443],
    server: true,
    secret_key_base: secret_key_base

  config :alem, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")
end
