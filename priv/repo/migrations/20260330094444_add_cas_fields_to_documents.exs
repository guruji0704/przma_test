defmodule Alem.Repo.Migrations.AddCasFieldsToDocuments do
  use Ecto.Migration

  def change do
    alter table(:documents) do
      add_if_not_exists :file_size,     :bigint,  default: 0
      add_if_not_exists :activity_verb, :string,  default: "Create"
      add_if_not_exists :actor_id,      :string
    end

    execute """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM pg_constraint
          WHERE conname = 'documents_content_hash_fkey'
        ) THEN
          ALTER TABLE documents
          ADD CONSTRAINT documents_content_hash_fkey
          FOREIGN KEY (content_hash)
          REFERENCES cas_objects(content_hash)
          ON DELETE RESTRICT;
        END IF;
      END
      $$;
    """,
    "ALTER TABLE documents DROP CONSTRAINT IF EXISTS documents_content_hash_fkey"

    create_if_not_exists index(:documents, [:content_hash])
  end
end
