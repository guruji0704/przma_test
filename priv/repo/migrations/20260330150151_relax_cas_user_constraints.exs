defmodule Alem.Repo.Migrations.RelaxCasUserConstraints do
  use Ecto.Migration

  @moduledoc """
  Drops the FK constraints on user_id in cas_activities and cas_dedup_refs,
  and makes user_id + actor_did nullable in both.

  Why: The CAS layer uses namespace_key as the user identity string.
  namespace_key is NOT the same as users.id — it is a 16-char DID prefix.
  Requiring a valid users.id FK breaks every CAS operation that doesn't have
  an authenticated user in scope (smoke tests, system operations, etc.).

  Per-user tracking is already handled by namespace_key and actor_did (DID).
  user_id in CAS tables is an optional audit hint, not a FK requirement.
  """

  def up do
    # ── cas_activities ───────────────────────────────────────────────────────
    execute "ALTER TABLE cas_activities DROP CONSTRAINT IF EXISTS cas_activities_user_id_fkey"
    execute "ALTER TABLE cas_activities ALTER COLUMN user_id   DROP NOT NULL"
    execute "ALTER TABLE cas_activities ALTER COLUMN actor_did DROP NOT NULL"
    execute "ALTER TABLE cas_activities ALTER COLUMN auth_id   DROP NOT NULL"

    # ── cas_dedup_refs ───────────────────────────────────────────────────────
    execute "ALTER TABLE cas_dedup_refs DROP CONSTRAINT IF EXISTS cas_dedup_refs_user_id_fkey"
    execute "ALTER TABLE cas_dedup_refs ALTER COLUMN user_id   DROP NOT NULL"
    execute "ALTER TABLE cas_dedup_refs ALTER COLUMN actor_did DROP NOT NULL"
  end

  def down do
    execute "ALTER TABLE cas_activities ALTER COLUMN user_id   SET NOT NULL"
    execute "ALTER TABLE cas_activities ALTER COLUMN actor_did SET NOT NULL"
    execute "ALTER TABLE cas_activities ALTER COLUMN auth_id   SET NOT NULL"
    execute "ALTER TABLE cas_dedup_refs  ALTER COLUMN user_id   SET NOT NULL"
    execute "ALTER TABLE cas_dedup_refs  ALTER COLUMN actor_did SET NOT NULL"
  end
end
