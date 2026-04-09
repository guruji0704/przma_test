defmodule Alem.Sync.Session do
  @moduledoc """
  Represents an active sync session for a user.
  """

  @enforce_keys [:id, :user_id, :started_at]
  defstruct [
    :id,
    :user_id,
    :client_info,
    :started_at,
    :last_activity,
    changes_applied: 0,
    changes_received: 0,
    bytes_uploaded: 0,
    bytes_downloaded: 0
  ]

  @type t :: %__MODULE__{
    id: String.t(),
    user_id: String.t(),
    client_info: map(),
    started_at: DateTime.t(),
    last_activity: DateTime.t(),
    changes_applied: non_neg_integer(),
    changes_received: non_neg_integer(),
    bytes_uploaded: non_neg_integer(),
    bytes_downloaded: non_neg_integer()
  }

  def new(user_id, client_info \\ %{}) do
    now = DateTime.utc_now()

    %__MODULE__{
      id: generate_id(),
      user_id: user_id,
      client_info: client_info,
      started_at: now,
      last_activity: now
    }
  end

  def update_activity(session) do
    %{session | last_activity: DateTime.utc_now()}
  end

  def record_changes_applied(session, count) do
    %{session | changes_applied: session.changes_applied + count}
  end

  def record_changes_received(session, count) do
    %{session | changes_received: session.changes_received + count}
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
