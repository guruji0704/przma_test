defmodule Alem.Repo.Migrations.CreateCasEvents do
  use Ecto.Migration

  def change do
    create table(:cas_events, primary_key: false) do
      # PK = event_seq (BIGSERIAL) — integer not UUID
      # 8 bytes vs 16 bytes — 10M+ rows/year = significant saving
      # Name conveys: ordered, append-only, high-volume
      add :event_seq, :bigserial, primary_key: true

      # ── Tenant context ─────────────────────────────────────────────────
      add :tenant_id, :string
      # NULL for server-level events (backups, integrity checks)
      add :namespace_key, references(:namespaces,
            column: :id, type: :string, on_delete: :nilify_all)
      add :actor_did, :string
      # NULL for background system jobs
      add :user_id, references(:users,
            type: :string, on_delete: :nilify_all)

      # ── Links ─────────────────────────────────────────────────────────
      add :activity_id, references(:cas_activities,
            column: :activity_id, type: :binary_id, on_delete: :nilify_all)
      # Column name matches cas_activities.activity_id exactly
      add :content_hash, references(:cas_objects,
            column: :content_hash, type: :string, on_delete: :nilify_all)
      add :device_id, :string
      add :session_id, :string

      # ── Event classification ───────────────────────────────────────────
      add :event_category, :string, null: false
      # file|auth|sync|vault|quota|admin|federation
      # Rollup without enumerating types:
      #   SELECT event_category, COUNT(*) GROUP BY 1
      add :event_type, :string, null: false
      # file.upload|file.download|file.delete|file.verify
      # auth.login|auth.logout|auth.token_issue|auth.token_revoke
      # sync.push|sync.pull|sync.conflict_detected|sync.conflict_resolved
      # vault.backup|vault.restore|quota.exceeded|quota.warning

      # ── Distributed tracing ────────────────────────────────────────────
      add :request_id, :string
      # ALL events from ONE HTTP request share this UUID
      # Debug: WHERE request_id = $rid -> see every step of one request
      add :ip_hash, :string
      # SHA256(raw_ip) — NEVER store raw IP (GDPR)
      add :user_agent, :text

      # ── Outcome ───────────────────────────────────────────────────────
      add :is_success, :boolean, default: true, null: false
      # Renamed from "success" — is_ prefix convention
      add :error_code, :string
      # FILE_TOO_LARGE|QUOTA_EXCEEDED|NOT_FOUND|PERMISSION_DENIED|
      # HASH_MISMATCH|STORAGE_ERROR|AUTH_EXPIRED|DID_BLOCKED
      add :error_message, :text
      # NEVER return to clients directly

      # ── Performance / billing ──────────────────────────────────────────
      add :duration_ms, :integer
      add :bytes_in, :bigint, default: 0, null: false
      add :bytes_out, :bigint, default: 0, null: false
      # Billing: SUM(bytes_in+bytes_out) WHERE tenant_id=$tid AND occurred_at > month_start
      add :metadata, :map, default: %{}

      add :occurred_at, :utc_datetime, null: false
      # PRIMARY sort + future monthly partition column

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:cas_events, [:namespace_key, :occurred_at])
    create index(:cas_events, [:tenant_id, :occurred_at])
    create index(:cas_events, [:actor_did, :occurred_at])
    create index(:cas_events, [:request_id])
    create index(:cas_events, [:activity_id])
    create index(:cas_events, [:event_category, :event_type])
    create index(:cas_events, [:session_id, :occurred_at])

    execute """
      CREATE INDEX idx_ce_failures
      ON cas_events (namespace_key, occurred_at)
      WHERE is_success = FALSE
    """,
    "DROP INDEX IF EXISTS idx_ce_failures"
  end
end
