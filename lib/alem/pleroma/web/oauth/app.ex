# =============================================================================
# Alem.Pleroma.Web.OAuth.App
# =============================================================================
# Based on Pleroma.Web.OAuth.App
# Source: https://git.pleroma.social/pleroma/pleroma/src/branch/develop/lib/pleroma/web
#
# Follows Pleroma's OAuth.App schema exactly so that any client that works
# with Pleroma's /api/v1/apps endpoint will work with ours too.
#
# Pleroma fields used: client_id, client_secret, name, redirect_uris,
#                      scopes, website, trusted
# =============================================================================

defmodule Alem.Pleroma.Web.OAuth.App do
  use Ecto.Schema
  import Ecto.Changeset

  @moduledoc """
  OAuth Application schema.

  Matches Pleroma.Web.OAuth.App field structure for API compatibility.
  Based on Pleroma (AGPL-3.0): https://git.pleroma.social/pleroma/pleroma
  """

  @primary_key {:id, :string, autogenerate: false}

  schema "oauth_apps" do
    # Pleroma uses `client_id` — a public identifier for the app
    field :client_id,     :string

    # Pleroma uses `client_secret` — private key for the app
    field :client_secret, :string

    # App name shown to users during OAuth consent
    field :name,          :string

    # Pleroma uses `redirect_uris` (note: plural, Pleroma stores as string)
    # "urn:ietf:wg:oauth:2.0:oob" = show token on screen (out-of-band)
    field :redirect_uris, :string

    # Scopes: "read", "write", "read write follow push"
    field :scopes,        {:array, :string}, default: ["read", "write"]

    field :website,       :string

    # Pleroma has `trusted` flag — trusted apps skip consent screen
    field :trusted,       :boolean, default: false

    timestamps()
  end

  @doc """
  Changeset for registering a new OAuth app via POST /api/v1/apps

  Based on Pleroma.Web.OAuth.App.register_changeset/2
  Source: https://git.pleroma.social/pleroma/pleroma/src/branch/develop/lib/pleroma/web
  """
  def register_changeset(app, attrs) do
    app
    |> cast(attrs, [:name, :redirect_uris, :scopes, :website, :trusted])
    |> validate_required([:name, :redirect_uris])
    |> validate_length(:name, min: 1, max: 255)
    |> put_client_credentials()
  end

  # -------------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------------

  # Generates client_id and client_secret for the app
  # Pleroma uses random tokens; we follow the same approach
  defp put_client_credentials(changeset) do
    # client_id: 43 chars (32 random bytes → base64)
    client_id =
      :crypto.strong_rand_bytes(32)
      |> Base.url_encode64(padding: false)

    # client_secret: 86 chars (64 random bytes → base64) — longer = more secure
    client_secret =
      :crypto.strong_rand_bytes(64)
      |> Base.url_encode64(padding: false)

    changeset
    |> put_change(:id, client_id)
    |> put_change(:client_id, client_id)
    |> put_change(:client_secret, client_secret)
  end
end
