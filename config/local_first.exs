import Config

# Configure LibSQL for local-first storage
config :alem, Alem.LocalFirst.LibSQLRepo,
  database: Path.expand("../alem_local.db", __DIR__),
  pool_size: 5,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

# Local-first configuration
config :alem, :local_first,
  enabled: true,
  sync_interval: 300_000,  # 5 minutes
  max_retry_attempts: 3,
  offline_queue_size: 1000,
  auto_sync: true

# Data directory for local storage
config :alem, :data_dir, Path.expand("../data", __DIR__)

# Server base URL for sync operations
config :alem, :server_base_url, "http://localhost:4000"

# Sync registry for distributed sync managers
config :alem, Alem.LocalFirst.SyncRegistry,
  keys: :unique,
  name: Alem.LocalFirst.SyncRegistry
