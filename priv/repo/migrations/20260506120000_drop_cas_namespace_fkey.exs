defmodule Alem.Repo.Migrations.DropCasNamespaceFkey do
  use Ecto.Migration

  def change do
    # namespace_key on cas_objects/cas_activities is an audit field.
    # It does NOT need a hard FK — the namespace may not exist when
    # CAS processes content from new home folders.
    execute "ALTER TABLE cas_objects DROP CONSTRAINT IF EXISTS cas_objects_namespace_key_fkey",
            "SELECT 1"

    execute "ALTER TABLE cas_activities DROP CONSTRAINT IF EXISTS cas_activities_namespace_key_fkey",
            "SELECT 1"
  end
end
