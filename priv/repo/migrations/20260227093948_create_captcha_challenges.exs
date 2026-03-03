defmodule Alem.Repo.Migrations.CreateCaptchaChallenges do
  use Ecto.Migration

  def change do
    create table(:captcha_challenges, primary_key: false) do
      add :id, :string, primary_key: true
      add :token, :string, null: false
      add :answer, :string, null: false
      add :used, :boolean, default: false, null: false
      add :expires_at, :utc_datetime, null: false

      timestamps()
    end

    create unique_index(:captcha_challenges, [:token])
    create index(:captcha_challenges, [:expires_at])
    create index(:captcha_challenges, [:used])
  end
end
