# =============================================================================
# Alem.Pleroma.Web.OAuth.Token
# =============================================================================
# Based on Pleroma.Web.OAuth.Token
# Source: https://git.pleroma.social/pleroma/pleroma/src/branch/develop/lib/pleroma/web
#
# Pleroma uses `valid_until` (not `expires_at`) for token expiry.
# Pleroma also has `refresh_token` support.
# We follow those exact field names for compatibility.
# =============================================================================

defmodule Alem.Pleroma.Web.OAuth.Token do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Alem.Repo

  # Alias for giving credit — mirrors Pleroma module naming
  # Based on Pleroma.Web.OAuth.Token
  # Source: https://git.pleroma.social/pleroma/pleroma/src/branch/develop/lib/pleroma/web

  @moduledoc """
  OAuth Token schema.

  Field names match Pleroma.Web.OAuth.Token for API compatibility.
  - `token`         — the Bearer access token
  - `refresh_token` — used to get a new token without re-login
  - `valid_until`   — expiry datetime (Pleroma uses this name, not expires_at)
  - `scopes`        — array of scope strings

  Based on Pleroma (AGPL-3.0): https://git.pleroma.social/pleroma/pleroma
  """

  # Token lives for 30 days (in seconds)
  # Pleroma default: 600 seconds for auth codes, longer for access tokens
  @token_valid_seconds 30 * 24 * 60 * 60

  @primary_key {:id, :string, autogenerate: false}

  schema "oauth_tokens" do
    # The actual Bearer token string — 88 chars (64 random bytes → base64)
    field :token,         :string

    # Refresh token — allows getting new access token without password
    # Pleroma supports refresh tokens; we generate one but don't expose it yet
    field :refresh_token, :string

    # Pleroma uses `valid_until` for expiry (NOT `expires_at`)
    # This is the key naming difference from our previous implementation
    field :valid_until,   :utc_datetime

    # Array of scopes this token grants
    # e.g. ["read", "write"] or ["read"]
    field :scopes,        {:array, :string}, default: ["read", "write"]

    # revoked_at: NULL = active, has value = revoked (logged out)
    # Pleroma uses a different approach but we keep this for simplicity
    field :revoked_at,    :utc_datetime

    # Foreign keys
    belongs_to :user, Alem.Pleroma.User,
      type: :string,
      foreign_key: :user_id

    belongs_to :app, Alem.Pleroma.Web.OAuth.App,
      type: :string,
      foreign_key: :app_id

    timestamps()
  end

  @doc """
  Changeset for creating a new OAuth token.

  Based on Pleroma.Web.OAuth.Token.create_token/3
  Source: https://git.pleroma.social/pleroma/pleroma/src/branch/develop/lib/pleroma/web
  """
  def create_changeset(token, attrs) do
    token
    |> cast(attrs, [:user_id, :app_id, :scopes])
    |> validate_required([:user_id])
    |> put_id()
    |> put_token()
    |> put_refresh_token()
    |> put_valid_until()
  end

  @doc """
  Check if token is still valid.

  Pleroma: Token.is_expired?/1
  Source: https://git.pleroma.social/pleroma/pleroma/src/branch/develop/lib/pleroma/web
  """
  def is_expired?(%__MODULE__{valid_until: valid_until}) do
    DateTime.compare(DateTime.utc_now(), valid_until) == :gt
  end

  @doc """
  Check if token has been revoked.
  """
  def is_revoked?(%__MODULE__{revoked_at: revoked_at}) do
    not is_nil(revoked_at)
  end

  @doc """
  Get token validity in seconds from now.
  Used in OAuth response: expires_in field.
  """
  def expires_in(%__MODULE__{valid_until: valid_until}) do
    now = NaiveDateTime.utc_now()
    max(0, NaiveDateTime.diff(valid_until, now, :second))
  end

  # -------------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------------

  defp put_id(changeset) do
    id =
      :crypto.strong_rand_bytes(16)
      |> Base.url_encode64(padding: false)
      |> String.slice(0, 20)

    put_change(changeset, :id, id)
  end

  # Generates the Bearer access token
  # 64 random bytes → base64 = 88 character string
  # Pleroma uses similar approach
  defp put_token(changeset) do
    token =
      :crypto.strong_rand_bytes(64)
      |> Base.url_encode64(padding: false)

    put_change(changeset, :token, token)
  end

  # Generates refresh token
  # Pleroma also generates refresh tokens alongside access tokens
  defp put_refresh_token(changeset) do
    refresh_token =
      :crypto.strong_rand_bytes(32)
      |> Base.url_encode64(padding: false)

    put_change(changeset, :refresh_token, refresh_token)
  end

  # Sets valid_until = NOW + 30 days
  # Pleroma calls this field `valid_until`
  defp put_valid_until(changeset) do
    valid_until =
      DateTime.utc_now()
      |> DateTime.add(@token_valid_seconds, :second)
      |> DateTime.truncate(:second)

    put_change(changeset, :valid_until, valid_until)
  end
end
