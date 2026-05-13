defmodule Alem.Repo.Migrations.AddVaultCategoryToDocuments do
  use Ecto.Migration

  def change do
    alter table(:documents) do
      add_if_not_exists :vault_category, :string, default: "personal", null: false
    end

    create_if_not_exists index(:documents, [:user_id, :vault_category])
  end
end
