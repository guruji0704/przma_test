import Config

# ── Database ───────────────────────────────────────────────────────────────
config :przma, Przma.Repo,
  username: "postgres",
  password: "new.P@ssw0rd",
  hostname: "localhost",
  database: "przma_sir",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# ── Phoenix Endpoint ───────────────────────────────────────────────────────
config :przma, PrzmaWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "U0p8WVeSgPQwzie15+WcZQCf9Yc0QDcw/HFI2scypTMXxON3ZP2S4LJwgGWYpjNi",
  watchers: []

# ── Logger / Phoenix dev settings ─────────────────────────────────────────
config :logger, :default_formatter, format: "[$level] $message\n"
config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime


# ── PRZMA: JWT ────────────────────────────────────────────────────────────
config :przma, :jwt_secret,
  "dev_jwt_secret_change_in_production_must_be_at_least_32_chars_abc"

# ── PRZMA: sqld shards ────────────────────────────────────────────────────
config :przma, :sqld_shards, [
  %{index: 0, url: "http://localhost:8080", max_users: 2000}
]

# ── PRZMA: S3 — Linode Object Storage (real credentials from alem) ────────
config :ex_aws,
  access_key_id:     "QBQ24J1P1BV957AUYYXV",
  secret_access_key: "LqqbMn1gBggICrvrqQMOKQ57T9rnqeXXOx6x8H7B"

config :ex_aws, :s3,
  scheme: "https://",
  host:   "in-maa-1.linodeobjects.com",
  region: "in-maa-1",
  port:   443

config :przma, :s3,
  bucket: "perkeep",
  region: "in-maa-1"

# ── PRZMA: Oban (inline for dev — no background job workers needed) ────────
config :przma, Oban, testing: :inline

# ── PRZMA: Vault lifecycle ────────────────────────────────────────────────
config :przma, :vault,
  hot_threshold_ms:  300_000,
  warm_threshold_ms: 1_800_000,
  pool_size: 4
