defmodule Przma.Repo.Migrations.CreateVaultIndex do
  use Ecto.Migration

  def change do
    create table(:namespace_index, primary_key: false) do
      add :id,        :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :path,      :string,    null: false
      add :cid,       :string,    null: false
      add :owner_did, :string,    null: false
      add :tier,      :string,    null: false, default: "personal"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:namespace_index, [:path, :owner_did])
    create index(:namespace_index, [:owner_did])
    create index(:namespace_index, [:cid])

    create table(:authorship_proofs, primary_key: false) do
      add :id,        :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :cid,       :string,    null: false
      add :owner_did, :string,    null: false
      add :sig,       :text,      null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:authorship_proofs, [:cid, :owner_did])
    create index(:authorship_proofs, [:owner_did])
  end
end
