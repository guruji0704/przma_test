defmodule AlemWeb.HealthController do
  @moduledoc """
  Health check endpoint required by load balancers.

  GET /api/health  →  200 OK    (all services healthy)
  GET /api/health  →  503       (one or more services down)

  ## Checked services

  1. PostgreSQL — Ecto connection pool
  2. sqld — libSQL HTTP API (172.235.17.68:8080)
     Note: sqld has bottomless replication to Linode Object Storage.
     The backup is automatic — no separate backup service to check.
  3. Linode Object Storage — file storage (perkeep bucket)
  4. CouchDB — document store

  ## Used by

  - Linode NodeBalancer (when set up) polls this every 10 seconds
  - Manual checks: curl http://172.235.17.68:4201/api/health
  - Monitoring dashboards
  """
  use AlemWeb, :controller
  require Logger
  alias Alem.Repo
  alias Alem.Sqld.Router

  def check(conn, _params) do
    services = check_all()
    healthy  = all_healthy?(services)
    status   = if healthy, do: :ok, else: :service_unavailable

    conn
    |> put_status(status)
    |> json(%{
      status:    if(healthy, do: "ok", else: "degraded"),
      timestamp: DateTime.utc_now(),
      version:   Application.spec(:alem, :vsn) |> to_string(),
      node:      node_info(),
      services:  services
    })
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  defp check_all do
    %{
      postgres:       check_postgres(),
      sqld:           check_sqld(),
      object_storage: check_object_storage(),
      couchdb:        check_couchdb(),
    }
  end

  # PostgreSQL via Ecto
  defp check_postgres do
    case Repo.query("SELECT 1", []) do
      {:ok, _}         -> %{status: "healthy", message: "PostgreSQL OK"}
      {:error, reason} -> %{status: "unhealthy", message: inspect(reason)}
    end
  rescue
    e -> %{status: "unhealthy", message: inspect(e)}
  end

  # sqld — single systemd instance on Linode VPS with bottomless replication
  defp check_sqld do
    urls    = Router.all_urls()
    results = Enum.map(urls, fn url -> {url, ping_sqld(url)} end)

    healthy = Enum.count(results, fn {_, r} -> r.status == "healthy" end)
    total   = length(results)

    base = %{
      pool_size:     total,
      backup_mode:   "bottomless replication → Linode Object Storage (automatic)",
      instances:     Map.new(results)
    }

    if healthy == total do
      Map.merge(base, %{status: "healthy", message: "All #{total} sqld instance(s) OK"})
    else
      Map.merge(base, %{status: "unhealthy",
                        message: "#{total - healthy} of #{total} sqld instance(s) unreachable"})
    end
  end

  defp ping_sqld(url) do
    case Req.get("#{url}/health", receive_timeout: 3_000) do
      {:ok, %{status: 200}} ->
        %{status: "healthy", url: url}
      {:ok, %{status: status}} ->
        %{status: "unhealthy", url: url, message: "HTTP #{status}"}
      {:error, reason} ->
        %{status: "unhealthy", url: url, message: inspect(reason)}
    end
  rescue
    e -> %{status: "unhealthy", url: url, message: inspect(e)}
  end

  # Linode Object Storage — S3-compatible, also where sqld backups go
  defp check_object_storage do
    bucket = Application.get_env(:alem, :file_storage)[:bucket] ||
               System.get_env("S3_BUCKET", "perkeep")

    case Alem.Storage.ObjectStore.list(bucket, "") do
      {:ok, objects} ->
        %{
          status:  "healthy",
          message: "Linode Object Storage OK",
          bucket:  bucket,
          note:    "sqld bottomless replication also writes to this bucket"
        }
      {:error, reason} ->
        %{status: "unhealthy", message: inspect(reason)}
    end
  rescue
    e -> %{status: "unhealthy", message: inspect(e)}
  end

  # CouchDB
  defp check_couchdb do
    case Alem.Storage.DocumentStore.ensure_database("health_check") do
      :ok              -> %{status: "healthy", message: "CouchDB OK"}
      {:error, reason} -> %{status: "unhealthy", message: inspect(reason)}
    end
  rescue
    e -> %{status: "unhealthy", message: inspect(e)}
  end

  # All services must be healthy for overall 200
  defp all_healthy?(services) do
    Enum.all?(services, fn {_, v} -> v[:status] == "healthy" end)
  end

  # Info about this specific Phoenix instance (useful when load-balanced)
  defp node_info do
    %{
      hostname:  System.get_env("HOSTNAME", "unknown"),
      node:      Node.self() |> to_string(),
      sqld_urls: Router.all_urls(),
      sqld_pool: Router.pool_size(),
    }
  end
end
