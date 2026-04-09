defmodule Alem.Repo.Migrations.CreateOauthTokens do
  use Ecto.Migration

  def change do
    create table(:oauth_tokens, primary_key: false) do
      add :id, :uuid, primary_key: true  
      add :token, :string, null: false
      add :refresh_token, :string
      add :user_id, :string
      add :app_id, references(:oauth_apps, type: :binary_id, on_delete: :delete_all)
      add :scopes, {:array, :string}, default: [], null: false
      add :valid_until, :utc_datetime
      add :revoked_at, :utc_datetime

      timestamps()
    end

    create unique_index(:oauth_tokens, [:token])
    create index(:oauth_tokens, [:user_id])
    create index(:oauth_tokens, [:app_id])
    create index(:oauth_tokens, [:valid_until])
  end
end
