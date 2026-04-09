defmodule Alem.Repo.Migrations.CreateOauthApps do
  use Ecto.Migration

  def change do
    create table(:oauth_apps, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :client_id, :string, null: false
      add :client_secret, :string, null: false
      add :redirect_uris, :string, null: false
      add :scopes, {:array, :string}, default: [], null: false
      add :website, :string

      timestamps()
    end

    create unique_index(:oauth_apps, [:client_id])
  end
end
