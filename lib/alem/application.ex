defmodule Alem.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Database
      Alem.Repo,

      # Telemetry
      AlemWeb.Telemetry,

      # DNS
      {DNSCluster, query: Application.get_env(:alem, :dns_cluster_query) || :ignore},

      # PubSub
      {Phoenix.PubSub, name: Alem.PubSub},

      # Presence (tracks online chat users per channel)
      AlemWeb.Presence,

      # LanceDB write subsystem (one GenServer per active user)
      Alem.Lance.Supervisor,

      # Broadway sync pipeline
      Alem.Lance.SyncPipeline,

      # Email
      # LanceDB HTTP connection pool
      {Finch, name: Alem.Lance.Finch, pools: %{
        "http://172.235.18.126:8765" => [size: 10]
      }},

      # Email / general HTTP
      {Finch, name: Alem.Finch},

      Alem.Sync.Manager,
      Alem.Vault.EpochKeyManager,

      # ← Horde registry first
      {Horde.Registry,
        name: Alem.Namespace.HordeRegistry,
        keys: :unique,
        members: :auto},

      # ← then Horde supervisor
      {Horde.DynamicSupervisor,
        name: Alem.Namespace.DynamicSupervisor,
        strategy: :one_for_one,
        members: :auto},

      # Web endpoint
      AlemWeb.Endpoint,

      # GraphQL subscriptions
      {Absinthe.Subscription, AlemWeb.Endpoint}
    ]

    # NOTE: PleromaMockServer is REMOVED.
    # Authentication now uses real database via Alem.Auth module.
    # No more fake server on port 4001.
    # 1. Sync Bootstrap SQLD (Metadata) before services start

    opts = [strategy: :one_for_one, name: Alem.Supervisor]
    Supervisor.start_link(children, opts)
     # Bootstrap sqld schema after startup


  end

  @impl true
  def config_change(changed, _new, removed) do
    AlemWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
