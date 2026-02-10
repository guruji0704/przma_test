defmodule Alem.PleromaMockServer do
  @moduledoc """
  Simple mock Pleroma server for development.
  Run this as a separate process to mock Pleroma API endpoints.
  """
  use Plug.Router
  require Logger

  plug Plug.Parsers, parsers: [:urlencoded, :json], json_decoder: Jason
  plug :match
  plug :dispatch

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  def start_link(opts \\ []) do
    port = Keyword.get(opts, :port, 4001)
    Logger.info("Starting Pleroma mock server on port #{port}")

    # Start Bandit server
    Bandit.start_link(
      plug: __MODULE__,
      port: port,
      scheme: :http
    )
  end

  # OAuth app registration
  post "/api/v1/apps" do
    client_id = generate_id(32)
    client_secret = generate_secret()

    send_resp(conn, 201, Jason.encode!(%{
      id: client_id,
      client_id: client_id,
      client_secret: client_secret,
      name: conn.body_params["client_name"] || "Test App",
      website: conn.body_params["website"],
      redirect_uri: conn.body_params["redirect_uris"] || "urn:ietf:wg:oauth:2.0:oob",
      vapid_key: nil
    }))
  end

  # OAuth token
  post "/oauth/token" do
    grant_type = conn.body_params["grant_type"]

    case grant_type do
      "password" ->
        access_token = generate_secret()
        send_resp(conn, 200, Jason.encode!(%{
          access_token: access_token,
          token_type: "Bearer",
          scope: conn.body_params["scope"] || "read write follow push",
          created_at: DateTime.utc_now() |> DateTime.to_unix()
        }))

      "authorization_code" ->
        access_token = generate_secret()
        send_resp(conn, 200, Jason.encode!(%{
          access_token: access_token,
          token_type: "Bearer",
          scope: "read write follow push",
          created_at: DateTime.utc_now() |> DateTime.to_unix()
        }))

      _ ->
        send_resp(conn, 400, Jason.encode!(%{error: "unsupported_grant_type"}))
    end
  end

  # Account registration
  post "/api/account/register" do
    account_id = generate_id(16)
    nickname = conn.body_params["nickname"]

    send_resp(conn, 201, Jason.encode!(%{
      id: account_id,
      username: nickname,
      acct: nickname,
      display_name: conn.body_params["fullname"] || nickname,
      note: conn.body_params["bio"] || "",
      avatar: "",
      avatar_static: "",
      header: "",
      header_static: "",
      locked: false,
      bot: false,
      created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      fields: [],
      emojis: [],
      discoverable: true,
      moved: nil,
      suspended: false,
      limited: false
    }))
  end

  # Captcha
  get "/api/v1/pleroma/captcha" do
    token = generate_secret()
    send_resp(conn, 200, Jason.encode!(%{
      token: token,
      answer_data: "ABCD1234",
      type: "image/png"
    }))
  end

  # Delete account
  post "/api/pleroma/delete_account" do
    send_resp(conn, 200, Jason.encode!(%{message: "Account deletion scheduled"}))
  end

  # Disable account
  post "/api/pleroma/disable_account" do
    send_resp(conn, 200, Jason.encode!(%{message: "Account disabled"}))
  end

  # MFA
  get "/api/v1/pleroma/accounts/mfa" do
    send_resp(conn, 200, Jason.encode!(%{
      enabled: false,
      backup_codes: [],
      totp: %{
        enabled: false,
        provisioning_uri: nil
      }
    }))
  end

  # Root endpoint
  get "/" do
    send_resp(conn, 200, Jason.encode!(%{
      message: "Pleroma Mock Server",
      version: "1.0.0",
      endpoints: [
        "POST /api/v1/apps",
        "POST /oauth/token",
        "POST /api/account/register",
        "GET /api/v1/pleroma/captcha",
        "POST /api/pleroma/delete_account",
        "POST /api/pleroma/disable_account",
        "GET /api/v1/pleroma/accounts/mfa"
      ]
    }))
  end

  # Catch-all
  match _ do
    send_resp(conn, 404, Jason.encode!(%{error: "Not found", path: conn.request_path}))
  end

  defp generate_id(length) do
    :crypto.strong_rand_bytes(length)
    |> Base.url_encode64(padding: false)
    |> String.slice(0, length)
  end

  defp generate_secret do
    :crypto.strong_rand_bytes(64)
    |> Base.url_encode64(padding: false)
  end
end
