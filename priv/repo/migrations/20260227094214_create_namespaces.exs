defmodule Alem.Repo.Migrations.CreateNamespaces do
  use Ecto.Migration

  def change do
    create table(:namespaces, primary_key: false) do
      add :id, :string, primary_key: true
      add :tenant_id, :string, null: false
      add :config, :map, default: %{}
      add :status, :string, default: "active"
      add :document_count, :integer, default: 0
      add :vector_count, :integer, default: 0
      add :storage_bytes, :bigint, default: 0
      add :last_activity_at, :utc_datetime

      timestamps()
    end

    create index(:namespaces, [:tenant_id])
    create index(:namespaces, [:status])
  end
end
