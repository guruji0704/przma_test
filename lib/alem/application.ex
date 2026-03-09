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

      # Email
      {Finch, name: Alem.Finch},

      Alem.Sync.Manager,

      # Distributed namespace management
      #Alem.Namespace.HordeSupervisor,

      # Web endpoint (Phoenix on port 4201)
      AlemWeb.Endpoint
    ]

    # NOTE: PleromaMockServer is REMOVED.
    # Authentication now uses real database via Alem.Auth module.
    # No more fake server on port 4001.
    Task.start(fn ->
      Process.sleep(2_000)  # wait for app to settle
      Alem.Sqld.ensure_schema()
    end)

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
