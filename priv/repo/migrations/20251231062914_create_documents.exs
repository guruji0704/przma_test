defmodule Alem.Repo.Migrations.CreateDocuments do
  use Ecto.Migration

  def change do
    create table(:documents, primary_key: false) do
      add :id, :string, primary_key: true
      add :user_id, :string, null: false
      add :filename, :string, null: false
      add :content_type, :string
      add :object_key, :string
      add :text_content, :text
      add :metadata, :map
      add :status, :string, default: "processing"

      timestamps(type: :utc_datetime)
    end

    create index(:documents, [:user_id])
    create index(:documents, [:status])
    create index(:documents, [:filename])

    # Full-text search index
    execute(
      "CREATE INDEX documents_text_content_idx ON documents USING GIN (to_tsvector('english', text_content))",
      "DROP INDEX documents_text_content_idx"
    )
  end
end
