defmodule Alem.Repo.Migrations.CreateCasActivities do
  use Ecto.Migration

  def change do
    create table(:cas_activities, primary_key: false) do
      add :activity_id,     :binary_id, primary_key: true

      add :tenant_id,       :string, null: false
      add :namespace_key,   references(:namespaces, column: :id, type: :string, on_delete: :restrict), null: false
      add :actor_did,       :string, null: false
      add :user_id,         references(:users, type: :string, on_delete: :restrict), null: false
      add :auth_id,         :string, null: false

      add :verb,            :string, null: false
      add :object_hash,     references(:cas_objects, column: :content_hash, type: :string, on_delete: :nilify_all)
      add :object_type,     :string
      add :object_id,       :string
      add :object_path,     :string
      add :target_did,      :string
      add :device_id,       :string
      add :session_id,      :string
      add :platform,        :string
      add :client_version,  :string

      add :seven_p_dimension,:string
      add :light_signal,    :string
      add :context,         :map, default: %{}

      add :published_at,    :utc_datetime, null: false
      add :duration_ms,     :integer

      add :effective_from,  :utc_datetime, null: false
      add :effective_to,    :utc_datetime
      add :is_active,       :boolean, default: true, null: false
      add :is_voided,       :boolean, default: false, null: false
      add :voided_at,       :utc_datetime
      add :voided_by_did,   :string
      add :void_reason,     :string

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:cas_activities, [:namespace_key, :published_at])
    create index(:cas_activities, [:actor_did, :published_at])
    create index(:cas_activities, [:tenant_id, :verb])
    create index(:cas_activities, [:object_hash])

    execute """
      CREATE INDEX idx_ca_active_ns_pub
      ON cas_activities (namespace_key, published_at DESC)
      WHERE is_active = TRUE
    """,
    "DROP INDEX IF EXISTS idx_ca_active_ns_pub"
  end
end
