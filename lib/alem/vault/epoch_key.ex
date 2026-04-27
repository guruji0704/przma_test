defmodule Alem.Vault.EpochKey do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:epoch_id, :integer, autogenerate: false}

  schema "epoch_keys" do
    field :public_key_b64,      :string
    field :enc_private_key_b64, :string
    field :started_at,          :utc_datetime
    field :expires_at,          :utc_datetime
    field :grace_until,         :utc_datetime
    field :is_current,          :boolean, default: false
  end

  def changeset(key, attrs) do
    key
    |> cast(attrs, [:epoch_id, :public_key_b64, :enc_private_key_b64,
                    :started_at, :expires_at, :grace_until, :is_current])
    |> validate_required([:epoch_id, :public_key_b64, :started_at, :expires_at])
  end
end
