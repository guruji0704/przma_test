defmodule AlemWeb.Chat.NotificationController do
  @moduledoc """
  Notifications — typed alerts derived from inbox activities.
  Types: invite | join | leave | mention | dm_request | room_deleted
  """
  use AlemWeb, :controller
  alias Alem.ActivityStream

  def index(conn, params) do
    user        = conn.assigns.current_user
    limit       = parse_int(params["per_page"], 20)
    before_id   = params["before_id"]
    unread_only = params["unread"] == "true"

    notifications = ActivityStream.list_notifications(user.id,
      limit:       limit,
      before_id:   before_id,
      unread_only: unread_only
    )

    json(conn, %{
      notifications: Enum.map(notifications, &ActivityStream.notification_json/1),
      unread_count:  ActivityStream.unread_notification_count(user.id),
      count:         length(notifications)
    })
  end

  def mark_read(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case ActivityStream.mark_notification_read(user.id, id) do
      {:ok, n} ->
        json(conn, %{ok: true, id: n.id, read: true})
      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "Notification not found"})
    end
  end

  def mark_all_read(conn, _params) do
    user = conn.assigns.current_user
    {count, _} = ActivityStream.mark_all_notifications_read(user.id)
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