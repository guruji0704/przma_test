defmodule AlemWeb.AuthController do
  use AlemWeb, :controller

  alias Alem.Auth
  alias Alem.Pleroma.User
  alias Alem.Pleroma.Web.OAuth.Token
  alias Alem.DID
  alias Alem.Namespace

  # ===========================================================================
  # GET /api/v1/pleroma/captcha
  # ===========================================================================
  def get_captcha(conn, _params) do
    case Auth.generate_captcha() do
      {:ok, captcha} -> json(conn, captcha)
      {:error, _}    -> conn |> put_status(500) |> json(%{error: "Failed to generate captcha"})
    end
  end

  # ===========================================================================
  # POST /api/v1/apps
  # ===========================================================================
  def register_app(conn, params) do
    attrs = %{
      name:          params["client_name"],
      redirect_uris: params["redirect_uris"] || "urn:ietf:wg:oauth:2.0:oob",
      scopes:        parse_scopes(params["scopes"]),
      website:       params["website"]
    }

    case Auth.register_app(attrs) do
      {:ok, app} ->
        json(conn, %{
          id:            app.id,
          name:          app.name,
          website:       app.website,
          redirect_uri:  app.redirect_uris,
          client_id:     app.client_id,
          client_secret: app.client_secret,
          vapid_key:     nil
        })

      {:error, changeset} ->
        conn |> put_status(422) |> json(%{error: format_errors(changeset)})
    end
  end

  # ===========================================================================
  # POST /api/v1/account/register
  # ===========================================================================
  def register_account(conn, params) do
    captcha_token    = params["captcha_token"]
    captcha_solution = params["captcha_solution"]

    with :ok         <- verify_captcha_step(captcha_token, captcha_solution),
         user_attrs  = build_user_attrs(params),
         {:ok, user} <- Auth.register_user(user_attrs),
         {:ok, namespace} <- Namespace.create_for_user(user) do

      namespace_key = DID.namespace_key(user.did_id)

      conn
      |> put_status(200)
      |> json(%{
        account: render_account(user),
        did: user.did_id,
        namespace: %{
          id: namespace_key,
          created: true
        },
        sync_config: %{
          sqld_url: "http://172.235.17.68:8080",
          s3_bucket: "perkeep",
          s3_prefix: "user/#{namespace_key}/"
        }
      })
    else
      {:error, :invalid_captcha} ->
        conn
        |> put_status(400)
        |> json(%{error: "Invalid or expired captcha token"})

      {:error, :wrong_captcha_answer} ->
        conn
        |> put_status(400)
        |> json(%{error: "Wrong captcha answer"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(400)
        |> json(%{error: format_changeset_errors(changeset)})

      {:error, reason} ->
        conn
        |> put_status(400)
        |> json(%{error: "Registration failed: #{inspect(reason)}"})
    end
  end

  # ===========================================================================
  # POST /oauth/token
  # ===========================================================================
  def get_token(conn, params) do
    case params["grant_type"] do
      "password"           -> handle_password_grant(conn, params)
      "client_credentials" -> handle_client_credentials_grant(conn, params)
      _                    -> conn |> put_status(400) |> json(%{error: "unsupported_grant_type"})
    end
  end

  # ===========================================================================
  # Private helpers
  # ===========================================================================

  defp handle_password_grant(conn, params) do
    nickname  = params["username"]
    password  = params["password"]
    client_id = params["client_id"]

    case Auth.login(nickname, password, client_id) do
      {:ok, token, user} ->
        # Generate sync config
        namespace_key = DID.namespace_key(user.did_id)
        sync_config = %{
          sqld_url: "http://172.235.17.68:8080",
          s3_bucket: "perkeep",
          s3_prefix: "user/#{namespace_key}/"
        }

        json(conn, %{
          access_token:  token.token,
          token_type:    "Bearer",
          scope:         Enum.join(token.scopes, " "),
          created_at:    token.inserted_at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(),
          expires_in:    Token.expires_in(token),
          refresh_token: token.refresh_token,
          me:            user.nickname,
          did:           user.did_id,
          # Added for Tauri client
          sync_config:   sync_config,
          account:       render_account(user)
        })

      {:error, :invalid_credentials} ->
        conn |> put_status(401) |> json(%{error: "Invalid nickname or password"})

      {:error, :account_disabled} ->
        conn |> put_status(403) |> json(%{error: "Account is disabled"})

      {:error, _} ->
        conn |> put_status(400) |> json(%{error: "Login failed"})
    end
  end

  defp handle_client_credentials_grant(conn, params) do
    case Auth.authenticate_client(params["client_id"], params["client_secret"]) do
      {:ok, _app} ->
        case Auth.create_token(nil, nil) do
          {:ok, token} ->
            json(conn, %{
              access_token: token.token,
              token_type:   "Bearer",
              scope:        Enum.join(token.scopes, " "),
              created_at:   token.inserted_at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()
            })

          {:error, _} ->
            conn |> put_status(400) |> json(%{error: "Could not create token"})
        end

      {:error, :invalid_credentials} ->
        conn |> put_status(401) |> json(%{error: "Invalid client credentials"})
    end
  end

  defp verify_captcha_step(token, solution) do
    case Auth.verify_captcha(token, solution) do
      {:ok, _}         -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_user_attrs(params) do
    %{
      nickname: params["nickname"],
      email:    params["email"],
      password: params["password"],
      name:     params["fullname"] || params["nickname"],
      bio:      params["bio"]
    }
  end

  defp render_account(%User{} = user) do
    %{
      id:           user.id,
      username:     user.nickname,
      acct:         user.nickname,
      display_name: user.name || user.nickname,
      note:         user.bio || "",
      avatar:       user.avatar || "",
      created_at:   NaiveDateTime.to_iso8601(user.inserted_at) <> "Z",
      locked:       false,
      bot:          false,
      did:          user.did_id,
      pleroma: %{
        is_admin:     user.is_admin,
        is_moderator: user.is_moderator,
        is_active:    user.is_active
      }
    }
  end

  defp parse_scopes(nil), do: ["read", "write"]
  defp parse_scopes(scopes) when is_list(scopes), do: scopes
  defp parse_scopes(scopes) when is_binary(scopes) do
    String.split(scopes, " ", trim: true)
  end

  defp format_errors(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, messages} -> "#{field}: #{Enum.join(messages, ", ")}" end)
    |> Enum.join("; ")
  end

  defp format_changeset_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, messages} ->
      "#{field}: #{Enum.join(messages, ", ")}"
    end)
    |> Enum.join("; ")
  end
end
