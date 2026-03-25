defmodule Alem.Repo.Migrations.CreateCasEvents do
  use Ecto.Migration

  def change do
    create table(:cas_events) do
      add :event_type,    :string, null: false
      add :actor_did,     :string
      add :namespace_key, :string
      add :content_hash,  references(:cas_objects,
                            column: :content_hash, type: :string,
                            on_delete: :nilify_all)
      add :activity_id,   :binary_id
      add :device_id,     :string
      add :ip_hash,       :string
      add :user_agent,    :string
      add :request_id,    :string
      add :success,       :boolean, default: true
      add :error_code,    :string
      add :error_message, :text
      add :duration_ms,   :integer
      add :bytes_in,      :bigint, default: 0
      add :bytes_out,     :bigint, default: 0
      add :metadata,      :map, default: %{}
      add :occurred_at,   :utc_datetime, null: false
    end

    create index(:cas_events, [:actor_did, :occurred_at])
    create index(:cas_events, [:event_type, :occurred_at])
    create index(:cas_events, [:namespace_key, :occurred_at])
    create index(:cas_events, [:occurred_at])
  end
end
