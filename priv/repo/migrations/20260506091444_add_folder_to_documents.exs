defmodule Alem.Repo.Migrations.AddFolderToDocuments do
  use Ecto.Migration

  @doc """
  Documents now belong to a folder (personal/private/public).
  media_category drives S3 sub-folder (images/videos/audio/documents).
  is_encrypted = true for private folder — server never decrypts these.
  """
  def change do
    alter table(:documents) do
      add_if_not_exists :folder,         :string, default: "personal"
      add_if_not_exists :media_category, :string, default: "documents"
      add_if_not_exists :is_encrypted,   :boolean, default: false
      # true for private folder uploads — stored as opaque ciphertext
    end

    create_if_not_exists index(:documents, [:folder])
    create_if_not_exists index(:documents, [:user_id, :folder])
    create_if_not_exists index(:documents, [:user_id, :folder, :media_category])

    # Backfill media_category for existing rows
    execute """
      UPDATE documents SET media_category =
        CASE
          WHEN content_type LIKE 'image/%'           THEN 'images'
          WHEN content_type LIKE 'video/%'           THEN 'videos'
          WHEN content_type LIKE 'audio/%'           THEN 'audio'
          WHEN content_type LIKE '%pdf%'             THEN 'documents'
          WHEN content_type LIKE '%wordprocessing%'  THEN 'documents'
          WHEN content_type LIKE 'text/%'            THEN 'documents'
          ELSE 'documents'
        END
      WHERE media_category = 'documents' OR media_category IS NULL
    """,
    "SELECT 1"
  end
end
