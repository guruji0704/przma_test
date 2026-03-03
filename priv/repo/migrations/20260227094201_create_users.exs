defmodule Alem.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :id, :string, primary_key: true
      add :nickname, :string, null: false
      add :email, :string
      add :name, :string
      add :bio, :string
      add :avatar, :string
      add :password_hash, :string, null: false
      add :is_active, :boolean, default: true
      add :is_admin, :boolean, default: false
      add :is_moderator, :boolean, default: false
      add :did_id, :string

      timestamps()
    end

    create unique_index(:users, [:nickname])
    create unique_index(:users, [:email])
    create unique_index(:users, [:did_id])
  end
end
