defmodule Alem.Repo.Migrations.RelaxCasObjectsUserConstraint do
  use Ecto.Migration

  @moduledoc """
  Drops the FK constraint on user_id in cas_objects and makes the column nullable.

  Why: same reason as relax_cas_user_constraints (20260330150151) which already
  did this for cas_activities and cas_dedup_refs but accidentally omitted cas_objects.

  The CAS layer identifies users via namespace_key / actor_did (DID strings), not
  users.id (UUID). Enforcing the FK breaks CAS for any caller that passes a
  non-UUID user_id (mock auth, system operations, CLI tools, smoke tests).
  Per-user tracking is fully covered by namespace_key and actor_did.
  """

  def up do
    execute "ALTER TABLE cas_objects DROP CONSTRAINT IF EXISTS cas_objects_user_id_fkey"
    execute "ALTER TABLE cas_objects ALTER COLUMN user_id DROP NOT NULL"
    execute "ALTER TABLE cas_objects ALTER COLUMN actor_did DROP NOT NULL"
  end

  def down do
    execute "ALTER TABLE cas_objects ALTER COLUMN user_id SET NOT NULL"
    execute "ALTER TABLE cas_objects ALTER COLUMN actor_did SET NOT NULL"
  end
end
