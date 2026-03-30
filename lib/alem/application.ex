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

      # Epoch key manager — generates + rotates x25519 keypairs for vault CAS decryption.
      # Must start before AlemWeb.Endpoint so the epoch endpoint is ready on first request.
      # Requires EPOCH_MASTER_KEY env var (32 random bytes, base64-encoded).
      Alem.Vault.EpochKeyManager,

      # Distributed namespace management
      #Alem.Namespace.HordeSupervisor,

      # Web endpoint (Phoenix on port 4201)
      AlemWeb.Endpoint
    ]

    # NOTE: PleromaMockServer is REMOVED.
    # Authentication now uses real database via Alem.Auth module.
    # No more fake server on port 4001.
    Task.start(fn ->
      Process.sleep(2_000)
      sqld_url = Application.get_env(:alem, :sqld_url, "http://localhost:8080")
      case Req.get("#{sqld_url}/health", receive_timeout: 3_000) do
        {:ok, %{status: 200}} ->
          Alem.Sqld.ensure_schema()
        _ ->
          require Logger
          Logger.info("[sqld] Not reachable at #{sqld_url} — skipping schema bootstrap (sync disabled locally)")
      end
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
