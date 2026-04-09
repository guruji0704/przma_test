defmodule AlemWeb.HealthController do
  @moduledoc """
  GET /api/health — checked by Linode NodeBalancer every 10 seconds.
  Returns 200 if all critical services are healthy, 503 if degraded.

  Services checked:
    - PostgreSQL (Ecto)
    - S3/Linode Object Storage
    - sqld (LibSQL HTTP API)
    - Horde registry (namespace manager distribution)
  """

  use AlemWeb, :controller
  require Logger
  alias Alem.Repo

  def check(conn, _params) do
    services = check_services()
    overall  = if all_healthy?(services), do: :ok, else: :service_unavailable

    conn
    |> put_status(overall)
    |> json(%{
      status:    if(overall == :ok, do: "ok", else: "degraded"),
      timestamp: DateTime.utc_now(),
      version:   Application.spec(:alem, :vsn) |> to_string(),
      services:  services
    })
  end

  defp check_services do
    %{
      postgres:       check_postgres(),
      object_storage: check_object_storage(),
      sqld:           check_sqld(),
      horde:          check_horde()
    }
  end

  defp check_postgres do
    case Repo.query("SELECT 1", []) do
      {:ok, _}         -> %{status: "healthy",   message: "PostgreSQL OK"}
      {:error, reason} -> %{status: "unhealthy", message: inspect(reason)}
    end
  rescue
    e -> %{status: "unhealthy", message: inspect(e)}
  end

  defp check_object_storage do
    bucket = Application.get_env(:alem, :file_storage, [])[:bucket] || "perkeep"
    case Alem.Storage.ObjectStore.list(bucket, "") do
      {:ok, _}         -> %{status: "healthy",   message: "S3 accessible (#{bucket})"}
      {:error, reason} -> %{status: "unhealthy", message: inspect(reason)}
    end
  rescue
    e -> %{status: "unhealthy", message: inspect(e)}
  end

  defp check_sqld do
    sqld_url = Application.get_env(:alem, :sqld_url, "http://localhost:8080")
    case Req.get("#{sqld_url}/health", receive_timeout: 3_000) do
      {:ok, %{status: 200}}    -> %{status: "healthy",   message: "sqld OK at #{sqld_url}"}
      {:ok, %{status: status}} -> %{status: "unhealthy", message: "sqld HTTP #{status}"}
      {:error, reason}         -> %{status: "unhealthy", message: inspect(reason)}
    end
  rescue
    e -> %{status: "unhealthy", message: inspect(e)}
  end

  defp check_horde do
    count = Horde.Registry.count(Alem.Namespace.HordeRegistry)
    %{status: "healthy", message: "Horde active, #{count} registrations"}
  rescue
    e -> %{status: "unhealthy", message: inspect(e)}
  end

  defp all_healthy?(services) do
    # sqld being down is non-fatal — sync is optional
    critical = Map.drop(services, [:sqld])
    Enum.all?(critical, fn {_, v} -> v[:status] == "healthy" end)
  end
end
