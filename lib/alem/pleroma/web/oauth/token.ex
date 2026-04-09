defmodule Alem.Pleroma.Web.OAuth.Token do
  use Ecto.Schema
  import Ecto.Changeset
  alias Alem.Pleroma.Web.OAuth.{Token, App}
  alias Alem.Pleroma.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "oauth_tokens" do
    field :token, :string
    field :refresh_token, :string
    field :scopes, {:array, :string}
    field :valid_until, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :user, User, type: :string
    belongs_to :app, App, type: :binary_id

    timestamps(type: :naive_datetime)
  end

  def create_changeset(%Token{} = token, attrs) do
    token
    |> cast(attrs, [:user_id, :app_id, :scopes])
    |> validate_required([:user_id, :scopes])
    |> put_token()
    |> put_refresh_token()
    |> put_valid_until()
  end

  defp put_token(changeset) do
    put_change(changeset, :token, generate_token())
  end

  defp put_refresh_token(changeset) do
    put_change(changeset, :refresh_token, generate_token())
  end

  defp put_valid_until(changeset) do
    # Token valid for 30 days - TRUNCATE microseconds
    valid_until =
      DateTime.utc_now()
      |> DateTime.add(30 * 24 * 60 * 60, :second)
      |> DateTime.truncate(:second)  # ← FIX: Remove microseconds

    put_change(changeset, :valid_until, valid_until)
  end

  defp generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  # Helper to get expiration in seconds
  def expires_in(%Token{valid_until: valid_until}) do
    DateTime.diff(valid_until, DateTime.utc_now())
  end
end
