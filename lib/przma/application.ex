defmodule Przma.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      PrzmaWeb.Telemetry,
      Przma.Repo,
      {DNSCluster, query: Application.get_env(:przma, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Przma.PubSub},
      # Start a worker by calling: Przma.Worker.start_link(arg)
      # {Przma.Worker, arg},
      # Start to serve requests, typically the last entry
      PrzmaWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Przma.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PrzmaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
