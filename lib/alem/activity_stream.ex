defmodule Alem.ActivityStream do
  @moduledoc """
  Inbox/Outbox context using ActivityStreams format.

  Chat messages are NOT activities.
  Only social events become activities:
    - Invite  → someone was invited to a room
    - Join    → someone joined a room
    - Leave   → someone left a room
    - Create  → a DM room was created
    - Delete  → a room was deleted
    - Mention → someone was @mentioned
  """

  import Ecto.Query
  alias Alem.Repo
  alias Alem.Schemas.{Activity, InboxItem, Notification, ChatRoomMember}
  alias Phoenix.PubSub

  # ── Publishing ──────────────────────────────────────────────────────────────

  @doc """
  Publish an activity, fan out to recipient inboxes and notifications,
  and push real-time PubSub events to each recipient.

  Required:
    - type          — "Invite" | "Join" | "Leave" | "Create" | "Delete" | "Mention"
    - actor_id      — user_id of the person performing the action
    - actor_username
    - object_type   — "ChatRoom" | "Note"
    - object_data   — map snapshot of the object (room name, vault, etc.)

  Options:
    - room_id           — fans out to all room members except actor
    - recipients        — explicit list of %{user_id, username} (used for invites/DMs)
    - vault             — vault string
    - object_id         — id of the related object
    - notification_type — overrides the derived notification type
  """
  def publish(type, actor_id, actor_username, object_type, object_data, opts \\ []) do
    room_id   = opts[:room_id]
    vault     = opts[:vault]
    object_id = opts[:object_id]
    now       = utc_now()

    Repo.transaction(fn ->
      {:ok, activity} =
        %Activity{}
        |> Activity.changeset(%{
          type:           type,
          actor_id:       to_string(actor_id),
          actor_username: actor_username,
          object_type:    object_type,
          object_id:      object_id,
          object_data:    object_data,
          room_id:        room_id,
          vault:          vault,
          published_at:   now
        })
        |> Repo.insert()

      recipients = resolve_recipients(actor_id, room_id, opts[:recipients])

      Enum.each(recipients, fn r ->
        deliver_to_inbox(r.user_id, activity)
        create_notification(r, activity, opts[:notification_type])
        push_realtime(r.user_id, activity)
      end)

      activity
    end)
  end

  # ── Recipient resolution ────────────────────────────────────────────────────

  defp resolve_recipients(_actor_id, nil, explicit) when is_list(explicit), do: explicit

  defp resolve_recipients(actor_id, room_id, nil) do
    from(m in ChatRoomMember,
      where: m.room_id == ^room_id and m.user_id != ^to_string(actor_id),
      select: %{user_id: m.user_id, username: m.username}
    ) |> Repo.all()
  end

  defp resolve_recipients(actor_id, room_id, explicit) when is_list(explicit) do
    room_members = from(m in ChatRoomMember,
      where: m.room_id == ^room_id and m.user_id != ^to_string(actor_id),
      select: %{user_id: m.user_id, username: m.username}
    ) |> Repo.all()

    existing_ids = MapSet.new(room_members, & &1.user_id)

    extra = Enum.reject(explicit, fn r ->
      MapSet.member?(existing_ids, r.user_id)
    end)

    room_members ++ extra
  end

  defp resolve_recipients(_, _, _), do: []

  # ── Inbox delivery ──────────────────────────────────────────────────────────

  defp deliver_to_inbox(user_id, activity) do
    %InboxItem{}
    |> InboxItem.changeset(%{
      user_id:     to_string(user_id),
      activity_id: activity.id
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :activity_id])
  end

  # ── Notification creation ───────────────────────────────────────────────────

  defp create_notification(recipient, activity, override_type) do
    type = override_type || derive_notification_type(activity.type)

    %Notification{}
    |> Notification.changeset(%{
      user_id:       to_string(recipient.user_id),
      from_user_id:  activity.actor_id,
      from_username: activity.actor_username,
      type:          type,
      activity_id:   activity.id,
      room_id:       activity.room_id
    })
    |> Repo.insert()
  end

  defp derive_notification_type("Invite"),  do: "invite"
  defp derive_notification_type("Join"),    do: "join"
  defp derive_notification_type("Leave"),   do: "leave"
  defp derive_notification_type("Create"),  do: "dm_request"
  defp derive_notification_type("Delete"),  do: "room_deleted"
  defp derive_notification_type("Mention"), do: "mention"
  defp derive_notification_type(_),         do: "invite"

  # ── Real-time push ──────────────────────────────────────────────────────────

  defp push_realtime(user_id, activity) do
    PubSub.broadcast(
      Alem.PubSub,
      "user:#{user_id}:inbox",
      {:new_inbox_item, activity_json(activity)}
    )
  end

  # ── Outbox ──────────────────────────────────────────────────────────────────

  @doc "All activities published by a user, newest first, paginated."
  def list_outbox(actor_id, opts \\ []) do
    limit     = opts[:limit] || 20
    before_id = opts[:before_id]

    query =
      from a in Activity,
        where: a.actor_id == ^to_string(actor_id),
        order_by: [desc: a.published_at],
        limit: ^limit

    query =
      if before_id do
        case Repo.get(Activity, before_id) do
          nil -> query
          ref -> where(query, [a], a.published_at < ^ref.published_at)
        end
      else
        query
      end

    query |> Repo.all() |> Enum.reverse()
  end

  def outbox_count(actor_id) do
    Repo.one(
      from a in Activity,
        where: a.actor_id == ^to_string(actor_id),
        select: count(a.id)
    ) || 0
  end

  # ── Inbox ────────────────────────────────────────────────────────────────────

  @doc "All inbox items for a user, newest first, paginated."
  def list_inbox(user_id, opts \\ []) do
    limit       = opts[:limit] || 20
    before_id   = opts[:before_id]
    unread_only = opts[:unread_only] || false

    query =
      from i in InboxItem,
        join: a in assoc(i, :activity),
        where: i.user_id == ^to_string(user_id),
        preload: [activity: a],
        order_by: [desc: i.inserted_at],
        limit: ^limit

    query = if unread_only, do: where(query, [i], i.read == false), else: query

    query =
      if before_id do
        case Repo.get(InboxItem, before_id) do
          nil -> query
          ref -> where(query, [i], i.inserted_at < ^ref.inserted_at)
        end
      else
        query
      end

    query |> Repo.all() |> Enum.reverse()
  end

  def mark_inbox_read(user_id, item_id) do
    case Repo.get_by(InboxItem, id: item_id, user_id: to_string(user_id)) do
      nil  -> {:error, :not_found}
      item ->
        item
        |> Ecto.Changeset.change(%{read: true, read_at: utc_now()})
        |> Repo.update()
    end
  end

  def mark_all_inbox_read(user_id) do
    from(i in InboxItem,
      where: i.user_id == ^to_string(user_id) and i.read == false
    )
    |> Repo.update_all(set: [read: true, read_at: utc_now()])
  end

  def unread_inbox_count(user_id) do
    Repo.one(
      from i in InboxItem,
        where: i.user_id == ^to_string(user_id) and i.read == false,
        select: count(i.id)
    ) || 0
  end

  # ── Notifications ────────────────────────────────────────────────────────────

  @doc "All notifications for a user, newest first."
  def list_notifications(user_id, opts \\ []) do
    limit       = opts[:limit] || 20
    before_id   = opts[:before_id]
    unread_only = opts[:unread_only] || false

    query =
      from n in Notification,
        join: a in assoc(n, :activity),
        where: n.user_id == ^to_string(user_id),
        preload: [activity: a],
        order_by: [desc: n.inserted_at],
        limit: ^limit

    query = if unread_only, do: where(query, [n], n.read == false), else: query

    query =
      if before_id do
        case Repo.get(Notification, before_id) do
          nil -> query
          ref -> where(query, [n], n.inserted_at < ^ref.inserted_at)
        end
      else
        query
      end

    query |> Repo.all() |> Enum.reverse()
  end

  def mark_notification_read(user_id, notif_id) do
    case Repo.get_by(Notification, id: notif_id, user_id: to_string(user_id)) do
      nil -> {:error, :not_found}
      n   ->
        n
        |> Ecto.Changeset.change(%{read: true, read_at: utc_now()})
        |> Repo.update()
    end
  end

  def mark_all_notifications_read(user_id) do
    from(n in Notification,
      where: n.user_id == ^to_string(user_id) and n.read == false
    )
    |> Repo.update_all(set: [read: true, read_at: utc_now()])
  end

  def unread_notification_count(user_id) do
    Repo.one(
      from n in Notification,
        where: n.user_id == ^to_string(user_id) and n.read == false,
        select: count(n.id)
    ) || 0
  end

  # ── Serialization ────────────────────────────────────────────────────────────

  def activity_json(%Activity{} = a) do
    %{
      id:             a.id,
      type:           a.type,
      actor:          %{id: a.actor_id, username: a.actor_username},
      object:         %{type: a.object_type, id: a.object_id, data: a.object_data},
      room_id:        a.room_id,
      vault:          a.vault,
      to:             a.to,
      published_at:   a.published_at
    }
  end

  def inbox_item_json(%InboxItem{} = i) do
    %{
      id:          i.id,
      read:        i.read,
      read_at:     i.read_at,
      received_at: i.inserted_at,
      activity:    if(i.activity, do: activity_json(i.activity), else: nil)
    }
  end

  def notification_json(%Notification{} = n) do
    %{
      id:            n.id,
      type:          n.type,
      from:          %{id: n.from_user_id, username: n.from_username},
      room_id:       n.room_id,
      read:          n.read,
      read_at:       n.read_at,
      created_at:    n.inserted_at,
      activity:      if(n.activity, do: activity_json(n.activity), else: nil)
    }
  end

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end