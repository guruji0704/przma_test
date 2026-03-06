defmodule AlemWeb.AuthController do
  use AlemWeb, :controller
  require Logger

  alias Alem.Auth
  alias Alem.Auth.OTP
  alias Alem.Session
  alias Alem.Pleroma.User
  alias Alem.Pleroma.Web.OAuth.Token
  alias Alem.DID

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
  #
  # Flow:
  #   1. Verify captcha
  #   2. Create user + DID
  #   3. Generate secure OTP (hashed in DB, plaintext only in email)
  #   4. Send OTP email via Alem.Auth.OTP
  #   5. Return user_id so client can POST /verify_email
  # ===========================================================================
  def register_account(conn, params) do
    captcha_token    = params["captcha_token"]
    captcha_solution = params["captcha_solution"]

    with :ok         <- verify_captcha_step(captcha_token, captcha_solution),
         user_attrs  =  build_user_attrs(params),
         {:ok, user} <- Auth.register_user(user_attrs) do

      # Generate secure OTP: stores hash in DB, emails plaintext
      case OTP.generate_and_send(user) do
        {:ok, _} ->
          Logger.info("[Auth] OTP sent to #{user.email} for user #{user.id}")

        {:error, reason} ->
          Logger.warning("[Auth] OTP send failed for #{user.id}: #{inspect(reason)}")
      end

      conn
      |> put_status(200)
      |> json(%{
        message:   "Registration successful. Check #{user.email} for your 6-digit verification code.",
        user_id:   user.id,
        email:     user.email,
        next_step: "POST /api/v1/account/verify_email with {user_id, code}"
      })
    else
      {:error, :invalid_captcha} ->
        conn |> put_status(400) |> json(%{error: "Invalid or expired captcha token"})

      {:error, :wrong_captcha_answer} ->
        conn |> put_status(400) |> json(%{error: "Wrong captcha answer"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn |> put_status(400) |> json(%{error: format_errors(changeset)})

      {:error, reason} ->
        conn |> put_status(400) |> json(%{error: to_string(reason)})
    end
  end

  # ===========================================================================
  # POST /api/v1/account/verify_email
  #
  # Body: { "user_id": "...", "code": "123456" }
  #
  # Security:
  #   - OTP is stored as Pbkdf2 hash — plaintext never persisted
  #   - Max 3 attempts before lockout
  #   - Expires in 10 minutes
  #   - Constant-time comparison via Pbkdf2.verify_pass
  # ===========================================================================
  def verify_email(conn, %{"user_id" => user_id, "code" => code}) do
    case Alem.Repo.get(User, user_id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "User not found"})

      %{is_verified: true} ->
        conn |> put_status(400) |> json(%{error: "Email already verified. You can log in."})

      user ->
        case OTP.verify(user, code) do
          {:ok, _verified_user} ->
            Logger.info("[Auth] ✅ Email verified for user #{user.id}")
            conn
            |> put_status(200)
            |> json(%{
              ok:        true,
              message:   "Email verified successfully. You can now log in.",
              user_id:   user.id,
              next_step: "POST /api/v1/oauth/token"
            })

          {:error, :max_attempts} ->
            Logger.warning("[Auth] Max OTP attempts for user #{user.id}")
            conn
            |> put_status(429)
            |> json(%{error: "Too many attempts. Request a new code via /resend_otp."})

          {:error, :expired} ->
            conn
            |> put_status(400)
            |> json(%{error: "Code expired. Use POST /api/v1/account/resend_otp to get a new one."})

          {:error, :invalid} ->
            remaining = max(0, 3 - (user.otp_attempts + 1))
            conn
            |> put_status(400)
            |> json(%{error: "Invalid code. #{remaining} attempt(s) remaining."})
        end
    end
  end

  def verify_email(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{error: "user_id and code are required"})
  end

  # ===========================================================================
  # POST /api/v1/account/resend_otp
  #
  # Body: { "user_id": "..." }
  #
  # Security:
  #   - Checks user exists and is not already verified
  #   - Rate limited (max 3 resends per hour via OTP module)
  #   - Generates a fresh hash, invalidates old code
  # ===========================================================================
  def resend_otp(conn, %{"user_id" => user_id}) do
    case Alem.Repo.get(User, user_id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "User not found"})

      %{is_verified: true} ->
        conn |> put_status(400) |> json(%{error: "Email already verified. You can log in."})

      user ->
        case OTP.generate_and_send(user) do
          {:ok, _} ->
            Logger.info("[Auth] OTP resent to #{user.email}")
            conn
            |> put_status(200)
            |> json(%{
              ok:      true,
              message: "New verification code sent to #{user.email}. Valid for 10 minutes."
            })

          {:error, :rate_limited} ->
            conn
            |> put_status(429)
            |> json(%{error: "Too many resend requests. Please wait before trying again."})

          {:error, reason} ->
            Logger.error("[Auth] Resend OTP failed for #{user.id}: #{inspect(reason)}")
            conn
            |> put_status(500)
            |> json(%{error: "Failed to send code. Please try again shortly."})
        end
    end
  end

  def resend_otp(conn, _params) do
    conn |> put_status(400) |> json(%{error: "user_id is required"})
  end

  # ===========================================================================
  # POST /api/v1/oauth/token
  # ===========================================================================
  def get_token(conn, params) do
    case params["grant_type"] do
      "password"           -> handle_password_grant(conn, params)
      "client_credentials" -> handle_client_credentials_grant(conn, params)
      _                    -> conn |> put_status(400) |> json(%{error: "unsupported_grant_type"})
    end
  end

  # ===========================================================================
  # GET /api/v1/accounts/verify_credentials
  # ===========================================================================
  def verify_credentials(conn, _params) do
    with {:ok, token} <- extract_bearer_token(conn),
         {:ok, user}  <- Auth.verify_token(token) do
      json(conn, render_account(user))
    else
      {:error, :missing_token} -> conn |> put_status(401) |> json(%{error: "Missing token"})
      {:error, :invalid_token} -> conn |> put_status(401) |> json(%{error: "Invalid or expired token"})
    end
  end

  # ===========================================================================
  # DELETE /oauth/token  — logout current token
  # ===========================================================================
  def revoke_token(conn, params) do
    token_string = params["token"] || extract_bearer_token_string(conn)

    case Auth.revoke_token(token_string) do
      {:ok, _}             -> json(conn, %{message: "Token revoked successfully"})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "Token not found"})
      {:error, _}          -> conn |> put_status(400) |> json(%{error: "Could not revoke token"})
    end
  end

  # ===========================================================================
  # GET /api/v1/accounts/did
  # ===========================================================================
  def get_did(conn, _params) do
    with {:ok, token} <- extract_bearer_token(conn),
         {:ok, user}  <- Auth.verify_token(token) do

      did_id = case user.did_id do
        nil ->
          new_did = DID.generate(user.id)
          user |> User.did_changeset(new_did) |> Alem.Repo.update!()
          new_did
        existing -> existing
      end

      json(conn, render_did(user.id, user.nickname, did_id))
    else
      {:error, :missing_token} -> conn |> put_status(401) |> json(%{error: "Missing token"})
      {:error, :invalid_token} -> conn |> put_status(401) |> json(%{error: "Invalid or expired token"})
    end
  end

  # ===========================================================================
  # GET /api/v1/sessions
  # ===========================================================================
  def list_sessions(conn, _params) do
    with {:ok, token} <- extract_bearer_token(conn),
         {:ok, user}  <- Auth.verify_token(token) do
      sessions = Session.list_active(user.id)
      json(conn, %{sessions: Enum.map(sessions, &render_session/1)})
    else
      {:error, :missing_token} -> conn |> put_status(401) |> json(%{error: "Missing token"})
      {:error, :invalid_token} -> conn |> put_status(401) |> json(%{error: "Invalid or expired token"})
    end
  end

  # ===========================================================================
  # DELETE /api/v1/sessions/:id
  # ===========================================================================
  def revoke_session(conn, %{"id" => session_id}) do
    with {:ok, token} <- extract_bearer_token(conn),
         {:ok, user}  <- Auth.verify_token(token) do
      case Session.revoke(session_id, user.id) do
        {:ok, _}             -> json(conn, %{message: "Session revoked"})
        {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "Session not found"})
      end
    else
      {:error, :missing_token} -> conn |> put_status(401) |> json(%{error: "Missing token"})
      {:error, :invalid_token} -> conn |> put_status(401) |> json(%{error: "Invalid or expired token"})
    end
  end

  # ===========================================================================
  # DELETE /api/v1/sessions  — logout from ALL devices
  # ===========================================================================
  def revoke_all_sessions(conn, _params) do
    with {:ok, token} <- extract_bearer_token(conn),
         {:ok, user}  <- Auth.verify_token(token) do
      Session.revoke_all(user.id)
      Auth.revoke_all_tokens(user.id)
      json(conn, %{message: "Logged out from all devices"})
    else
      {:error, :missing_token} -> conn |> put_status(401) |> json(%{error: "Missing token"})
      {:error, :invalid_token} -> conn |> put_status(401) |> json(%{error: "Invalid or expired token"})
    end
  end

  # ===========================================================================
  # POST /api/v1/pleroma/delete_account
  # ===========================================================================
  def delete_account(conn, params) do
    with {:ok, token_string} <- extract_bearer_token(conn),
         {:ok, user}         <- Auth.verify_token(token_string),
         {:ok, _}            <- Auth.authenticate_user(user.nickname, params["password"]) do
      Auth.revoke_all_tokens(user.id)
      Session.revoke_all(user.id)
      json(conn, %{status: "success"})
    else
      {:error, :missing_token}       -> conn |> put_status(401) |> json(%{error: "Missing token"})
      {:error, :invalid_token}       -> conn |> put_status(401) |> json(%{error: "Invalid token"})
      {:error, :invalid_credentials} -> conn |> put_status(403) |> json(%{error: "Invalid password"})
      {:error, reason}               -> conn |> put_status(400) |> json(%{error: inspect(reason)})
    end
  end

  # ===========================================================================
  # POST /api/v1/pleroma/disable_account
  # ===========================================================================
  def disable_account(conn, params) do
    with {:ok, token_string} <- extract_bearer_token(conn),
         {:ok, user}         <- Auth.verify_token(token_string),
         {:ok, _}            <- Auth.authenticate_user(user.nickname, params["password"]) do
      Auth.disable_user(user.id)
      Session.revoke_all(user.id)
      json(conn, %{status: "success"})
    else
      {:error, :missing_token}       -> conn |> put_status(401) |> json(%{error: "Missing token"})
      {:error, :invalid_token}       -> conn |> put_status(401) |> json(%{error: "Invalid token"})
      {:error, :invalid_credentials} -> conn |> put_status(403) |> json(%{error: "Invalid password"})
      {:error, reason}               -> conn |> put_status(400) |> json(%{error: inspect(reason)})
    end
  end

  # ===========================================================================
  # GET /api/v1/pleroma/accounts/mfa
  # ===========================================================================
  def get_mfa(conn, _params) do
    json(conn, %{
      enabled: false,
      backup_codes: [],
      totp: %{enabled: false, provisioning_uri: nil}
    })
  end


alias Alem.Auth.PasswordReset

# ===========================================================================
# POST /api/v1/account/forgot_password
# Body: { "email": "mani@example.com" }
# ===========================================================================
def forgot_password(conn, %{"email" => email}) do
  # Always return same response — prevents email enumeration
  case PasswordReset.request_reset(email) do
    {:ok, :sent} ->
      conn
      |> put_status(200)
      |> json(%{
        ok:      true,
        message: "If that email is registered, a reset link has been sent. Check your inbox.",
        note:    "Link expires in 15 minutes."
      })

    {:error, :rate_limited} ->
      conn
      |> put_status(429)
      |> json(%{error: "Please wait 60 seconds before requesting another reset link."})

    {:error, _} ->
      # Generic message — don't expose internal errors
      conn
      |> put_status(200)
      |> json(%{
        ok:      true,
        message: "If that email is registered, a reset link has been sent. Check your inbox."
      })
  end
end

def forgot_password(conn, _params) do
  conn |> put_status(400) |> json(%{error: "email is required"})
end

# ===========================================================================
# POST /api/v1/account/reset_password
# Body: { "user_id": "...", "token": "...", "password": "...", "password_confirmation": "..." }
# ===========================================================================
def reset_password(conn, params) do
  user_id              = params["user_id"]
  token                = params["token"]
  new_password         = params["password"]
  password_confirmation = params["password_confirmation"]

  cond do
    is_nil(user_id) or is_nil(token) or is_nil(new_password) ->
      conn |> put_status(400) |> json(%{error: "user_id, token, and password are required"})

    String.length(new_password) < 8 ->
      conn |> put_status(400) |> json(%{error: "Password must be at least 8 characters"})

    new_password != password_confirmation ->
      conn |> put_status(400) |> json(%{error: "Passwords do not match"})

    true ->
      case PasswordReset.reset_password(user_id, token, new_password) do
        {:ok, _user} ->
          Logger.info("[Auth] ✅ Password reset successful for user #{user_id}")
          conn
          |> put_status(200)
          |> json(%{
            ok:        true,
            message:   "Password reset successfully. You can now log in.",
            next_step: "POST /api/v1/oauth/token"
          })

        {:error, :max_attempts} ->
          conn
          |> put_status(429)
          |> json(%{error: "Too many attempts. Request a new reset link."})

        {:error, :expired} ->
          conn
          |> put_status(400)
          |> json(%{error: "Reset link expired. Request a new one via /forgot_password."})

        {:error, :invalid} ->
          conn
          |> put_status(400)
          |> json(%{error: "Invalid reset link. Check the link in your email."})

        {:error, :not_found} ->
          conn
          |> put_status(404)
          |> json(%{error: "No password reset was requested for this account."})

        {:error, _} ->
          conn
          |> put_status(500)
          |> json(%{error: "Something went wrong. Please try again."})
      end
  end
end


  # ===========================================================================
  # Private helpers
  # ===========================================================================

  defp handle_password_grant(conn, params) do
    nickname  = params["username"]
    password  = params["password"]
    client_id = params["client_id"]
    conn_info = Session.conn_info(conn)

    case Auth.login(nickname, password, client_id) do
      {:ok, token, user} ->
        if !user.is_verified do
          conn
          |> put_status(403)
          |> json(%{
            error:     "Email not verified. Check your inbox for the 6-digit code.",
            user_id:   user.id,
            email:     user.email,
            next_step: "POST /api/v1/account/verify_email with {user_id, code}"
          })
        else
          Session.create(user.id, conn_info)

          json(conn, %{
            access_token:  token.token,
            token_type:    "Bearer",
            scope:         Enum.join(token.scopes, " "),
            created_at:    token.inserted_at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(),
            expires_in:    Token.expires_in(token),
            refresh_token: token.refresh_token,
            me:            user.nickname,
            did:           user.did_id
          })
        end

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

  defp render_did(user_id, nickname, did_id) do
    {:ok, fingerprint} = DID.fingerprint(did_id)
    %{
      user_id:       user_id,
      nickname:      nickname,
      did:           did_id,
      did_method:    "przma",
      fingerprint:   fingerprint,
      namespace_key: DID.namespace_key(did_id),
      description:   "Your unique decentralized identifier. One per user, never changes."
    }
  end

  defp render_session(s) do
    %{
      id:             s.id,
      device:         s.device || "unknown",
      ip_address:     s.ip_address || "unknown",
      user_agent:     s.user_agent || "",
      last_active_at: s.last_active_at,
      created_at:     s.inserted_at
    }
  end

  defp extract_bearer_token(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> {:ok, token}
      _                        -> {:error, :missing_token}
    end
  end

  defp extract_bearer_token_string(conn) do
    case extract_bearer_token(conn) do
      {:ok, token} -> token
      _            -> nil
    end
  end

  defp parse_scopes(nil),                  do: ["read", "write"]
  defp parse_scopes(s) when is_list(s),    do: s
  defp parse_scopes(s) when is_binary(s),  do: String.split(s, " ", trim: true)

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
end
