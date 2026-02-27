# =============================================================================
# Alem.Pleroma.User
# =============================================================================
# Based on Pleroma.User
# Source: https://git.pleroma.social/pleroma/pleroma/src/branch/develop/lib/pleroma/user.ex
#
# Key addition: `did_id` field — Decentralized Identifier
# One DID per user. Generated at registration. Never changes.
# =============================================================================

defmodule Alem.Pleroma.User do
  use Ecto.Schema
  import Ecto.Changeset

  @moduledoc """
  Schema for users.

  Field names follow Pleroma.User conventions for API compatibility.
  Based on Pleroma (AGPL-3.0): https://git.pleroma.social/pleroma/pleroma

  ## DID Field

  `did_id` — Decentralized Identifier. Format: `did:przma:<fingerprint>`
  Generated at registration via `Alem.DID.generate/1`.
  Used as the root identity for namespace creation.
  """

  @primary_key {:id, :string, autogenerate: false}

  schema "users" do
    # Pleroma uses `nickname` (not `username`)
    field :nickname,       :string

    # Pleroma uses `name` for display name
    field :name,           :string

    field :email,          :string
    field :bio,            :string

    # Pbkdf2 password hash (Pleroma uses Argon2, we use Pbkdf2 — Windows compatible)
    field :password_hash,  :string

    # Virtual field — never stored, only used during registration
    field :password,       :string, virtual: true

    # Pleroma flags
    field :is_active,      :boolean, default: true
    field :is_admin,       :boolean, default: false
    field :is_moderator,   :boolean, default: false

    # Federation flag (local = on this instance)
    field :local,          :boolean, default: true

    field :avatar,         :string

    # ─── DID (Decentralized Identifier) ─────────────────────────────────────
    # Format: "did:przma:<base64url-sha256-fingerprint>"
    # Generated once at registration. Never changes.
    # One DID per user. NULL for users created before DID support was added.
    # This is the root identity for namespace creation.
    # See: lib/alem/did.ex
    field :did_id,         :string
    # ────────────────────────────────────────────────────────────────────────

    timestamps()
  end

  @doc """
  Changeset for creating a new user.
  Password is validated and hashed. DID is set externally after insert.

  Based on Pleroma.User.registration_changeset/2
  """
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:nickname, :email, :password, :name, :bio, :avatar])
    |> validate_required([:nickname, :email, :password])
    |> validate_length(:nickname, min: 1, max: 100)
    |> validate_format(:nickname, ~r/^[a-zA-Z0-9_\-.]+$/,
        message: "only letters, numbers, underscore, dash, dot allowed")
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+\.[^\s]+$/,
        message: "must be a valid email")
    |> validate_length(:password, min: 6, message: "minimum 6 characters")
    |> unique_constraint(:nickname, message: "nickname already taken")
    |> unique_constraint(:email,    message: "email already registered")
    |> put_id()
    |> hash_password()
  end

  @doc """
  Changeset for setting the DID after user creation.
  """
  def did_changeset(user, did_id) do
    user
    |> cast(%{did_id: did_id}, [:did_id])
    |> validate_required([:did_id])
    |> unique_constraint(:did_id, message: "DID already assigned")
  end

  @doc """
  Changeset for profile updates.
  """
  def update_changeset(user, attrs) do
    user
    |> cast(attrs, [:name, :bio, :avatar])
  end

  @doc """
  Admin changeset — can toggle is_active, is_admin etc.
  """
  def admin_changeset(user, attrs) do
    user
    |> cast(attrs, [:is_active, :is_admin, :is_moderator])
  end

  # -------------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------------

  defp put_id(%Ecto.Changeset{} = changeset) do
    id =
      :crypto.strong_rand_bytes(16)
      |> Base.url_encode64(padding: false)
      |> String.slice(0, 20)

    put_change(changeset, :id, id)
  end

  defp hash_password(%Ecto.Changeset{valid?: true, changes: %{password: pw}} = cs) do
    put_change(cs, :password_hash, Pbkdf2.hash_pwd_salt(pw))
  end
  defp hash_password(changeset), do: changeset
end
