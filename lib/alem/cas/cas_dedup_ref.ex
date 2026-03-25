defmodule Alem.Cas.CasDedupRef do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:dedup_ref_id, :binary_id, autogenerate: true}
  @foreign_key_type :string

  schema "cas_dedup_refs" do
    # Tenant context
    field :tenant_id,           :string
    field :namespace_key,       :string
    field :actor_did,           :string
    belongs_to :user,           Alem.Accounts.User,
      type: :string, foreign_key: :user_id

    # Links
    field :content_hash,        :string
    belongs_to :document,       Alem.Documents.Document,
      type: :binary_id, foreign_key: :document_id

    # Associations
    belongs_to :cas_object,     Alem.Cas.CasObject,
      foreign_key: :content_hash, references: :content_hash,
      define_field: false

    # Per-user private metadata
    # Same S3 bytes — different names/paths/tags per user
    field :vault_path,          :string
    field :user_filename,       :string
    field :user_tags,           {:array, :string}, default: []
    field :version_label,       :string
    # v1.0|draft|final|archived

    # Soft-delete
    # NEVER hard delete — keep for audit trail
    field :is_active,           :boolean, default: true
    field :deactivated_at,      :utc_datetime
    field :deactivated_by_did,  :string

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
        name: :cas_dedup_refs_content_hash_namespace_key_document_id_index,
        message: "This file is already in this namespace"
      )
  end

  def create_changeset(ref, attrs) do
    changeset(ref, Map.put(attrs, :is_active, true))
  end

  # Call when user deletes their copy of a file
  # IMPORTANT: after this, your application must also:
  #   1. DECREMENT cas_objects.ref_count by 1
  #   2. IF ref_count == 0 THEN delete cas_objects row + S3 object
  def deactivate_changeset(ref, deactivated_by_did) do
    ref
    |> change(%{
      is_active: false,
      deactivated_at: DateTime.utc_now(),
      deactivated_by_did: deactivated_by_did
    })
  end
end
