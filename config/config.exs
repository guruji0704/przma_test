import Config

# ── Application ────────────────────────────────────────────────────────────
config :przma,
  ecto_repos: [Przma.Repo],
  generators: [timestamp_type: :utc_datetime]

# ── Phoenix Endpoint ───────────────────────────────────────────────────────
config :przma, PrzmaWeb.Endpoint,
  url:    [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: PrzmaWeb.ErrorJSON], layout: false],
  pubsub_server: Przma.PubSub,
  live_view: [signing_salt: "przma_lv_salt"]

# ── JSON ───────────────────────────────────────────────────────────────────
config :phoenix, :json_library, Jason

# ── Logger ─────────────────────────────────────────────────────────────────
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# ── S3 (Linode Object Storage) — base config, credentials in dev.exs ───────
config :ex_aws,
  region: "in-maa-1",
  retries: [max_attempts: 3, base_backoff_in_ms: 100, max_backoff_in_ms: 10_000]

config :ex_aws, :s3,
  scheme: "https://",
  host:   "in-maa-1.linodeobjects.com",
  region: "in-maa-1"

config :ex_aws, :hackney,
  timeout:      600_000,
  recv_timeout: 600_000

# ── Vault lifecycle ────────────────────────────────────────────────────────
config :przma, :vault,
  hot_threshold_ms:  300_000,
  warm_threshold_ms: 1_800_000,
  pool_size: 4

# ── sqld shards ────────────────────────────────────────────────────────────
config :przma, :sqld_shards, [
  %{index: 0, url: "http://sqld-0:8080", max_users: 2000},
  %{index: 1, url: "http://sqld-1:8080", max_users: 2000},
  %{index: 2, url: "http://sqld-2:8080", max_users: 2000},
  %{index: 3, url: "http://sqld-3:8080", max_users: 2000}
]

# ── Oban background jobs ───────────────────────────────────────────────────
config :przma, Oban,
  repo:   Przma.Repo,
  queues: [default: 10, inbox: 10, federation: 10, analytics: 20],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 604_800},
    {Oban.Plugins.Cron, crontab: [
      {"0 3 * * *", Przma.Workers.ContentGCSweep},
      {"0 4 * * 0", Przma.Workers.ParquetCompaction}
    ]}
  ]

# ── S3 bucket ──────────────────────────────────────────────────────────────
config :przma, :s3,
  bucket: "perkeep",
  region: "in-maa-1"

# ── Hammer rate limiter ────────────────────────────────────────────────────
config :hammer,
  backend: {Hammer.Backend.ETS, [
    expiry_ms:       60_000 * 60 * 4,   # 4 hours
    cleanup_interval_ms: 60_000 * 10         # clean every 10 minutes
  ]}

# ── Import environment-specific config (must stay at bottom) ───────────────
import_config "#{config_env()}.exs"
