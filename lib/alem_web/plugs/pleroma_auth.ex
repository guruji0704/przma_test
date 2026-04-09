defmodule AlemWeb.Plugs.PleromaAuth do
  @moduledoc """
  Plug for Pleroma OAuth token authentication

  Verifies Pleroma OAuth tokens and extracts account information.
  Adds `:pleroma_account` and `:pleroma_token` to conn.assigns.
  """

  import Plug.Conn
  import Phoenix.Controller
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    case extract_token(conn) do
      nil ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Missing or invalid Authorization header"})
        |> halt()

      token ->
        case verify_token(token) do
          {:ok, account_info} ->
            account_id = account_info["id"] || account_info[:id] ||
                        to_string(account_info["username"] || account_info[:username] || "unknown")

            conn
            |> assign(:pleroma_token, token)
            |> assign(:pleroma_account, account_info)
            |> assign(:pleroma_account_id, account_id)

          {:error, :invalid_token} ->
            conn
            |> put_status(:unauthorized)
            |> json(%{error: "Invalid Pleroma OAuth token"})
            |> halt()

          {:error, reason} ->
            Logger.error("Pleroma auth failed: #{inspect(reason)}")
            conn
            |> put_status(:unauthorized)
            |> json(%{error: "Authentication failed", details: inspect(reason)})
            |> halt()
        end
    end
  end

  # Extract token from Authorization header
  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      [header | _] when is_binary(header) ->
        case String.split(header, " ") do
          ["Bearer", token] -> token
          _ -> nil
        end
      _ -> nil
    end
  end

  # Verify token with Pleroma API


  # defp verify_token("test-token-123") do
  #   {:ok, %{"id" => "12345", "username" => "testuser", "acct" => "testuser"}}
  # end

  defp verify_token(token) do
    pleroma_base_url = Application.get_env(:alem, :pleroma, [])[:base_url] ||
      System.get_env("PLEROMA_BASE_URL") ||
      "http://localhost:4001"

    url = "#{pleroma_base_url}/api/v1/accounts/verify_credentials"
    headers = [
      {"Authorization", "Bearer #{token}"},
      {"Content-Type", "application/json"}
    ]

    case Req.get(url, headers: headers) do
      {:ok, %{status: 200, body: account_info}} ->
        parsed_info = parse_response_body(account_info)
        {:ok, parsed_info}

      {:ok, %{status: status}} ->
        Logger.error("Pleroma token verification failed: #{status}")
        {:error, :invalid_token}

      {:error, reason} ->
        Logger.error("Failed to verify Pleroma token: #{inspect(reason)}")
        {:error, :connection_failed}
    end
  end

  # Helper to parse response body
  defp parse_response_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp parse_response_body(body) when is_map(body), do: body
  defp parse_response_body(body), do: body
end
