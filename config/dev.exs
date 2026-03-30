import Config

# ── PostgreSQL (local install) ─────────────────────────────────────────────
# Default credentials for a standard local PostgreSQL install.
# Change username/password to match your local postgres setup.
config :alem, Alem.Repo,
  username: "postgres",
  password: "new.P@ssw0rd",
  hostname: "localhost",
  database: "namespcae_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# ── sqld (libsql server) ───────────────────────────────────────────────────
# Points to localhost. sqld is only needed for sync features.
# For benchmark testing (mix benchmark), sqld is NOT required.
# Download sqld binary: https://github.com/tursodatabase/libsql/releases
config :alem, :sqld_url, "http://localhost:8080"

# ── S3 / MinIO ─────────────────────────────────────────────────────────────
# File uploads are skipped gracefully if S3 is unreachable locally.
# For full upload testing, install MinIO: https://min.io/download#windows
config :ex_aws,
  access_key_id: "minioadmin",
  secret_access_key: "minioadmin"

config :ex_aws, :s3,
  scheme: "http://",
  host: "localhost",
  port: 9000,
  region: "local"

# ── CouchDB ────────────────────────────────────────────────────────────────
# Only needed if CouchDB features are used. Safe to leave if unused.
config :alem, :couchdb,
  enabled: false,
  url: "http://localhost:5984",
  user: "admin",
  password: "admin",
  timeout: 10_000

# ── Vault epoch key (dev placeholder) ─────────────────────────────────────
# Fine for local dev. In prod this must be a real 32-byte secret.
config :alem, :epoch_master_key,
  System.get_env("EPOCH_MASTER_KEY", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")

# ── Phoenix Endpoint ───────────────────────────────────────────────────────
config :alem, AlemWeb.Endpoint,
  http: [
    ip: {127, 0, 0, 1},
    port: 4000,
    thousand_island_options: [read_timeout: 300_000]
  ],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "TYPluKe+33aYQCwORlkEwTADppYLiB7fVdKrxNk0YQBFsNtSQ9iLj4+ZNm9d4Ox5",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:alem, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:alem, ~w(--watch)]}
  ]

config :alem, AlemWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*\.po$",
      ~r"lib/alem_web/(controllers|live|components)/.*\.(ex|heex)$"
    ]
  ]

config :alem, dev_routes: true

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  debug_heex_annotations: true,
  enable_expensive_runtime_checks: true

config :alem, :pleroma, base_url: "http://localhost:4001"

# Allow unauthenticated analytics POST from localhost for local testing
config :alem, :analytics_dev_bypass, true

config :alem, Alem.LocalFirst.LibSQLRepo,
  database: Path.expand("../priv/local_data/alem_local_dev.db", __DIR__),
  pool_size: 1,
  journal_mode: :wal,
  busy_timeout: 5_000,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true
