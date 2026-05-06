defmodule Alem.Repo.Migrations.AddFolderTypeToNamespaces do
  use Ecto.Migration

  @doc """
  Each user gets 3 namespaces on registration: personal, private, public.
  folder_type tells us which folder this namespace serves.
  parent_did links all 3 back to the owning user.
  """
  def change do
    alter table(:namespaces) do
      add_if_not_exists :folder_type, :string, default: "personal"
      # values: personal | private | public | platform
      add_if_not_exists :parent_did,  :string
      # DID of owning user — null for platform namespaces like przma-commons
    end

    create_if_not_exists index(:namespaces, [:parent_did])
    create_if_not_exists index(:namespaces, [:parent_did, :folder_type])
    create_if_not_exists index(:namespaces, [:folder_type])
  end
end
