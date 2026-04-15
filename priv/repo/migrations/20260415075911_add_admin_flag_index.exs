defmodule Alem.Repo.Migrations.AddAdminFlagIndex do
  use Ecto.Migration

  def change do
    # Admin status uses is_admin flag on the users table.
    # Add an index to speed up admin lookups.
    create_if_not_exists index(:users, [:is_admin])
    create_if_not_exists index(:users, [:is_moderator])
  end
end
