import Config

config :alem, Alem.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "alemmm_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :alem, AlemWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
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
