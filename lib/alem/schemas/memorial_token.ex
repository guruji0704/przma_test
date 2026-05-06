defmodule Alem.Schemas.MemorialToken do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "memorial_tokens" do
    field :owner_did,          :string
    field :trusted_dids,       {:array, :string}, default: []
    field :quorum,             :integer, default: 1
    field :scope_folders,      {:array, :string}, default: ["personal"]
    # Always ["personal"] — Private is NEVER included
    field :expiry_days,        :integer, default: 365
    field :is_activated,       :boolean, default: false
    field :activated_at,       :utc_datetime
    field :activated_by,       {:array, :string}, default: []
    field :generated_token_id, :binary_id
    field :revoked_at,         :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(token, attrs) do
    token
    |> cast(attrs, [:owner_did, :trusted_dids, :quorum,
                    :scope_folders, :expiry_days])
    |> validate_required([:owner_did, :trusted_dids])
    |> validate_number(:quorum, greater_than: 0)
    |> validate_length(:trusted_dids, min: 1)
    |> validate_no_private_scope()
  end

  defp validate_no_private_scope(changeset) do
    folders = get_field(changeset, :scope_folders) || []
    if "private" in folders,
      do: add_error(changeset, :scope_folders, "private folder cannot be included in memorial token"),
      else: changeset
  end

  @doc "True if quorum of trusted DIDs have voted."
  def quorum_reached?(%__MODULE__{} = t, voted_dids) do
    valid_votes =
      voted_dids
      |> Enum.filter(&(&1 in t.trusted_dids))
      |> Enum.uniq()
      |> length()

    valid_votes >= t.quorum
  end
end
