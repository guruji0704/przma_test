defmodule AlemWeb.PleromaMockController do
  use AlemWeb, :controller
  require Logger

  # Mock OAuth app registration
  def register_app(conn, params) do
    client_id = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false) |> String.slice(0, 32)
    client_secret = :crypto.strong_rand_bytes(64) |> Base.url_encode64(padding: false)

    json(conn, %{
      id: client_id,
      client_id: client_id,
      client_secret: client_secret,
      name: params["client_name"] || "Test App",
      website: params["website"],
      redirect_uri: params["redirect_uris"] || "urn:ietf:wg:oauth:2.0:oob",
      vapid_key: nil
    })
  end

  # Mock OAuth token
  def get_token(conn, params) do
    grant_type = params["grant_type"] || params[:grant_type]

    case grant_type do
      "password" ->
        access_token = :crypto.strong_rand_bytes(64) |> Base.url_encode64(padding: false)
        json(conn, %{
          access_token: access_token,
          token_type: "Bearer",
          scope: params["scope"] || "read write follow push",
          created_at: DateTime.utc_now() |> DateTime.to_unix()
        })

      "authorization_code" ->
        access_token = :crypto.strong_rand_bytes(64) |> Base.url_encode64(padding: false)
        json(conn, %{
          access_token: access_token,
          token_type: "Bearer",
          scope: "read write follow push",
          created_at: DateTime.utc_now() |> DateTime.to_unix()
        })

      _ ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "unsupported_grant_type"})
    end
  end

  # Mock account registration
  def register_account(conn, params) do
    account_id = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false) |> String.slice(0, 16)

    json(conn, %{
      id: account_id,
      username: params["nickname"] || params[:nickname],
      acct: params["nickname"] || params[:nickname],
      display_name: params["fullname"] || params[:fullname] || params["nickname"] || params[:nickname],
      note: params["bio"] || params[:bio] || "",
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
    })
  end

  # Mock captcha
  def get_captcha(conn, _params) do
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    json(conn, %{
      token: token,
      answer_data: "ABCD1234",
      type: "image/png"
    })
  end

  # Mock delete account
  def delete_account(conn, _params) do
    json(conn, %{message: "Account deletion scheduled"})
  end

  # Mock disable account
  def disable_account(conn, _params) do
    json(conn, %{message: "Account disabled"})
  end

  # Mock MFA
  def get_mfa(conn, _params) do
    json(conn, %{
      enabled: false,
      backup_codes: [],
      totp: %{
        enabled: false,
        provisioning_uri: nil
      }
    })
  end
end




