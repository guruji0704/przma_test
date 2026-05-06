defmodule Alem.Repo.Migrations.DropNamespacesDidUnique do
  use Ecto.Migration

  def change do
    # One user (one DID) now owns 3 namespace rows: personal, private, public.
    # The unique constraint on did must be dropped.
    # Uniqueness is now enforced by the composite (parent_did, folder_type).
    drop_if_exists unique_index(:namespaces, [:did])

    # Add the correct composite unique index instead
    create_if_not_exists unique_index(:namespaces, [:parent_did, :folder_type])
  end
end
