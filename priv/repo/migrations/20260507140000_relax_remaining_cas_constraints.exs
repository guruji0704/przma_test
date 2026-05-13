defmodule Alem.Repo.Migrations.RelaxRemainingCasConstraints do
  use Ecto.Migration

  @moduledoc """
  Drops remaining FK constraints on cas_objects, cas_activities, and
  cas_dedup_refs that were not covered by earlier migrations.

  20260507120000 handled cas_objects.user_id_fkey.
  20260507130000 handled cas_events.namespace_key_fkey and actor_did_fkey.
  This migration covers everything else.

  All statements use IF EXISTS — safe to run even if some constraints
  were already dropped manually.
  """

  def up do
    # ── cas_objects (remaining constraints) ──────────────────────────────────
    execute "ALTER TABLE cas_objects DROP CONSTRAINT IF EXISTS cas_objects_namespace_key_fkey"
    execute "ALTER TABLE cas_objects DROP CONSTRAINT IF EXISTS cas_objects_actor_did_fkey"

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
  end

  def down do
    execute "ALTER TABLE cas_activities ALTER COLUMN namespace_key SET NOT NULL"
    execute "ALTER TABLE cas_activities ALTER COLUMN actor_did SET NOT NULL"
    execute "ALTER TABLE cas_activities ALTER COLUMN user_id SET NOT NULL"
    execute "ALTER TABLE cas_dedup_refs ALTER COLUMN namespace_key SET NOT NULL"
    execute "ALTER TABLE cas_dedup_refs ALTER COLUMN actor_did SET NOT NULL"
    execute "ALTER TABLE cas_dedup_refs ALTER COLUMN user_id SET NOT NULL"
  end
end
