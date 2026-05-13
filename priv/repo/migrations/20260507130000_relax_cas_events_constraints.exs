defmodule Alem.Repo.Migrations.RelaxCasEventsConstraints do
  use Ecto.Migration

  @moduledoc """
  Drops all orphaned FK constraints on namespace_key, actor_did, and user_id
  across every CAS table: cas_events, cas_dedup_refs, cas_activities, cas_objects.

  Why: namespace_key is a DID-derived routing key (first 16 chars of SHA-256
  fingerprint). It is NOT the primary key of the namespaces table — that is
  keyed by user_id. Any FK from a CAS table to namespaces/users via
  namespace_key or actor_did will therefore always fail at insert time.

  cas_objects was partially covered by 20260507120000; this migration
  completes the cleanup for all remaining CAS tables.
  All DROP CONSTRAINTs use IF EXISTS so the migration is idempotent.
  """

  def up do
    # ── cas_objects ──────────────────────────────────────────────────────────
    execute "ALTER TABLE cas_objects DROP CONSTRAINT IF EXISTS cas_objects_user_id_fkey"
    execute "ALTER TABLE cas_objects DROP CONSTRAINT IF EXISTS cas_objects_namespace_key_fkey"
    execute "ALTER TABLE cas_objects DROP CONSTRAINT IF EXISTS cas_objects_actor_did_fkey"
    execute "ALTER TABLE cas_objects ALTER COLUMN user_id DROP NOT NULL"
    execute "ALTER TABLE cas_objects ALTER COLUMN actor_did DROP NOT NULL"

    # ── cas_activities ────────────────────────────────────────────────────────
    execute "ALTER TABLE cas_activities DROP CONSTRAINT IF EXISTS cas_activities_namespace_key_fkey"
    execute "ALTER TABLE cas_activities DROP CONSTRAINT IF EXISTS cas_activities_actor_did_fkey"
    execute "ALTER TABLE cas_activities DROP CONSTRAINT IF EXISTS cas_activities_user_id_fkey"
    execute "ALTER TABLE cas_activities ALTER COLUMN namespace_key DROP NOT NULL"
    execute "ALTER TABLE cas_activities ALTER COLUMN actor_did DROP NOT NULL"
    execute "ALTER TABLE cas_activities ALTER COLUMN user_id DROP NOT NULL"

    # ── cas_dedup_refs ────────────────────────────────────────────────────────
    execute "ALTER TABLE cas_dedup_refs DROP CONSTRAINT IF EXISTS cas_dedup_refs_namespace_key_fkey"
    execute "ALTER TABLE cas_dedup_refs DROP CONSTRAINT IF EXISTS cas_dedup_refs_actor_did_fkey"
    execute "ALTER TABLE cas_dedup_refs DROP CONSTRAINT IF EXISTS cas_dedup_refs_user_id_fkey"
    execute "ALTER TABLE cas_dedup_refs ALTER COLUMN namespace_key DROP NOT NULL"
    execute "ALTER TABLE cas_dedup_refs ALTER COLUMN actor_did DROP NOT NULL"
    execute "ALTER TABLE cas_dedup_refs ALTER COLUMN user_id DROP NOT NULL"

    # ── cas_events ────────────────────────────────────────────────────────────
    execute "ALTER TABLE cas_events DROP CONSTRAINT IF EXISTS cas_events_namespace_key_fkey"
    execute "ALTER TABLE cas_events DROP CONSTRAINT IF EXISTS cas_events_actor_did_fkey"
    execute "ALTER TABLE cas_events DROP CONSTRAINT IF EXISTS cas_events_user_id_fkey"
    execute "ALTER TABLE cas_events ALTER COLUMN namespace_key DROP NOT NULL"
    execute "ALTER TABLE cas_events ALTER COLUMN actor_did DROP NOT NULL"
  end

  def down do
    # Restore only NOT NULL — FKs are not re-added as they would require data cleanup
    execute "ALTER TABLE cas_objects ALTER COLUMN user_id SET NOT NULL"
    execute "ALTER TABLE cas_objects ALTER COLUMN actor_did SET NOT NULL"
    execute "ALTER TABLE cas_activities ALTER COLUMN namespace_key SET NOT NULL"
    execute "ALTER TABLE cas_activities ALTER COLUMN actor_did SET NOT NULL"
    execute "ALTER TABLE cas_activities ALTER COLUMN user_id SET NOT NULL"
    execute "ALTER TABLE cas_dedup_refs ALTER COLUMN namespace_key SET NOT NULL"
    execute "ALTER TABLE cas_dedup_refs ALTER COLUMN actor_did SET NOT NULL"
    execute "ALTER TABLE cas_dedup_refs ALTER COLUMN user_id SET NOT NULL"
    execute "ALTER TABLE cas_events ALTER COLUMN namespace_key SET NOT NULL"
    execute "ALTER TABLE cas_events ALTER COLUMN actor_did SET NOT NULL"
  end
end
