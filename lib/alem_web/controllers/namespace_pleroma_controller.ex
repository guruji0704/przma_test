defmodule AlemWeb.NamespacePleromaController do
  use AlemWeb, :controller
  require Logger

  alias Alem.Namespace
  alias Alem.Namespace.PleromaIntegration

  @doc """
  Create or get namespace for authenticated Pleroma user
  POST /api/namespaces/pleroma
  """
  def create_or_get(conn, _params) do
    # Get OAuth token from Authorization header
    auth_header = Plug.Conn.get_req_header(conn, "authorization")

    case extract_token(auth_header) do
      nil ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Missing or invalid Authorization header"})

      token ->
        # First verify token to get account ID
        case verify_and_get_account_id(token) do
          {:ok, account_id} ->
            case PleromaIntegration.ensure_namespace_for_pleroma_account(account_id, token) do
              {:ok, user_id, account_info} ->
                # Get namespace status
                case Namespace.status(user_id) do
                  {:ok, status} ->
                    conn
                    |> put_status(:ok)
                    |> json(%{
                      namespace: %{
                        user_id: user_id,
                        tenant_id: status.tenant_id,
                        status: status.health_status,
                        started_at: status.started_at,
                        pleroma_account: account_info
                      }
                    })

                  error ->
                    conn
                    |> put_status(:internal_server_error)
                    |> json(%{error: "Failed to get namespace status", details: inspect(error)})
                end

              {:error, :invalid_token} ->
                conn
                |> put_status(:unauthorized)
                |> json(%{error: "Invalid Pleroma OAuth token"})

              {:error, reason} ->
                conn
                |> put_status(:bad_request)
                |> json(%{error: "Failed to create namespace", details: inspect(reason)})
            end

          {:error, :invalid_token} ->
            conn
            |> put_status(:unauthorized)
            |> json(%{error: "Invalid Pleroma OAuth token"})

          {:error, reason} ->
            conn
            |> put_status(:bad_request)
            |> json(%{error: "Failed to verify token", details: inspect(reason)})
        end
    end
  end

  @doc """
  Get namespace for authenticated Pleroma user
  GET /api/namespaces/pleroma
  """
  def get(conn, _params) do
    auth_header = Plug.Conn.get_req_header(conn, "authorization")

    case extract_token(auth_header) do
      nil ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Missing or invalid Authorization header"})

      token ->
        case verify_and_get_account_id(token) do
          {:ok, account_id} ->
            case PleromaIntegration.get_namespace_for_pleroma_account(account_id, token) do
              {:ok, user_id, account_info} ->
                case Namespace.status(user_id) do
                  {:ok, status} ->
                    conn
                    |> json(%{
                      namespace: %{
                        user_id: user_id,
                        tenant_id: status.tenant_id,
                        status: status.health_status,
                        started_at: status.started_at,
                        services: status.services,
                        resource_usage: status.resource_usage,
                        pleroma_account: account_info
                      }
                    })

                  error ->
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
                conn
                |> put_status(:bad_request)
                |> json(%{error: "Failed to get namespace", details: inspect(reason)})
            end

          {:error, :invalid_token} ->
            conn
            |> put_status(:unauthorized)
            |> json(%{error: "Invalid Pleroma OAuth token"})

          {:error, reason} ->
            conn
            |> put_status(:bad_request)
            |> json(%{error: "Failed to verify token", details: inspect(reason)})
        end
    end
  end

  @doc """
  Sync namespace with Pleroma
  POST /api/namespaces/pleroma/sync
  """
  def sync(conn, params) do
    auth_header = Plug.Conn.get_req_header(conn, "authorization")

    case extract_token(auth_header) do
      nil ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Missing or invalid Authorization header"})

      token ->
        user_id = get_user_id_from_token(token)
        sync_mode = params["sync_mode"] || "metadata_only"

        opts = [
          sync_mode: String.to_atom(sync_mode)
        ]

        case PleromaIntegration.sync_namespace_with_pleroma(user_id, token, opts) do
          {:ok, sync_result} ->
            conn
            |> json(%{
              message: "Sync completed",
              result: sync_result
            })

          {:error, reason} ->
            conn
            |> put_status(:bad_request)
            |> json(%{error: "Sync failed", details: inspect(reason)})
        end
    end
  end

  @doc """
  Get Pleroma account info for namespace
  GET /api/namespaces/pleroma/account
  """
  def get_account_info(conn, _params) do
    auth_header = Plug.Conn.get_req_header(conn, "authorization")

    case extract_token(auth_header) do
      nil ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Missing or invalid Authorization header"})

      token ->
        user_id = get_user_id_from_token(token)

        case PleromaIntegration.get_pleroma_account_info(user_id) do
          {:ok, account_info} ->
            conn
            |> json(%{account: account_info})

          {:error, :no_pleroma_account} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: "No Pleroma account associated with this namespace"})

          {:error, reason} ->
            conn
            |> put_status(:bad_request)
            |> json(%{error: "Failed to get account info", details: inspect(reason)})
        end
    end
  end

  # Private helpers

  defp extract_token([header | _]) when is_binary(header) do
    case String.split(header, " ") do
      ["Bearer", token] -> token
      _ -> nil
    end
  end

  defp extract_token(_), do: nil

  defp get_user_id_from_token(token) do
    case verify_and_get_account_id(token) do
      {:ok, account_id} -> account_id
      _ -> "unknown"
    end
  end

  defp verify_and_get_account_id(token) do
    pleroma_base_url = Application.get_env(:alem, :pleroma, [])[:base_url] ||
      System.get_env("PLEROMA_BASE_URL") ||
      "http://localhost:4001"

    url = "#{pleroma_base_url}/api/v1/accounts/verify_credentials"
    headers = [{"Authorization", "Bearer #{token}"}, {"Content-Type", "application/json"}]

    case Req.get(url, headers: headers) do
      {:ok, %{status: 200, body: account_info}} ->
        parsed_info = parse_response_body(account_info)
        account_id = parsed_info["id"] || parsed_info[:id] || to_string(parsed_info["username"] || parsed_info[:username])
        {:ok, account_id}

      {:ok, %{status: status}} ->
        Logger.error("Pleroma token verification failed: #{status}")
        {:error, :invalid_token}

      {:error, reason} ->
        Logger.error("Failed to verify Pleroma token: #{inspect(reason)}")
        {:error, :connection_failed}
    end
  end

  # Helper to parse response body - handles both string and map responses
  defp parse_response_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp parse_response_body(body) when is_map(body), do: body
  defp parse_response_body(body), do: body
end
