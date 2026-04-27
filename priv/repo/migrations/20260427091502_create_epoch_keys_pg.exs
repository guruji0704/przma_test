defmodule Alem.Repo.Migrations.CreateEpochKeysPg do
  use Ecto.Migration

  def change do
    create table(:epoch_keys, primary_key: false) do
      add :epoch_id,            :integer, primary_key: true
      add :public_key_b64,      :string,  null: false
      add :enc_private_key_b64, :string
      add :started_at,          :utc_datetime, null: false
      add :expires_at,          :utc_datetime, null: false
      add :grace_until,         :utc_datetime
      add :is_current,          :boolean, default: false, null: false
    end

    create index(:epoch_keys, [:is_current])
  end
end
