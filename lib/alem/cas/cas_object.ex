defmodule Alem.Cas.CasObject do
  use Ecto.Schema
  import Ecto.Changeset

  # content_hash is set by application (BLAKE3 of raw bytes)
  # Never auto-generated
  @primary_key {:content_hash, :string, autogenerate: false}
  @foreign_key_type :string

  schema "cas_objects" do
    # Tenant context
    field :tenant_id,         :string
    field :namespace_key,     :string
    field :actor_did,         :string
    belongs_to :user,         Alem.Accounts.User,
      type: :string, foreign_key: :user_id

    # Storage
    field :storage_backend,   :string, default: "s3"
    field :storage_key,       :string
    field :media_type,        :string
    field :file_size,         :integer, default: 0
    field :ref_count,         :integer, default: 1

    # Integrity
    field :is_corrupt,        :boolean, default: false
    field :is_verified,       :boolean, default: false
    field :verified_at,       :utc_datetime

    # Content
    field :extracted_text,    :string
    field :duration_seconds,  :integer
    field :width_px,          :integer
    field :height_px,         :integer
    field :page_count,        :integer

    # Effective-date (version history)
    field :effective_from,    :utc_datetime
    field :effective_to,      :utc_datetime
    field :is_current,        :boolean, default: true
    field :superseded_by,     :string
    field :superseded_reason, :string

    has_many :activities,     Alem.Cas.CasActivity,
      foreign_key: :object_hash, references: :content_hash
    has_many :events,         Alem.Cas.CasEvent,
      foreign_key: :content_hash, references: :content_hash
    has_many :dedup_refs,     Alem.Cas.CasDedupRef,
      foreign_key: :content_hash, references: :content_hash

    timestamps(type: :utc_datetime)
  end

  @required [:content_hash, :namespace_key, :actor_did, :user_id,
             :storage_key, :effective_from]
  @optional [:tenant_id, :storage_backend, :media_type, :file_size,
             :ref_count, :is_corrupt, :is_verified, :verified_at,
             :extracted_text, :duration_seconds, :width_px, :height_px,
             :page_count, :effective_to, :is_current, :superseded_by,
             :superseded_reason]

  def changeset(cas_object, attrs) do
    cas_object
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:storage_backend, ["s3", "local", "turso"])
    |> validate_number(:ref_count, greater_than_or_equal_to: 0)
    |> validate_inclusion(:superseded_reason,
        ["update", "replace", "correction", "deletion", nil])
  end

  def ingest_changeset(cas_object, attrs) do
    attrs_with_defaults = Map.merge(%{
      effective_from: DateTime.utc_now(),
      is_current: true,
      is_corrupt: false,
      is_verified: false,
      ref_count: 1
    }, attrs)
    changeset(cas_object, attrs_with_defaults)
  end

  # Call this when a new version supersedes this object
  def supersede_changeset(cas_object, new_hash, reason \\ "update") do
    cas_object
    |> change(%{
      effective_to: DateTime.utc_now(),
      is_current: false,
      superseded_by: new_hash,
      superseded_reason: reason
    })
  end
end
