defmodule Alem.Schemas.VaultShare do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:share_id, :binary_id, autogenerate: true}
  schema "vault_shares" do
    field :owner_user_id,     :string
    field :doc_id,            :string
    field :source_vault,      :string
    field :target_vault,      :string
    field :source_s3_key,     :string
    field :filename,          :string
    field :content_type,      :string
    field :recipient_user_id, :string
    field :share_token,       :string
    field :permission,        :string, default: "read"
    field :expires_at,        :utc_datetime
    field :revoked_at,        :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(share, attrs) do
    share
    |> cast(attrs, [:owner_user_id, :doc_id, :source_vault, :target_vault,
                    :source_s3_key, :filename, :content_type, :recipient_user_id,
                    :share_token, :permission, :expires_at, :revoked_at])
    |> validate_required([:owner_user_id, :doc_id, :source_vault, :target_vault,
                          :source_s3_key, :share_token])
    |> validate_inclusion(:source_vault, ["personal", "private", "social"])
    |> validate_inclusion(:target_vault, ["personal", "private", "social"])
    |> validate_inclusion(:permission,   ["read", "download"])
    |> unique_constraint(:share_token)
  end
end
