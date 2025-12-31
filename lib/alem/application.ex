defmodule Alem.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AlemWeb.Telemetry,
      Alem.Repo,
      {Phoenix.PubSub, name: Alem.PubSub},
      {DNSCluster, query: Application.get_env(:alem, :dns_cluster_query) || :ignore},
      {Finch, name: Alem.Finch},

      # Horde for distributed namespaces
      {Horde.Registry,
        name: Alem.Namespace.HordeRegistry,
        keys: :unique,
        members: :auto},

      {Horde.DynamicSupervisor,
        name: Alem.Namespace.DynamicSupervisor,
        strategy: :one_for_one,
        members: :auto},

      AlemWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Alem.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    AlemWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
