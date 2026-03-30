defmodule Alem.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Alem.Repo,
      AlemWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:alem, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Alem.PubSub},
      {Finch, name: Alem.Finch},
      Alem.Sync.Manager,
      # Epoch key manager for vault encryption
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

      # Web endpoint — must start before Absinthe.Subscription
      AlemWeb.Endpoint,
      # GraphQL subscriptions (real-time uploads notification)
      {Absinthe.Subscription, AlemWeb.Endpoint}
      # Horde namespace supervisor — uncomment when deploying multi-node:
      # Alem.Namespace.Supervisor,
    ]

    Task.start(fn ->
      Process.sleep(2_000)
      sqld_url = Application.get_env(:alem, :sqld_url, "http://localhost:8080")
      case Req.get("#{sqld_url}/health", receive_timeout: 3_000) do
        {:ok, %{status: 200}} ->
          Alem.Sqld.ensure_schema()
        _ ->
          require Logger
          Logger.info("[sqld] Not reachable — skipping schema bootstrap")
      end
    end)

    opts = [strategy: :one_for_one, name: Alem.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    AlemWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
