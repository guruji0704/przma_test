defmodule Alem.Repo.Migrations.AddEmailVerificationToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :is_verified,      :boolean, default: false, null: false
      add :otp_code,         :string
      add :otp_expires_at,   :naive_datetime
      add :otp_attempts,     :integer, default: 0
    end
  end
end
