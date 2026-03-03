defmodule Alem.Repo.Migrations.CreateDocuments do
  use Ecto.Migration

  def change do
    create table(:documents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :string, null: false
      add :tenant_id, :string, null: false
      add :filename, :string, null: false
      add :content_type, :string
      add :file_size, :bigint
      add :content_hash, :string
      add :object_key, :string
      add :text_content, :text
      add :metadata, :map, default: %{}
      add :status, :string, default: "pending"

      timestamps()
    end

    create index(:documents, [:user_id])
    create index(:documents, [:tenant_id])
    create index(:documents, [:status])
    create index(:documents, [:content_hash])
  end
end
