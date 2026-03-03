defmodule Alem.Repo.Migrations.CreateSessions do
  use Ecto.Migration

  def change do
    create table(:sessions, primary_key: false) do
      add :id,             :string,  primary_key: true, null: false
      add :user_id,        references(:users, type: :string, on_delete: :delete_all), null: false
      add :device,         :string         # "mobile" / "desktop" / "api_client" / "unknown"
      add :ip_address,     :string
      add :user_agent,     :text
      add :last_active_at, :naive_datetime_usec
      add :revoked_at,     :naive_datetime_usec
      timestamps(type: :naive_datetime_usec)
    end

    create index(:sessions, [:user_id])
    create index(:sessions, [:revoked_at])
  end
end
