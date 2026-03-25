defmodule Alem.Repo.Migrations.CreateCasEmbeddings do
  use Ecto.Migration

  def change do
    # Enable pgvector extension first
    execute "CREATE EXTENSION IF NOT EXISTS vector",
            "DROP EXTENSION IF EXISTS vector"

    create table(:cas_embeddings, primary_key: false) do
      add :id,              :binary_id, primary_key: true
      add :content_hash,    references(:cas_objects,
                              column: :content_hash, type: :string,
                              on_delete: :delete_all)
      add :activity_id,     references(:cas_activities,
                              type: :binary_id, on_delete: :nilify_all)
      add :actor_did,       :string, null: false
      add :namespace_key,   :string, null: false
      add :path,            :string
      add :modality,        :string, null: false
      add :text_preview,    :string, size: 500
      add :model_name,      :string, default: "all-MiniLM-L6-v2"
      add :model_version,   :string
      add :filter_context,  :map, default: %{}
      add :seven_p_context, :string

      timestamps(type: :utc_datetime, updated_at: false)
    end

    # Add the vector column separately — Ecto doesn't know this type
    execute "ALTER TABLE cas_embeddings
             ADD COLUMN embedding vector(384)",
            "ALTER TABLE cas_embeddings DROP COLUMN embedding"

    # IVFFlat index for fast cosine similarity search
    execute "CREATE INDEX idx_cas_embeddings_vector
             ON cas_embeddings
             USING ivfflat (embedding vector_cosine_ops)
             WITH (lists = 100)",
            "DROP INDEX IF EXISTS idx_cas_embeddings_vector"

    create index(:cas_embeddings, [:actor_did])
    create index(:cas_embeddings, [:namespace_key])
    create index(:cas_embeddings, [:content_hash])
    create index(:cas_embeddings, [:modality])
  end
end
