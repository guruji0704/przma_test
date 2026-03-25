defmodule Alem.Repo.Migrations.CreateCasObjects do
  use Ecto.Migration

  def change do
    create table(:cas_objects, primary_key: false) do
      add :content_hash,    :string,  primary_key: true
      add :storage_backend, :string,  default: "s3", null: false
      add :storage_key,     :string,  null: false
      add :media_type,      :string
      add :file_size,       :bigint,  default: 0
      add :ref_count,       :integer, default: 1
      add :verified_at,     :utc_datetime
      add :is_corrupt,      :boolean, default: false
      add :extracted_text,  :text
      add :duration_seconds,:integer
      add :width_px,        :integer
      add :height_px,       :integer
      add :page_count,      :integer

      timestamps(type: :utc_datetime)
    end

    create index(:cas_objects, [:storage_backend])
    create index(:cas_objects, [:inserted_at])
  end
end
