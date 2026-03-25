defmodule Alem.Repo.Migrations.CreateCasLexiconTags do
  use Ecto.Migration

  def change do
    create table(:cas_lexicon_tags, primary_key: false) do
      add :id,                :binary_id, primary_key: true
      add :activity_id,       references(:cas_activities,
                                type: :binary_id, on_delete: :delete_all), null: false
      add :namespace_key,     :string, null: false
      add :tag,               :string, null: false
      add :category,          :string, null: false
      add :seven_p_dimension, :string
      add :source,            :string, default: "ai"
      add :confidence,        :decimal
      add :span_start,        :integer
      add :span_end,          :integer

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:cas_lexicon_tags, [:activity_id])
    create index(:cas_lexicon_tags, [:tag])
    create index(:cas_lexicon_tags, [:category])
    create index(:cas_lexicon_tags, [:namespace_key])
  end
end
