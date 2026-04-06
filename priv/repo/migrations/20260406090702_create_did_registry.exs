defmodule Przma.Repo.Migrations.CreateDIDRegistry do
  use Ecto.Migration

  def change do
    create table(:did_documents, primary_key: false) do
      add :did,      :string, primary_key: true, null: false
      add :document, :jsonb,  null: false
      add :active,   :boolean, default: true

      timestamps(type: :utc_datetime)
    end

    create table(:did_keys, primary_key: false) do
      add :id,         :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :did,        :string, null: false
      add :key_id,     :string, null: false
      add :key_type,   :string, null: false   # "Ed25519VerificationKey2020" | "RsaVerificationKey2018"
      add :public_key, :text,   null: false   # PEM for RSA, base58 for Ed25519
      add :purpose,    :string, null: false   # "authentication" | "assertionMethod"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:did_keys, [:did, :key_id])
    create index(:did_documents, [:active])
  end
end
