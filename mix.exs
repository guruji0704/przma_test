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

      # ── AUTH (NEW) ──────────────────────────────────────
      # pbkdf2_elixir — password hashing
      # replaces fake mock server password checking
      {:pbkdf2_elixir, "~> 2.0"},

      # ── API DOCS ────────────────────────────────────────
      {:open_api_spex, "~> 3.18"},

      # ── EMAIL ───────────────────────────────────────────
      {:swoosh, "~> 1.5"},
      {:finch, "~> 0.13"},

      # ── TELEMETRY ───────────────────────────────────────
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},

      # ── UTILITIES ───────────────────────────────────────
      {:gettext, "~> 0.26"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.1.1"},
      {:bandit, "~> 1.5"},

      # ── DISTRIBUTED SYSTEMS ─────────────────────────────
      {:horde, "~> 0.9.0"},

      # ── STORAGE - S3 ────────────────────────────────────
      {:ex_aws, "~> 2.5"},
      {:ex_aws_s3, "~> 2.5"},
      {:hackney, "~> 1.20"},
      {:sweet_xml, "~> 0.7"},

      # ── HTTP CLIENT ─────────────────────────────────────
      {:req, "~> 0.4"},

      # ── PLUG ────────────────────────────────────────────
      {:plug, "~> 1.15"},
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
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
