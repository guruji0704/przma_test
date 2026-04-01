defmodule ChatApp.Repo.Migrations.CreateMessages do
  use Ecto.Migration

  def change do
    create table(:messages) do
      add :username, :string, null: false
      add :body,     :string, null: false
      add :room,     :string, null: false, default: "general"
      add :mentions, {:array, :string}, default: []

      timestamps(type: :utc_datetime)
    end

    create index(:messages, [:room])
    create index(:messages, [:inserted_at])
  end
end
