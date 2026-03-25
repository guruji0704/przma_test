defmodule Alem.Repo.Migrations.CreateCasActivities do
  use Ecto.Migration

  def change do
    create table(:cas_activities, primary_key: false) do
      # PK = activity_id (not id)
      # Self-documenting: JOIN cas_events e ON e.activity_id = a.activity_id
      add :activity_id, :binary_id, primary_key: true

      # ── Tenant context ────────────────────────────────────────────────────
      add :tenant_id, :string, null: false
      add :namespace_key, references(:namespaces,
            column: :id, type: :string, on_delete: :restrict),
          null: false
      # PRIMARY isolation — EVERY query: WHERE namespace_key = $nk
      add :actor_did, :string, null: false
      # NOT FK — DID deactivation must never delete activity history
      add :user_id, references(:users,
            type: :string, on_delete: :restrict),
          null: false
      add :auth_id, :string, null: false
      # Denorm copy of users.auth_id — Bearer token lookup without joining users

      # ── Action ────────────────────────────────────────────────────────────
      add :verb, :string, null: false
      # Upload|Create|Delete|View|Share|Search|Login|Logout|
      # Sync|Comment|React|Invite|Join|Leave|Export|Import
      add :object_hash, references(:cas_objects,
            column: :content_hash, type: :string, on_delete: :nilify_all)
      # NULL for non-file verbs (Login, Search, Invite)
      add :object_type, :string
      # Document|Media|Circle|User|Conversation|Vault|Channel
      add :object_id, :string
      # Generic id for non-CAS objects (circle_did, channel_id)
      add :object_path, :string
      # przma://did:.../vault/journals/entry_20260324
      add :target_did, :string
      # Recipient for Share/Invite/Comment
      add :device_id, :string
      add :session_id, :string
      add :platform, :string
      # tauri_desktop|web|mobile_ios|mobile_android|api
      add :client_version, :string

      # ── PRZMA dimensions ──────────────────────────────────────────────────
      add :seven_p_dimension, :string
      # presence|people|portfolio|progress|perspectives|pursuits|purpose
      add :light_signal, :string
      # L|i|G|H|T
      add :context, :map, default: %{}

      # ── Timing ────────────────────────────────────────────────────────────
      add :published_at, :utc_datetime, null: false
      # WHEN action occurred — PRIMARY sort column
      # May differ from inserted_at for offline-synced rows
      add :duration_ms, :integer

      # ── Effective-record — offline sync conflict resolution ───────────────
      # Two devices edit same object offline simultaneously:
      #   Both INSERT with is_active=TRUE
      #   On sync conflict: losing record SET is_voided=TRUE,
      #                     void_reason='sync_conflict'
      # All normal queries: AND is_active = TRUE
      add :effective_from, :utc_datetime, null: false
      add :effective_to, :utc_datetime
      add :is_active, :boolean, default: true, null: false
      add :is_voided, :boolean, default: false, null: false
      add :voided_at, :utc_datetime
      add :voided_by_did, :string
      add :void_reason, :string
      # sync_conflict|admin_correction|duplicate|test_data|user_request

      timestamps(type: :utc_datetime, updated_at: false)
    end

    # Primary: namespace + time (most common query pattern)
    create index(:cas_activities, [:namespace_key, :published_at])

    # Partial: active only — smaller, faster
    execute """
      CREATE INDEX idx_ca_active_ns_pub
      ON cas_activities (namespace_key, published_at DESC)
      WHERE is_active = TRUE
    """,
    "DROP INDEX IF EXISTS idx_ca_active_ns_pub"

    create index(:cas_activities, [:actor_did, :published_at])
    create index(:cas_activities, [:tenant_id, :verb])
    create index(:cas_activities, [:namespace_key, :verb])
    create index(:cas_activities, [:object_hash])
    create index(:cas_activities, [:light_signal])
    create index(:cas_activities, [:seven_p_dimension])
    create index(:cas_activities, [:device_id, :published_at])
    create index(:cas_activities, [:session_id, :published_at])

    execute """
      CREATE INDEX idx_ca_voided
      ON cas_activities (namespace_key, voided_at)
      WHERE is_voided = TRUE
    """,
    "DROP INDEX IF EXISTS idx_ca_voided"
  end
end
