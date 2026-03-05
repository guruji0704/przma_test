defmodule Alem.Pleroma.User do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "users" do
    field :nickname, :string
    field :email, :string
    field :name, :string
    field :bio, :string
    field :avatar, :string
    field :password_hash, :string
    field :password, :string, virtual: true
    field :is_active, :boolean, default: true
    field :is_admin, :boolean, default: false
    field :is_moderator, :boolean, default: false
    field :did_id, :string
    field :is_verified,    :boolean, default: false
    field :otp_code,       :string
    field :otp_expires_at, :naive_datetime
    field :otp_attempts,   :integer, default: 0

    timestamps()
  end

  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:nickname, :email, :password, :name, :bio])
    |> validate_required([:nickname, :password])
    |> validate_length(:nickname, min: 1, max: 30)
    |> validate_length(:password, min: 6)
    |> validate_format(:email, ~r/@/)
    |> unique_constraint(:nickname)
    |> unique_constraint(:email)
    |> put_password_hash()
    |> put_id()
  end

  def did_changeset(user, did_id) do
    user
    |> cast(%{did_id: did_id}, [:did_id])
    |> validate_required([:did_id])
    |> unique_constraint(:did_id)
  end

  defp put_password_hash(%Ecto.Changeset{valid?: true, changes: %{password: password}} = changeset) do
    change(changeset, password_hash: hash_password(password))
  end

  defp put_password_hash(changeset), do: changeset

  defp put_id(changeset) do
    case get_field(changeset, :id) do
      nil -> put_change(changeset, :id, generate_id())
      _ -> changeset
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 16)
  end

  # Use Pbkdf2 for password hashing
  defp hash_password(password) do
    Pbkdf2.hash_pwd_salt(password)
  end

  # Verify password
  def verify_password(user, password) do
    Pbkdf2.verify_pass(password, user.password_hash)
  end

  #Email verification functions
  def generate_otp do
    :rand.uniform(999999)
    |> Integer.to_string()
    |> String.pad_leading(6, "0")
  end

  def otp_changeset(user, otp_code) do
    expires_at = NaiveDateTime.add(NaiveDateTime.utc_now(), 600, :second)
    |> NaiveDateTime.truncate(:second)

    user
    |> Ecto.Changeset.change(%{
      otp_code: otp_code,
      otp_expires_at: expires_at,
      otp_attempts: 0
    })
  end

  def verify_otp_changeset(user) do
    user
    |> Ecto.Changeset.change(%{
      is_verified: true,
      otp_code: nil,
      otp_expires_at: nil
    })
  end
end
