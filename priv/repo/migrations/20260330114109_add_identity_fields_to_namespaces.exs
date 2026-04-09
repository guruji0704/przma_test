defmodule Alem.Repo.Migrations.AddIdentityFieldsToNamespaces do
  use Ecto.Migration

  def change do
    alter table(:namespaces) do
      add_if_not_exists :did,                :string
      add_if_not_exists :pleroma_account_id, :string
      add_if_not_exists :identity_type,      :string, default: "did"
    end

    create_if_not_exists unique_index(:namespaces, [:did],                name: :namespaces_did_index)
    create_if_not_exists unique_index(:namespaces, [:pleroma_account_id], name: :namespaces_pleroma_account_id_index)
  end
end
