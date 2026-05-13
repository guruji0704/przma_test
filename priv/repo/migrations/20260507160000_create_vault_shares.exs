defmodule Alem.Repo.Migrations.CreateVaultShares do
  use Ecto.Migration

  def change do
    create table(:vault_shares, primary_key: false) do
      add :share_id,         :uuid,   primary_key: true, default: fragment("gen_random_uuid()")
      add :owner_user_id,    :string, null: false
      add :doc_id,           :string, null: false
      add :source_vault,     :string, null: false
      add :target_vault,     :string, null: false
      add :source_s3_key,    :text,   null: false
      add :filename,         :string
      add :content_type,     :string
      add :recipient_user_id,:string
      add :share_token,      :string, null: false
      add :permission,       :string, null: false, default: "read"
      add :expires_at,       :utc_datetime
      add :revoked_at,       :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:vault_shares, [:share_token])
    create index(:vault_shares, [:owner_user_id])
    create index(:vault_shares, [:recipient_user_id])
    create index(:vault_shares, [:doc_id])
  end
end
