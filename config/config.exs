import Config

config :alem,
  ecto_repos: [Alem.Repo],
  generators: [timestamp_type: :utc_datetime]

# Database
config :alem, Alem.Repo,
  database: "dev_alem",
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



#config :alem, Alem.Mailer,
 # adapter: Swoosh.Adapters.SMTP,
  #relay: "mail.przma.com",
  #port: 465,
  #username: "noreply@przma.com",
  #password: "dev.mail@12345",
  #ssl: true,
  #tls: :always,
  #auth: :always,
  #retries: 2,
  #no_mx_lookups: false,
  #sockopts: [
   # {:verify, :verify_none},
    #{:versions, [:"tlsv1.2"]}
  #]


# config :swoosh, :api_client, Swoosh.ApiClient.Finch

# ExAws S3 Configuration
config :ex_aws,
  access_key_id: [{:system, "AWS_ACCESS_KEY_ID"}],
  secret_access_key: [{:system, "AWS_SECRET_ACCESS_KEY"}],
  region: "in-maa-1",
  retries: [
    max_attempts: 1,
    base_backoff_in_ms: 10,
    max_backoff_in_ms: 10_000
  ]

config :ex_aws, :s3,
  scheme: "https://",
  host: "in-maa-1.linodeobjects.com",
  region: "in-maa-1"

config :ex_aws, :hackney,
  timeout: 600_000,
  recv_timeout: 600_000

# CouchDB Configuration
config :alem, :couchdb,
  enabled: true,
  url: "http://172.235.17.68:5984",
  user: "admin",
  password: "new.P@ssw0rd",
  timeout: 10_000

# File Storage
config :alem, :file_storage,
  bucket: "perkeep",
  max_file_size: 1_073_741_824,
  allowed_extensions: ~w(.jpg .jpeg .png .gif .pdf .doc .docx .txt .mp4 .mov .avi)

# JWT
config :joken, default_signer: "your-secret-key-here"

# Pleroma API Configuration
config :alem, :pleroma,
  base_url: System.get_env("PLEROMA_BASE_URL", "https://pleroma.social")

# Assets
config :esbuild,
  version: "0.25.4",
  alem: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :tailwind,
  version: "3.4.3",
  alem: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

config :alem, Alem.LocalFirst.LibSQLRepo,
  database: Path.expand("../priv/local_data/alem_local.db", __DIR__),
  pool_size: 1,
  journal_mode: :wal,
  busy_timeout: 5_000

config :alem, ecto_repos: [Alem.Repo, Alem.LocalFirst.LibSQLRepo]

config :alem, :local_first_data_dir, Path.expand("../priv/local_data", __DIR__)

import_config "#{config_env()}.exs"
