defmodule Alem.Repo.Migrations.CreateCasFilterAssessments do
  use Ecto.Migration

  def change do
    create table(:cas_filter_assessments, primary_key: false) do
      add :id,                  :binary_id, primary_key: true
      add :activity_id,         references(:cas_activities,
                                  type: :binary_id, on_delete: :delete_all)
      add :perception_id,       :string
      add :actor_did,           :string, null: false
      add :namespace_key,       :string, null: false
      add :assessed_at,         :utc_datetime
      add :assessment_stage,    :string, default: "initial"

      # 7 Filters — each has status + score
      add :body_status,         :string
      add :body_score,          :integer
      add :senses_status,       :string
      add :senses_score,        :integer
      add :mind_status,         :string
      add :mind_score,          :integer
      add :heart_status,        :string
      add :heart_score,         :integer
      add :ego_status,          :string
      add :ego_score,           :integer
      add :knowledge_status,    :string
      add :knowledge_score,     :integer
      add :detachment_status,   :string
      add :detachment_score,    :integer

      # Computed fields
      add :fogged_filters,      {:array, :string}, default: []
      add :cleared_filters,     {:array, :string}, default: []
      add :overall_clarity,     :decimal

      add :notes, :text

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:cas_filter_assessments, [:actor_did])
    create index(:cas_filter_assessments, [:activity_id])
    create index(:cas_filter_assessments, [:overall_clarity])
    execute "CREATE INDEX idx_cas_fa_fogged
             ON cas_filter_assessments USING GIN(fogged_filters)"
  end
end
