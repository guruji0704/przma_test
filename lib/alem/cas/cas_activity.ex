defmodule Alem.Cas.CasActivity do
  @moduledoc """
  Activity log — WHAT happened to a file.
  One row per user action: Upload, Delete, View, Share, etc.
  Used for audit trail, PRZMA perception dimensions, and sync conflict resolution.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:activity_id, :binary_id, autogenerate: true}
  @foreign_key_type :string

  schema "cas_activities" do
    field :tenant_id,         :string
    field :namespace_key,     :string
    field :actor_did,         :string
    belongs_to :user,         Alem.Pleroma.User,
      type: :string, foreign_key: :user_id
    field :auth_id,           :string

    # The action
    field :verb,              :string
    # Upload|Create|Delete|View|Share|Search|Login|Logout|Sync
    field :object_hash,       :string
    # NULL for non-file verbs (Login, Search)
    field :object_type,       :string
    field :object_id,         :string
    field :object_path,       :string
    field :target_did,        :string
    field :device_id,         :string
    field :session_id,        :string
    field :platform,          :string
    field :client_version,    :string

    # PRZMA perception dimensions
    field :seven_p_dimension, :string
    field :light_signal,      :string
    field :context,           :map, default: %{}

    field :published_at,      :utc_datetime
    field :duration_ms,       :integer

    # Sync conflict resolution
    field :effective_from,    :utc_datetime
    field :effective_to,      :utc_datetime
    field :is_active,         :boolean, default: true
    field :is_voided,         :boolean, default: false
    field :voided_at,         :utc_datetime
    field :voided_by_did,     :string
    field :void_reason,       :string

    belongs_to :cas_object,   Alem.Cas.CasObject,
      foreign_key: :object_hash, references: :content_hash,
      define_field: false
    has_many :events,         Alem.Cas.CasEvent,
      foreign_key: :activity_id, references: :activity_id

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @verbs ~w(Upload Create Delete View Share Search Login Logout Sync Comment React)

  @required [:tenant_id, :namespace_key, :actor_did, :user_id,
             :auth_id, :verb, :published_at, :effective_from]
  @optional [:object_hash, :object_type, :object_id, :object_path,
             :target_did, :device_id, :session_id, :platform,
             :client_version, :seven_p_dimension, :light_signal, :context,
             :duration_ms, :effective_to, :is_active, :is_voided,
             :voided_at, :voided_by_did, :void_reason]

  def changeset(activity, attrs) do
    activity
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:verb, @verbs)
  end

  def create_changeset(activity, attrs) do
    now = DateTime.utc_now()
    attrs_with_defaults = Map.merge(%{
      published_at:   now,
      effective_from: now,
      is_active:      true,
      is_voided:      false
    }, attrs)
    changeset(activity, attrs_with_defaults)
  end

  def void_changeset(activity, voided_by_did, reason) do
    activity
    |> change(%{
      is_active:    false,
      is_voided:    true,
      voided_at:    DateTime.utc_now(),
      voided_by_did: voided_by_did,
      void_reason:  reason,
      effective_to: DateTime.utc_now()
    })
  end
end
