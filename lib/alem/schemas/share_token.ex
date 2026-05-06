defmodule Alem.Schemas.ShareToken do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @scopes   ~w(read read_write)
  @folders  ~w(personal private public)

  schema "share_tokens" do
    field :issuer_did,    :string
    field :target_did,    :string    # null = anyone with the link
    field :namespace_key, :string
    field :document_id,   :binary_id # null = entire namespace
    field :content_hash,  :string
    field :folder,        :string, default: "personal"
    field :scope,         :string, default: "read"
    field :expires_at,    :utc_datetime
    field :is_memorial,   :boolean, default: false
    field :note,          :string
    field :signature,     :string
    field :revoked_at,    :utc_datetime
    field :last_used_at,  :utc_datetime
    field :use_count,     :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def changeset(token, attrs) do
    token
    |> cast(attrs, [:issuer_did, :target_did, :namespace_key, :document_id,
                    :content_hash, :folder, :scope, :expires_at,
                    :is_memorial, :note, :signature])
    |> validate_required([:issuer_did, :expires_at, :signature])
    |> validate_inclusion(:scope,  @scopes)
    |> validate_inclusion(:folder, @folders)
    |> validate_expiry()
  end

  defp validate_expiry(changeset) do
    case get_change(changeset, :expires_at) do
      nil -> changeset
      exp ->
        if DateTime.compare(exp, DateTime.utc_now()) == :gt,
          do: changeset,
          else: add_error(changeset, :expires_at, "must be in the future")
    end
  end

  @doc "True if token is still usable right now."
  def valid?(%__MODULE__{} = t) do
    t.revoked_at == nil and
    DateTime.compare(t.expires_at, DateTime.utc_now()) == :gt
  end
end
