defmodule Alem.Repo.Migrations.CreateUserProviders do
  use Ecto.Migration
  def change do
    create table(:user_providers, primary_key: false) do
      add :id,             :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :user_id,        references(:users, type: :string, on_delete: :delete_all), null: false
      add :provider_type,  :string, null: false
      add :adapter,        :string, null: false
      add :label,          :string
      add :endpoint,       :string
      add :region,         :string
      add :bucket,         :string
      add :enc_access_key, :text
      add :enc_secret_key, :text
      add :is_active,      :boolean, default: false
      add :is_verified,    :boolean, default: false
      add :verified_at,    :utc_datetime
      add :extra_config,   :map, default: %{}
      timestamps(type: :utc_datetime)
    end
    create index(:user_providers, [:user_id])
    create index(:user_providers, [:user_id, :provider_type])
  end
end
