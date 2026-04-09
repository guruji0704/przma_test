defmodule AlemWeb.HealthController do
  use AlemWeb, :controller
  require Logger
  alias Alem.Repo

  def check(conn, _params) do
    services = check_services()
    overall = if all_critical_healthy?(services), do: :ok, else: :service_unavailable
    conn
    |> put_status(overall)
    |> json(%{
      status: if(overall == :ok, do: "ok", else: "degraded"),
      timestamp: DateTime.utc_now(),
      version: Application.spec(:alem, :vsn) |> to_string(),
      services: services
    })
  end

  defp check_services do
    %{
      postgres:       check_database(),
      object_storage: check_object_storage(),
      sqld:           check_sqld(),
      horde:          check_horde()
    }
  end

  defp check_database do
    case Repo.query("SELECT 1", []) do
      {:ok, _}         -> %{status: "healthy",   message: "PostgreSQL OK"}
      {:error, reason} -> %{status: "unhealthy", message: inspect(reason)}
    end
  rescue
    e -> %{status: "unhealthy", message: inspect(e)}
  end

  defp check_object_storage do
    bucket = Application.get_env(:alem, :file_storage)[:bucket] || "perkeep"
    case Alem.Storage.ObjectStore.list(bucket, "") do
      {:ok, _}         -> %{status: "healthy",   message: "S3 accessible (#{bucket})"}
      {:error, reason} -> %{status: "unhealthy", message: inspect(reason)}
    end
  rescue
    e -> %{status: "unhealthy", message: inspect(e)}
  end

  defp check_sqld do
    sqld_url = Application.get_env(:alem, :sqld_url, "http://localhost:8080")
    case Req.get("#{sqld_url}/health", receive_timeout: 2_000) do
      {:ok, %{status: 200}} -> %{status: "healthy",   message: "sqld reachable at #{sqld_url}"}
      _                     -> %{status: "unhealthy", message: "sqld not reachable (optional — sync disabled)"}
    end
  rescue
    e -> %{status: "unhealthy", message: inspect(e)}
  end

  defp check_horde do
    count = Horde.Registry.count(Alem.Namespace.HordeRegistry)
    %{status: "healthy", message: "Horde active, #{count} registrations", registrations: count}
  rescue
    e -> %{status: "unhealthy", message: inspect(e)}
  end

  # Only postgres + object_storage are critical; sqld and horde are optional
  defp all_critical_healthy?(services) do
    [:postgres, :object_storage]
    |> Enum.all?(fn key -> get_in(services, [key, :status]) == "healthy" end)
  end
end
