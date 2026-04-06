defmodule Przma.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # 1. Telemetry
      PrzmaWeb.Telemetry,
      # 2. Database
      Przma.Repo,
      # 3. DNS cluster (Phoenix generated — keep it)
      # {DNSCluster, query: Application.get_env(:przma, :dns_cluster_query) || :ignore},
      # 4. Vault infrastructure
      Przma.Vault.Supervisor,
      # 5. Identity (DID registry, JWT)
      Przma.Identity.Supervisor,
      # 6. XRPC Lexicon registry
      Przma.XRPC.LexiconRegistry,
      # 7. CRDT sync engine
      Przma.Sync.Supervisor,
      # 8. Federation (ActivityPub, HTTP Signatures)
      Przma.Federation.Supervisor,
      # 9. AI agents
      Przma.AI.Supervisor,
      # 10. PubSub
      {Phoenix.PubSub, name: Przma.PubSub},
      # 11. Presence
      PrzmaWeb.Presence,
      # 12. Oban background jobs
      {Oban, Application.fetch_env!(:przma, Oban)},
      # 13. Web endpoint — always last
      PrzmaWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Przma.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    PrzmaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
