defmodule Alem.Repo.Migrations.AddTenantIdToDocuments do
  use Ecto.Migration

  def change do
    alter table(:documents) do
      add :tenant_id, :string, null: false, default: "default"
      add :content_hash, :string
    end

    create index(:documents, [:tenant_id])
    create index(:documents, [:tenant_id, :user_id])
    create index(:documents, [:content_hash])
  end
end
