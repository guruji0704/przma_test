defmodule Alem.Repo.Migrations.CreatePleromaCompatAuthTables do
  use Ecto.Migration

  # ===========================================================================
  # Migration: Create auth tables with Pleroma-compatible field names
  # ===========================================================================
  #
  # Table and column names follow Pleroma's schema conventions:
  #   - users.nickname        (Pleroma uses nickname, not username)
  #   - users.name            (Pleroma uses name for display name)
  #   - oauth_tokens.valid_until  (Pleroma uses valid_until, not expires_at)
  #   - oauth_tokens.refresh_token (Pleroma supports refresh tokens)
  #   - oauth_apps.redirect_uris   (Pleroma uses redirect_uris, plural)
  #   - oauth_apps.trusted         (Pleroma has trusted flag)
  #
  # Based on Pleroma migrations:
  # Source: https://git.pleroma.social/pleroma/pleroma/src/branch/develop/lib/mix/tasks/pleroma
  # ===========================================================================

  def change do

    # ─────────────────────────────────────────────────────────────────────────
    # TABLE: users
    # Based on Pleroma.User schema
    # Source: https://git.pleroma.social/pleroma/pleroma/src/branch/develop/lib/pleroma/user.ex
    # ─────────────────────────────────────────────────────────────────────────
    create table(:users, primary_key: false) do
      add :id,            :string,  primary_key: true

      # Pleroma uses `nickname` not `username`
      add :nickname,      :string,  null: false

      # Pleroma uses `name` for display name
      add :name,          :string

      add :email,         :string,  null: false
      add :bio,           :string,  default: ""
      add :avatar,        :string

      # Password stored as hash — never plain text
      add :password_hash, :string

      # Pleroma flags
      add :is_active,     :boolean, default: true,  null: false
      add :is_admin,      :boolean, default: false, null: false
      add :is_moderator,  :boolean, default: false, null: false

      # Pleroma: local=true for users on this instance
      # local=false for federated users from other instances
      add :local,         :boolean, default: true,  null: false

      timestamps()
    end

    # Unique on nickname and email — same as Pleroma
    create unique_index(:users, [:nickname])
    create unique_index(:users, [:email])
    create index(:users, [:is_active])
    create index(:users, [:local])

    # ─────────────────────────────────────────────────────────────────────────
    # TABLE: oauth_apps
    # Based on Pleroma.Web.OAuth.App schema
    # Source: https://git.pleroma.social/pleroma/pleroma/src/branch/develop/lib/pleroma/web
    # ─────────────────────────────────────────────────────────────────────────
    create table(:oauth_apps, primary_key: false) do
      add :id,            :string, primary_key: true
      add :client_id,     :string, null: false
      add :client_secret, :string, null: false
      add :name,          :string, null: false

      # Pleroma uses `redirect_uris` (plural)
      add :redirect_uris, :string, default: "urn:ietf:wg:oauth:2.0:oob"

      # Pleroma stores scopes as array
      add :scopes,        {:array, :string}, default: ["read", "write"]

      add :website,       :string

      # Pleroma has trusted flag for first-party apps
      add :trusted,       :boolean, default: false

      timestamps()
    end

    create unique_index(:oauth_apps, [:client_id])

    # ─────────────────────────────────────────────────────────────────────────
    # TABLE: oauth_tokens
    # Based on Pleroma.Web.OAuth.Token schema
    # Source: https://git.pleroma.social/pleroma/pleroma/src/branch/develop/lib/pleroma/web
    #
    # KEY DIFFERENCE from our old schema:
    #   OLD: expires_at    (our name)
    #   NEW: valid_until   (Pleroma's name) ← changed to match Pleroma
    # ─────────────────────────────────────────────────────────────────────────
    create table(:oauth_tokens, primary_key: false) do
      add :id,            :string, primary_key: true

      # The Bearer access token
      add :token,         :string, null: false

      # Refresh token — Pleroma supports refresh tokens
      add :refresh_token, :string

      # Pleroma uses `valid_until` (not `expires_at`)
      add :valid_until,   :utc_datetime, null: false

      # Array of scopes this token grants
      add :scopes,        {:array, :string}, default: ["read", "write"]

      # NULL = active, has value = revoked (logged out)
      add :revoked_at,    :utc_datetime

      # Foreign keys
      add :user_id, references(:users, type: :string, on_delete: :delete_all)
      add :app_id,  references(:oauth_apps, type: :string, on_delete: :nilify_all)

      timestamps()
    end

    create unique_index(:oauth_tokens, [:token])
    create index(:oauth_tokens, [:user_id])
    create index(:oauth_tokens, [:valid_until])
    create index(:oauth_tokens, [:refresh_token])

    # ─────────────────────────────────────────────────────────────────────────
    # TABLE: captcha_challenges
    # Based on Pleroma.Captcha
    # Source: https://git.pleroma.social/pleroma/pleroma/src/branch/develop/lib/pleroma/captcha.ex
    #
    # Pleroma's captcha is GenServer-based (in memory).
    # We store in DB for persistence and multi-node support.
    # Response format: {type, token, answer_data, seconds_valid}
    # ─────────────────────────────────────────────────────────────────────────
    create table(:captcha_challenges, primary_key: false) do
      add :id,         :string, primary_key: true

      # Public token sent to client — used as lookup key
      add :token,      :string, null: false

      # The correct answer (we call it answer; Pleroma response calls it answer_data)
      add :answer,     :string, null: false

      # Expiry — Pleroma default: 300 seconds (5 minutes)
      add :expires_at, :utc_datetime, null: false

      # Prevents reuse of same captcha
      add :used,       :boolean, default: false, null: false

      timestamps()
    end

    create unique_index(:captcha_challenges, [:token])
    create index(:captcha_challenges, [:expires_at])

  end
end
