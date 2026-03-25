defmodule Alem.Repo.Migrations.CreateCasActivities do
  use Ecto.Migration

  def change do
    create table(:cas_activities, primary_key: false) do
      add :id,                :binary_id, primary_key: true
      add :actor_did,         :string, null: false
      add :namespace_key,     :string, null: false
      add :verb,              :string, null: false
      add :object_hash,       references(:cas_objects,
                                column: :content_hash, type: :string,
                                on_delete: :nilify_all)
      add :object_type,       :string
      add :object_path,       :string
      add :target_did,        :string
      add :device_id,         :string
      add :platform,          :string
      add :filter_snapshot,   :map,    default: %{}
      add :seven_p_dimension, :string
      add :lexicon_tags,      {:array, :string}, default: []
      add :light_signal,      :string
      add :context,           :map,    default: %{}
      add :published_at,      :utc_datetime, null: false
      add :duration_ms,       :integer
      add :enriched,          :boolean, default: false
      add :enriched_at,       :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:cas_activities, [:actor_did, :published_at])
    create index(:cas_activities, [:namespace_key, :published_at])
    create index(:cas_activities, [:verb])
    create index(:cas_activities, [:object_hash])
    create index(:cas_activities, [:light_signal])
    create index(:cas_activities, [:seven_p_dimension])
    execute "CREATE INDEX idx_cas_activities_lexicon
             ON cas_activities USING GIN(lexicon_tags)"
    execute "CREATE INDEX idx_cas_activities_filter
             ON cas_activities USING GIN(filter_snapshot)"
  end
end
