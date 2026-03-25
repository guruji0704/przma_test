defmodule Alem.Repo.Migrations.CreateCasAiTrainingLabels do
  use Ecto.Migration

  def change do
    create table(:cas_ai_training_labels, primary_key: false) do
      add :id,              :binary_id, primary_key: true
      add :activity_id,     references(:cas_activities,
                              type: :binary_id, on_delete: :delete_all), null: false
      add :label_type,      :string, null: false
      add :label_value,     :string, null: false
      add :confidence,      :decimal
      add :labeler,         :string, null: false
      add :labeler_did,     :string
      add :model_version,   :string
      add :training_split,  :string, default: "train"
      add :verified,        :boolean, default: false
      add :verified_at,     :utc_datetime
      add :verified_by_did, :string

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:cas_ai_training_labels, [:activity_id])
    create index(:cas_ai_training_labels, [:label_type])
    create index(:cas_ai_training_labels, [:training_split])
    create index(:cas_ai_training_labels, [:verified, :training_split])
  end
end
