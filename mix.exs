defmodule Alem.MixProject do
  use Mix.Project

  def project do
    [
      app: :alem,
      version: "0.1.0",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Alem.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Phoenix Framework
      {:phoenix, "~> 1.7.21"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.10"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.0"},
      {:floki, ">= 0.30.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},

      # Assets
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.2.0", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.1.1",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},

      # Email
      {:swoosh, "~> 1.5"},
      {:finch, "~> 0.13"},
      {:multipart, "~> 0.4"},

      # Telemetry
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},

      # Utilities
      {:gettext, "~> 0.26"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.1.1"},
      {:bandit, "~> 1.5"},
      {:req, "~> 0.5"},

      # Distributed Systems
      {:horde, "~> 0.9.0"},

      # Storage - S3/Object Storage
      {:ex_aws, "~> 2.5"},
      {:ex_aws_s3, "~> 2.5"},
      {:hackney, "~> 1.20"},
      {:sweet_xml, "~> 0.7"},

      # LibSQL Support
      {:exqlite, "~> 0.24"},
      {:ecto_sqlite3, "~> 0.17"},

      # JWT
      {:joken, "~> 2.6"},
      {:jose, git: "https://github.com/potatosalad/erlang-jose.git", tag: "1.11.10", override: true},

      # API Documentation
      {:open_api_spex, "~> 3.18"},

      # WebSocket for real-time sync
      {:phoenix_pubsub, "~> 2.1"},

      # UUID generation
      {:uuid, "~> 1.1"},

      {:corsica, "~> 2.0"},
      {:pbkdf2_elixir, "~> 2.0"},


      {:castore, "~> 1.0"},
      {:gen_smtp, "~> 1.2"},

      # Analytics: Apache Arrow IPC + Parquet (via Polars NIF)
      # Receives Arrow IPC batches from Tauri client → converts to Parquet → S3
      {:explorer, "~> 0.10"},

      # Analytics: MessagePack serialization (benchmark comparison + XRPC wire)
      {:msgpax, "~> 2.4"},

      # GraphQL — Absinthe
      {:absinthe,         "~> 1.7"},
      {:absinthe_plug,    "~> 1.5"},
      {:absinthe_phoenix, "~> 2.0"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      benchmark: ["run benchmark/run_benchmark.exs"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind alem", "esbuild alem"],
      "assets.deploy": [
        "tailwind alem --minify",
        "esbuild alem --minify",
        "phx.digest"
      ]
    ]
  end
end
