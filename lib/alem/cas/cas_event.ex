defmodule Alem.Cas.CasEvent do
  @moduledoc """
  Technical event log — every HTTP request that touches files.
  High volume. BIGSERIAL PK (not UUID) saves 8 bytes per row.
  request_id links all events from one HTTP request together for debugging.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:event_seq, :id, autogenerate: true}
  @foreign_key_type :string

  schema "cas_events" do
    field :tenant_id,      :string
    field :namespace_key,  :string
    field :actor_did,      :string
    belongs_to :user,      Alem.Pleroma.User,
      type: :string, foreign_key: :user_id

    belongs_to :activity,  Alem.Cas.CasActivity,
      foreign_key: :activity_id, references: :activity_id,
      type: :binary_id
    field :content_hash,   :string
    field :device_id,      :string
    field :session_id,     :string

    field :event_category, :string
    # file|auth|sync|vault|quota|admin
    field :event_type,     :string
    # file.upload|file.download|auth.login|sync.push etc.

    field :request_id,     :string
    # All events from ONE HTTP request share this ID
    field :ip_hash,        :string
    # SHA256(ip) — never raw IP (GDPR)
    field :user_agent,     :string

    field :is_success,     :boolean, default: true
    field :error_code,     :string
    field :error_message,  :string

    field :duration_ms,    :integer
    field :bytes_in,       :integer, default: 0
    field :bytes_out,      :integer, default: 0
    field :metadata,       :map, default: %{}

    field :occurred_at,    :utc_datetime

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @categories ~w(file auth sync vault quota admin)

  @required [:event_category, :event_type, :occurred_at]
  @optional [:tenant_id, :namespace_key, :actor_did, :user_id,
             :activity_id, :content_hash, :device_id, :session_id,
             :request_id, :ip_hash, :user_agent, :is_success,
             :error_code, :error_message, :duration_ms,
             :bytes_in, :bytes_out, :metadata]

  def changeset(event, attrs) do
    event
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:event_category, @categories)
  end

  def create_changeset(event, attrs) do
    attrs_with_defaults = Map.merge(%{
      occurred_at: DateTime.utc_now(),
      is_success:  true,
      bytes_in:    0,
      bytes_out:   0
    }, attrs)
    changeset(event, attrs_with_defaults)
  end

  def failure_changeset(event, attrs, error_code, error_message) do
    attrs
    |> Map.merge(%{is_success: false, error_code: error_code, error_message: error_message})
    |> then(&create_changeset(event, &1))
  end
end
