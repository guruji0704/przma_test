defmodule Alem.Pleroma.Web.OAuth.App do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}  # ← Ecto generates UUID
  @foreign_key_type :binary_id

  schema "oauth_apps" do
    field :name, :string
    field :website, :string
    field :redirect_uris, :string
    field :client_id, :string
    field :client_secret, :string
    field :scopes, {:array, :string}

    timestamps(type: :naive_datetime)
  end

  def register_changeset(app, attrs) do
    app
    |> cast(attrs, [:name, :website, :redirect_uris, :scopes])
    |> validate_required([:name, :redirect_uris])
    |> put_client_credentials()
    |> unique_constraint(:client_id)
    # ← DON'T manually set ID
  end

  defp put_client_credentials(changeset) do
    changeset
    |> put_change(:client_id, generate_client_id())
    |> put_change(:client_secret, generate_secret())
  end

  defp generate_client_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp generate_secret do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end
