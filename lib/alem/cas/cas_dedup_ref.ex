defmodule Alem.Cas.CasDedupRef do
  @moduledoc """
  Each user's PERSONAL pointer to a shared CAS object.
  Same S3 bytes → same cas_objects row → multiple dedup_refs (one per user).
  Each user can have their own filename, tags, vault_path for the same file.
  Soft-delete only — rows kept for audit trail.

  When user "deletes" a file:
    1. SET is_active = false
    2. DECREMENT cas_objects.ref_count
    3. IF ref_count == 0 THEN delete cas_objects row + S3 bytes
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:dedup_ref_id, :binary_id, autogenerate: true}
  @foreign_key_type :string

  schema "cas_dedup_refs" do
    field :tenant_id,          :string
    field :namespace_key,      :string
    field :actor_did,          :string
    belongs_to :user,          Alem.Pleroma.User,
      type: :string, foreign_key: :user_id

    field :content_hash,       :string
    belongs_to :document,      Alem.Schemas.Document,
      type: :string, foreign_key: :document_id

    belongs_to :cas_object,    Alem.Cas.CasObject,
      foreign_key: :content_hash, references: :content_hash,
      define_field: false

    # Per-user private metadata
    field :vault_path,         :string
    field :user_filename,      :string
    field :user_tags,          {:array, :string}, default: []
    field :version_label,      :string

    # Soft-delete
    field :is_active,          :boolean, default: true
    field :deactivated_at,     :utc_datetime
    field :deactivated_by_did, :string

    timestamps(type: :utc_datetime)
  end

  @required [:tenant_id, :namespace_key, :actor_did, :user_id,
             :content_hash, :document_id]
  @optional [:vault_path, :user_filename, :user_tags, :version_label,
             :is_active, :deactivated_at, :deactivated_by_did]

  def changeset(ref, attrs) do
    ref
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint(
        [:content_hash, :namespace_key, :document_id],
        message: "This file is already linked in this namespace"
      )
  end

  def create_changeset(ref, attrs) do
    changeset(ref, Map.put(attrs, :is_active, true))
  end

  def deactivate_changeset(ref, deactivated_by_did) do
    ref
    |> change(%{
      is_active:          false,
      deactivated_at:     DateTime.utc_now(),
      deactivated_by_did: deactivated_by_did
    })
  end
end
