defmodule Alem.Repo.Migrations.AddFileMetadataIndexes do
  use Ecto.Migration

  def change do
    # Ensure file_size column exists (if migration 20260227094232 created it)
    # This migration adds proper indexing for file metadata queries

    # Add index on file_size for filtering large files
    create index(:documents, [:file_size])

    # Add composite index for user + status queries
    create index(:documents, [:user_id, :status])

    # Add index for content_type queries
    create index(:documents, [:content_type])

    # Add index for filename searches (optional, depends on search capability)
    # create index(:documents, [:filename])

    # Ensure cas_objects has proper indexes for integrity checks
    create index(:cas_objects, [:is_corrupt])
    create index(:cas_objects, [:is_verified])
    create index(:cas_objects, [:ref_count])
  end
end
