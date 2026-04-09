defmodule Alem.Repo.Migrations.MakeCasObjectsFieldsNullable do
  use Ecto.Migration

  @doc """
  Makes user_id and actor_did nullable in cas_objects.

  These were created as null: false in 20260325112118 but that is too
  restrictive — CAS operates at the storage layer without always having
  a user context (smoke tests, system operations, future service accounts).
  Per-user tracking is handled by cas_dedup_refs and cas_activities.
  """
  def up do
    execute "ALTER TABLE cas_objects ALTER COLUMN user_id   DROP NOT NULL"
    execute "ALTER TABLE cas_objects ALTER COLUMN actor_did DROP NOT NULL"
  end

  def down do
    execute "ALTER TABLE cas_objects ALTER COLUMN user_id   SET NOT NULL"
    execute "ALTER TABLE cas_objects ALTER COLUMN actor_did SET NOT NULL"
  end
end
