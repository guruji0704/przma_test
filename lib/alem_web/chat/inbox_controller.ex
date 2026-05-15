defmodule AlemWeb.Chat.InboxController do
  @moduledoc """
  Inbox — ActivityStreams activities delivered to the authenticated user.
  Covers: room invites, joins, leaves, DM requests, mentions, room deletions.
  Chat messages are NOT in the inbox.
  """
  use AlemWeb, :controller
  alias Alem.ActivityStream

  def index(conn, params) do
    user        = conn.assigns.current_user
    limit       = parse_int(params["per_page"], 20)
    before_id   = params["before_id"]
    unread_only = params["unread"] == "true"

    items = ActivityStream.list_inbox(user.id,
      limit:       limit,
      before_id:   before_id,
      unread_only: unread_only
    )

    json(conn, %{
      inbox:        Enum.map(items, &ActivityStream.inbox_item_json/1),
      unread_count: ActivityStream.unread_inbox_count(user.id),
      count:        length(items)
    })
  end

  def mark_read(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case ActivityStream.mark_inbox_read(user.id, id) do
      {:ok, item} ->
        json(conn, %{ok: true, id: item.id, read: true})
      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "Inbox item not found"})
    end
  end

  def mark_all_read(conn, _params) do
    user = conn.assigns.current_user
    {count, _} = ActivityStream.mark_all_inbox_read(user.id)
    json(conn, %{ok: true, marked_read: count})
  end

  defp parse_int(v, d) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> d
    end
  end
  defp parse_int(_, d), do: d
end