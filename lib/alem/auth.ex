# =============================================================================
# Alem.Auth
# =============================================================================
# Authentication context module using Pleroma-compatible schemas.
#
# Based on Pleroma authentication patterns:
# Source: https://git.pleroma.social/pleroma/pleroma/src/branch/develop/lib/pleroma
# =============================================================================

  defmodule Alem.Auth do
    import Ecto.Query

    alias Alem.Repo

    # ─── Pleroma-style aliases ───────────────────────────────────────────────────
    alias Alem.Pleroma.User
    alias Alem.Pleroma.Web.OAuth.App
    alias Alem.Pleroma.Web.OAuth.Token
    alias Alem.Pleroma.Captcha
    alias Alem.DID
    # ────────────────────────────────────────────────────────────────────────────

    @moduledoc """
    Authentication context for PRZMA/ALEM system.

    Handles:
    - Captcha generation/verification (Pleroma.Captcha style)
    - User registration with automatic DID generation
    - OAuth app registration
    - Login / token creation
    - Token verification and revocation
    - DID management

    ## DID Generation Flow

    1. User registers → `register_user/1` inserts user record
    2. DID is immediately generated via `Alem.DID.generate(user.id)`
    3. DID stored in `users.did_id`
    4. One DID per user — never changes after creation
    """

    # ===========================================================================
    # CAPTCHA
    # Based on Pleroma.Captcha
    # ===========================================================================

    @doc "Generate a new captcha challenge."
    def generate_captcha do
      case Repo.insert(Captcha.changeset(%Captcha{}, %{})) do
        {:ok, captcha} -> {:ok, Captcha.to_response(captcha)}
        {:error, _} = err -> err
      end
    end

    @doc """
    Verify a captcha answer.
    Returns {:ok, :valid} | {:error, :invalid_captcha} | {:error, :wrong_captcha_answer}
    """
    def verify_captcha(nil, _answer), do: {:ok, :skipped}
    def verify_captcha("", _answer),  do: {:ok, :skipped}

    def verify_captcha(token, answer) do
      now = DateTime.utc_now()

      case Repo.one(
        from c in Captcha,
          where: c.token == ^token,
          where: c.used == false,
          where: c.expires_at > ^now
      ) do
        nil ->
          {:error, :invalid_captcha}

        challenge ->
          if String.downcase(challenge.answer) == String.downcase(to_string(answer)) do
            challenge
            |> Ecto.Changeset.change(used: true)
            |> Repo.update!()
            {:ok, :valid}
          else
            {:error, :wrong_captcha_answer}
          end
      end
    end

    # ===========================================================================
    # OAUTH APPS
    # Based on Pleroma.Web.OAuth.App
    # ===========================================================================

    @doc "Register a new OAuth application."
    def register_app(attrs) do
      %App{}
      |> App.register_changeset(attrs)
      |> Repo.insert()
    end

    @doc "Get an OAuth app by client_id."
    def get_app_by_client_id(nil), do: nil
    def get_app_by_client_id(client_id), do: Repo.get_by(App, client_id: client_id)

    @doc "Verify client_id + client_secret pair."
    def authenticate_client(client_id, client_secret) do
      case get_app_by_client_id(client_id) do
        nil -> {:error, :invalid_credentials}
        app ->
          if app.client_secret == client_secret, do: {:ok, app}, else: {:error, :invalid_credentials}
      end
    end

    # ===========================================================================
    # USERS + DID
    # ===========================================================================

    @doc """
    Register a new user and immediately generate their DID.

    Flow:
    1. Insert user record (nickname, email, password_hash)
    2. Generate DID: `did:przma:<sha256-fingerprint>`
    3. Store DID in `users.did_id`
    4. Return user with DID attached

    Returns {:ok, user_with_did} | {:error, changeset}
    """
    def register_user(attrs) do
      Repo.transaction(fn ->
        # Step 1: Insert user
        user = case %User{} |> User.registration_changeset(attrs) |> Repo.insert() do
          {:ok, u}   -> u
          {:error, cs} -> Repo.rollback(cs)
        end

        # Step 2: Generate DID using the user's DB-assigned ID
        did_id = DID.generate(user.id)

        # Step 3: Store DID
        user = case user |> User.did_changeset(did_id) |> Repo.update() do
          {:ok, u}   -> u
          {:error, cs} -> Repo.rollback(cs)
        end

        user
      end)
      |> case do
        {:ok, user}    -> {:ok, user}
        {:error, reason} -> {:error, reason}
      end
    end

    @doc "Get user by nickname. Pleroma: User.get_by_nickname/1"
    def get_user_by_nickname(nickname), do: Repo.get_by(User, nickname: nickname)

    @doc "Get user by ID."
    def get_user_by_id(id), do: Repo.get(User, id)

    @doc "Get user by DID."
    def get_user_by_did(did_id), do: Repo.get_by(User, did_id: did_id)

    @doc """
    Verify nickname + password.

    Includes timing attack prevention via `Pbkdf2.no_user_verify/0`.

    Based on Pleroma.Web.Auth.PleromaAuthenticator.checkpw/2
    Returns {:ok, user} | {:error, :invalid_credentials} | {:error, :account_disabled}
    """
    def authenticate_user(nickname, password) do
      user = get_user_by_nickname(nickname)

      cond do
        is_nil(user) ->
          Pbkdf2.no_user_verify()
          {:error, :invalid_credentials}

        not user.is_active ->
          {:error, :account_disabled}

        Pbkdf2.verify_pass(password, user.password_hash) ->
          {:ok, user}

        true ->
          {:error, :invalid_credentials}
      end
    end

    # ===========================================================================
    # TOKENS
    # Based on Pleroma.Web.OAuth.Token
    # ===========================================================================

    @doc "Create a new access token for a user."
    def create_token(user_id, app_id \\ nil, scopes \\ ["read", "write"]) do
      %Token{}
      |> Token.create_changeset(%{user_id: user_id, app_id: app_id, scopes: scopes})
      |> Repo.insert()
    end

    @doc """
    Verify an access token and return the associated user.

    Checks:
    1. Token exists in DB
    2. Not revoked (revoked_at IS NULL)
    3. Not expired (valid_until > NOW) — Pleroma field name: valid_until
    4. User is active

    Returns {:ok, user} | {:error, :invalid_token}
    """
    def verify_token(token_string) do
      now = NaiveDateTime.utc_now()

      result =
        Repo.one(
          from t in Token,
            join: u in User, on: t.user_id == u.id,
            where: t.token == ^token_string,
            where: is_nil(t.revoked_at),
            where: t.valid_until > ^now,
            where: u.is_active == true,
            select: u
        )

      case result do
        nil  -> {:error, :invalid_token}
        user -> {:ok, user}
      end
    end

    def revoke_token(token_string) do
      case Repo.get_by(Token, token: token_string) do
        nil   -> {:error, :not_found}
        token ->
          now = DateTime.utc_now() |> DateTime.truncate(:second)  # ← Add truncate
          token |> Ecto.Changeset.change(revoked_at: now) |> Repo.update()
      end
    end

    # In revoke_all_tokens function:
    def revoke_all_tokens(user_id) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)  # ← Add truncate
      from(t in Token, where: t.user_id == ^user_id, where: is_nil(t.revoked_at))
      |> Repo.update_all(set: [revoked_at: now])
    end

    @doc "Disable a user account (is_active = false)."
    def disable_user(user_id) do
      case Repo.get(User, user_id) do
        nil  -> {:error, :not_found}
        user -> user |> Ecto.Changeset.change(is_active: false) |> Repo.update()
      end
    end

    @doc "List all active tokens for a user."
    def list_user_tokens(user_id) do
      now = NaiveDateTime.utc_now()
      Repo.all(
        from t in Token,
          where: t.user_id == ^user_id,
          where: is_nil(t.revoked_at),
          where: t.valid_until > ^now,
          order_by: [desc: t.inserted_at]
      )
    end

    # ===========================================================================
    # COMBINED LOGIN
    # ===========================================================================

    @doc "Full login: authenticate + create token. Returns {:ok, token, user} | {:error, reason}"
    def login(nickname, password, client_id \\ nil) do
      with {:ok, user} <- authenticate_user(nickname, password) do
        app_id = case get_app_by_client_id(client_id) do
          nil -> nil
          app -> app.id
        end

        case create_token(user.id, app_id) do
          {:ok, token} -> {:ok, token, user}
          {:error, cs} -> {:error, cs}
        end
      end
    end

    # ===========================================================================
    # CLEANUP
    # ===========================================================================

    @doc "Delete expired captchas. Run periodically."
    def cleanup_expired_captchas do
      now = DateTime.utc_now()
      Repo.delete_all(from c in Captcha, where: c.expires_at < ^now)
    end

    @doc "Delete expired tokens. Run periodically."
    def cleanup_expired_tokens do
      now = DateTime.utc_now()
      Repo.delete_all(from t in Token, where: t.valid_until < ^now)
    end
  end
