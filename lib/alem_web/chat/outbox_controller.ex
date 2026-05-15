defmodule AlemWeb.Chat.OutboxController do
  @moduledoc """
  Outbox — ActivityStreams activities published by the authenticated user.
  Covers: invites sent, rooms joined/left, DMs created, rooms deleted.
  """
  use AlemWeb, :controller
  alias Alem.ActivityStream

  def index(conn, params) do
    user      = conn.assigns.current_user
    limit     = parse_int(params["per_page"], 20)
    before_id = params["before_id"]

    activities = ActivityStream.list_outbox(user.id,
      limit:     limit,
      before_id: before_id
    )

    json(conn, %{
      outbox: Enum.map(activities, &ActivityStream.activity_json/1),
      actor:  user.id,
      count:  length(activities),
      total:  ActivityStream.outbox_count(user.id)
    })
  end

  defp parse_int(v, d) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> d
    end
  end
  defp parse_int(_, d), do: d
end