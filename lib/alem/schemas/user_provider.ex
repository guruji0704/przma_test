defmodule Alem.Schemas.UserProvider do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :string

  schema "user_providers" do
    belongs_to :user, Alem.Pleroma.User

    field :provider_type,   :string
    field :adapter,         :string
    field :label,           :string
    field :endpoint,        :string
    field :region,          :string
    field :bucket,          :string
    field :enc_access_key,  :string
    field :enc_secret_key,  :string
    field :is_active,       :boolean, default: false
    field :is_verified,     :boolean, default: false
    field :verified_at,     :utc_datetime
    field :extra_config,    :map, default: %{}

    field :access_key, :string, virtual: true
    field :secret_key, :string, virtual: true

    timestamps(type: :utc_datetime)
  end

  def changeset(provider, attrs) do
    provider
    |> cast(attrs, [:user_id, :provider_type, :adapter, :label, :endpoint,
                    :region, :bucket, :is_active, :is_verified, :verified_at,
                    :extra_config, :access_key, :secret_key])
    |> validate_required([:user_id, :provider_type, :adapter, :bucket])
    |> validate_inclusion(:provider_type, ["storage", "vector", "ai"])
    |> validate_inclusion(:adapter, ["s3", "minio", "r2", "backblaze", "localfs"])
    |> encrypt_keys()
  end

  defp encrypt_keys(cs) do
    cs
    |> maybe_encrypt(:access_key, :enc_access_key)
    |> maybe_encrypt(:secret_key, :enc_secret_key)
  end

  defp maybe_encrypt(cs, vf, ef) do
    case Ecto.Changeset.get_change(cs, vf) do
      nil -> cs
      val -> Ecto.Changeset.put_change(cs, ef, Base.encode64(val))
    end
  end
end
