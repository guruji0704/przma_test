defmodule Alem.Repo.Migrations.AddPasswordResetToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :reset_token,         :string
      add :reset_token_expires_at, :naive_datetime
      add :reset_token_attempts,   :integer, default: 0
      add :reset_sent_at,          :naive_datetime
    end
  end
end
