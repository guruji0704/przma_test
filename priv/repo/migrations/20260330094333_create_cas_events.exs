defmodule Alem.Repo.Migrations.CreateCasEvents do
  use Ecto.Migration

  def change do
    create table(:cas_events, primary_key: false) do
      add :event_seq,     :bigserial, primary_key: true

      add :tenant_id,     :string
      add :namespace_key, references(:namespaces, column: :id, type: :string, on_delete: :nilify_all)
      add :actor_did,     :string
      add :user_id,       references(:users, type: :string, on_delete: :nilify_all)

      add :activity_id,   references(:cas_activities, column: :activity_id, type: :binary_id, on_delete: :nilify_all)
      add :content_hash,  references(:cas_objects, column: :content_hash, type: :string, on_delete: :nilify_all)
      add :device_id,     :string
      add :session_id,    :string

      add :event_category,:string, null: false
      add :event_type,    :string, null: false

      add :request_id,    :string
      add :ip_hash,       :string
      add :user_agent,    :text

      add :is_success,    :boolean, default: true, null: false
      add :error_code,    :string
      add :error_message, :text

      add :duration_ms,   :integer
      add :bytes_in,      :bigint, default: 0, null: false
      add :bytes_out,     :bigint, default: 0, null: false
      add :metadata,      :map, default: %{}

      add :occurred_at,   :utc_datetime, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:cas_events, [:namespace_key, :occurred_at])
    create index(:cas_events, [:request_id])
    create index(:cas_events, [:activity_id])
    create index(:cas_events, [:event_category, :event_type])

    execute """
      CREATE INDEX idx_ce_failures
      ON cas_events (namespace_key, occurred_at)
      WHERE is_success = FALSE
    """,
    "DROP INDEX IF EXISTS idx_ce_failures"
  end
end
