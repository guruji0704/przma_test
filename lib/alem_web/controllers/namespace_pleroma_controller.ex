defmodule AlemWeb.NamespacePleromaController do
  use AlemWeb, :controller
  require Logger

  alias Alem.Namespace
  alias Alem.Namespace.PleromaIntegration

  # Use PleromaAuth plug for all actions
  plug AlemWeb.Plugs.PleromaAuth

  @doc """
  Create or get namespace for authenticated Pleroma user
  POST /api/v1/namespaces
  """
  def create_or_get(conn, _params) do
    token = conn.assigns.pleroma_token
    account_info = conn.assigns.pleroma_account
    account_id = conn.assigns.pleroma_account_id

    case PleromaIntegration.ensure_namespace_for_pleroma_account(account_id, token) do
      {:ok, user_id, _account_info} ->
        case Namespace.status(user_id) do
          {:ok, status} ->
            conn
            |> put_status(:ok)
            |> json(%{
              namespace: format_namespace_status(status, account_info),
              did: user_id,           # ← ADD THIS — user_id IS the DID
              user_id: user_id,       # ← ADD THIS — so Tauri knows real user_id
              identity_type: "hybrid" # ← ADD THIS — tells Tauri DID is active
            })

          error ->
            Logger.error("Failed to get namespace status: #{inspect(error)}")
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: "Failed to get namespace status"})
        end

      {:error, :invalid_token} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Invalid Pleroma OAuth token"})

      {:error, reason} ->
        Logger.error("Failed to create namespace: #{inspect(reason)}")
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Failed to create namespace", details: inspect(reason)})
    end
  end

  @doc """
  Get namespace for authenticated Pleroma user
  GET /api/v1/namespaces
  """
  def get(conn, _params) do
    token = conn.assigns.pleroma_token
    account_info = conn.assigns.pleroma_account
    account_id = conn.assigns.pleroma_account_id

    case PleromaIntegration.get_namespace_for_pleroma_account(account_id, token) do
      {:ok, user_id, _account_info} ->
        case Namespace.status(user_id) do
          {:ok, status} ->
            conn
            |> json(%{
              namespace: format_namespace_status(status, account_info, include_details: true)
            })

          error ->
            Logger.error("Failed to get namespace status: #{inspect(error)}")
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: "Failed to get namespace status", details: inspect(error)})
        end

      {:error, :namespace_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Namespace not found for this Pleroma account"})

      {:error, :invalid_token} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Invalid Pleroma OAuth token"})

      {:error, reason} ->
        Logger.error("Failed to get namespace: #{inspect(reason)}")
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Failed to get namespace", details: inspect(reason)})
    end
  end

  @doc """
  Sync namespace with Pleroma
  POST /api/v1/namespaces/sync
  """
  def sync(conn, params) do
    token = conn.assigns.pleroma_token
    account_id = conn.assigns.pleroma_account_id
    sync_mode = params["sync_mode"] || "metadata_only"

    # Resolve account_id to namespace user_id
    case PleromaIntegration.get_namespace_for_pleroma_account(account_id, token) do
      {:ok, user_id, _account_info} ->
        opts = [sync_mode: String.to_atom(sync_mode)]

        case PleromaIntegration.sync_namespace_with_pleroma(user_id, token, opts) do
          {:ok, sync_result} ->
            conn
            |> json(%{
              message: "Sync completed",
              result: sync_result
            })

          {:error, reason} ->
            Logger.error("Sync failed: #{inspect(reason)}")
            conn
            |> put_status(:bad_request)
            |> json(%{error: "Sync failed", details: inspect(reason)})
        end

      {:error, :namespace_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Namespace not found"})

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Failed to resolve namespace", details: inspect(reason)})
    end
  end

  @doc """
  Get Pleroma account info for namespace
  GET /api/v1/namespaces/account
  """
  def get_account_info(conn, _params) do
    account_info = conn.assigns.pleroma_account
    account_id = conn.assigns.pleroma_account_id

    # Resolve to namespace user_id
    case PleromaIntegration.get_namespace_for_pleroma_account(account_id, conn.assigns.pleroma_token) do
      {:ok, user_id, _account_info} ->
        case PleromaIntegration.get_pleroma_account_info(user_id) do
          {:ok, stored_account_info} ->
            conn
            |> json(%{account: stored_account_info})

          {:error, :no_pleroma_account} ->
            # Fallback to current account info from token
            conn
            |> json(%{account: account_info})

          {:error, reason} ->
            Logger.error("Failed to get account info: #{inspect(reason)}")
            conn
            |> put_status(:bad_request)
            |> json(%{error: "Failed to get account info", details: inspect(reason)})
        end

      {:error, :namespace_not_found} ->
        # Return account info from token even if namespace doesn't exist
        conn
        |> json(%{account: account_info})

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Failed to resolve namespace", details: inspect(reason)})
    end
  end

  # Private helpers

  defp format_namespace_status(status, account_info, opts \\ []) do
    include_details = Keyword.get(opts, :include_details, false)

    base = %{
      user_id: status.user_id,
      tenant_id: status.tenant_id,
      did: Map.get(status, :did),
      identity_type: Map.get(status, :identity_type),
      status: status.health_status,
      started_at: status.started_at,
      pleroma_account: account_info
    }

    if include_details do
      Map.merge(base, %{
        services: status.services,
        resource_usage: status.resource_usage,
        config: Map.get(status, :config, %{})
      })
    else
      base
    end
  end
end
