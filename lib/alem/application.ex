defmodule Alem.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do

    # ✅ ETS — children-க்கு முன்னாடி இங்க போடணும்
    :ets.new(:chat_messages, [:named_table, :public, :ordered_set])
    :ets.new(:chat_rooms,    [:named_table, :public, :set])

    children = [
      # Database
      Alem.Repo,

      # ❌ இந்த 2 lines remove பண்ணிட்டோம்
      # :ets.new(:chat_messages, ...),
      # :ets.new(:chat_rooms,    ...),

      # Telemetry
      AlemWeb.Telemetry,

      # DNS
      {DNSCluster, query: Application.get_env(:alem, :dns_cluster_query) || :ignore},

      # PubSub
      {Phoenix.PubSub, name: Alem.PubSub},
      AlemWeb.Presence,

      # Email
      {Finch, name: Alem.Finch},

      Alem.Sync.Manager,
      Alem.Vault.EpochKeyManager,

      {Horde.Registry,
        name: Alem.Namespace.HordeRegistry,
        keys: :unique,
        members: :auto},

      {Horde.DynamicSupervisor,
        name: Alem.Namespace.DynamicSupervisor,
        strategy: :one_for_one,
        members: :auto},

      AlemWeb.Endpoint,

      {Absinthe.Subscription, AlemWeb.Endpoint}
    ]

    sqld_url = Application.get_env(:alem, :sqld_url, "http://localhost:8080")
    try do
      Alem.Sqld.ensure_schema()
    rescue
      e -> Logger.error("[sqld] Bootstrap exception: #{inspect(e)}")
    end

    opts = [strategy: :one_for_one, name: Alem.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    AlemWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
