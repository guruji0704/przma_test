defmodule Alem.Sqld.Router do
  @moduledoc """
  Routes sqld queries to the correct instance.

  ## Current Architecture (Single Instance)

      ┌─────────────────────────────────────────┐
      │  LINODE VPS (172.235.17.68)             │
      │                                         │
      │  sqld (systemd, port 8080)              │
      │  DB: /var/lib/sqld/data/przma.db        │
      │       │                                 │
      │       ↓ bottomless replication          │
      └───────┼─────────────────────────────────┘
              │
              ↓
      ┌─────────────────────────────────────────┐
      │  LINODE OBJECT STORAGE (perkeep)        │
      │  Real-time automatic backup             │
      │  Recovery: ~8 seconds, zero data loss   │
      └─────────────────────────────────────────┘

  ## How to configure

  Single instance (current setup) — set one env var:
    SQLD_URL=http://172.235.17.68:8080

  Multiple instances (future horizontal scaling) — comma-separated:
    SQLD_URLS=http://sqld-1:8080,http://sqld-2:8080,http://sqld-3:8080

  Both are set in your .env file or Docker environment.

  ## Bottomless replication

  sqld automatically replicates every write to Linode Object Storage.
  If the server restarts, sqld restores from the cloud backup in ~8 seconds.
  No manual backup or restore is needed — it is fully automatic.

  ## Scaling path (future)

  When you need multiple sqld instances, change SQLD_URL → SQLD_URLS.
  This module uses consistent hashing so each user always routes to the
  same sqld instance — no data routing bugs when the pool grows.
  """

  require Logger

  # ── Public API ───────────────────────────────────────────────────────────────

  @doc """
  Returns the sqld URL for a given routing key (user_id or namespace_key).

  With a single instance: always returns that instance's URL.
  With multiple instances: uses consistent hashing — same key always
  maps to the same instance.

  ## Examples

      # Single instance (current setup)
      iex> Alem.Sqld.Router.url_for("any-user-id")
      "http://172.235.17.68:8080"

      # Multi-instance (future)
      iex> Alem.Sqld.Router.url_for("user-abc")
      "http://sqld-2:8080"
  """
  def url_for(routing_key) when is_binary(routing_key) do
    pool = pool_urls()

    case pool do
      [] ->
        raise "[Sqld.Router] No sqld instances configured — check SQLD_URL env var"

      [single_url] ->
        # Single instance — no routing needed
        single_url

      multiple_urls ->
        # Consistent hashing: same key → same instance
        index = :erlang.phash2(routing_key, length(multiple_urls))
        url   = Enum.at(multiple_urls, index)
        Logger.debug("[Sqld.Router] #{routing_key} → #{url} (index #{index}/#{length(multiple_urls)})")
        url
    end
  end

  def url_for(nil) do
    # No routing key — use first (or only) instance
    default_url()
  end

  @doc """
  Same as url_for/1 — named for clarity when routing by namespace key.
  The namespace_key comes from DID.namespace_key(user.did_id).
  """
  def url_for_namespace(namespace_key), do: url_for(namespace_key)

  @doc """
  Returns the primary sqld URL (first in the pool).
  Used for schema bootstrapping and admin operations.

  With a single instance, this is just SQLD_URL.
  """
  def default_url do
    pool_urls()
    |> List.first()
    |> case do
      nil -> raise "[Sqld.Router] No sqld instances configured — check SQLD_URL env var"
      url -> url
    end
  end

  @doc """
  Returns all sqld URLs.
  Used by health_controller to check every instance is reachable.
  """
  def all_urls, do: pool_urls()

  @doc """
  Returns the number of sqld instances currently configured.
  1 = single instance (current setup).
  N = horizontal scaling active.
  """
  def pool_size, do: length(pool_urls())

  # ── Private ──────────────────────────────────────────────────────────────────

  defp pool_urls do
    Application.get_env(:alem, :sqld, [])
    |> Keyword.get(:urls, ["http://localhost:8080"])
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
  end
end
