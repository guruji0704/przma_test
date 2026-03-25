defmodule Alem.Cas.CasActivity do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:activity_id, :binary_id, autogenerate: true}
  @foreign_key_type :string

  schema "cas_activities" do
    # Tenant context
    field :tenant_id,         :string
    field :namespace_key,     :string
    field :actor_did,         :string
    belongs_to :user,         Alem.Accounts.User,
      type: :string, foreign_key: :user_id
    field :auth_id,           :string

    # Action
    field :verb,              :string
    field :object_hash,       :string
    field :object_type,       :string
    field :object_id,         :string
    field :object_path,       :string
    field :target_did,        :string
    field :device_id,         :string
    field :session_id,        :string
    field :platform,          :string
    field :client_version,    :string

    # PRZMA dimensions
    field :seven_p_dimension, :string
    field :light_signal,      :string
    field :context,           :map, default: %{}

    # Timing
    field :published_at,      :utc_datetime
    field :duration_ms,       :integer

    # Effective-record (sync conflict resolution)
    field :effective_from,    :utc_datetime
    field :effective_to,      :utc_datetime
    field :is_active,         :boolean, default: true
    field :is_voided,         :boolean, default: false
    field :voided_at,         :utc_datetime
    field :voided_by_did,     :string
    field :void_reason,       :string

    # Associations
    belongs_to :cas_object,   Alem.Cas.CasObject,
      foreign_key: :object_hash, references: :content_hash,
      define_field: false
    has_many :events,         Alem.Cas.CasEvent,
      foreign_key: :activity_id, references: :activity_id

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @verbs ~w(Upload Create Delete View Share Search Login Logout
            Sync Comment React Invite Join Leave Export Import)

  @seven_p ~w(presence people portfolio progress perspectives pursuits purpose)

  @light_signals ~w(L i G H T)

  @void_reasons ~w(sync_conflict admin_correction duplicate test_data user_request)

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
    |> validate_inclusion(:seven_p_dimension, @seven_p ++ [nil])
    |> validate_inclusion(:light_signal, @light_signals ++ [nil])
    |> validate_inclusion(:void_reason, @void_reasons ++ [nil])
  end

  def create_changeset(activity, attrs) do
    now = DateTime.utc_now()
    attrs_with_defaults = Map.merge(%{
      published_at: now,
      effective_from: now,
      is_active: true,
      is_voided: false
    }, attrs)
    changeset(activity, attrs_with_defaults)
  end

  # Call when voiding a record (sync conflict resolution)
  def void_changeset(activity, voided_by_did, reason) do
    activity
    |> change(%{
      is_active: false,
      is_voided: true,
      voided_at: DateTime.utc_now(),
      voided_by_did: voided_by_did,
      void_reason: reason,
      effective_to: DateTime.utc_now()
    })
    |> validate_inclusion(:void_reason, @void_reasons)
  end
end
