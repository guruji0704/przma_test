defmodule AlemWeb.ChatChannel do
  use AlemWeb, :channel

  alias Alem.Chat
  alias AlemWeb.Presence

  # Topic format: "vault_chat:{vault}:{room_id}"
  @impl true
  def join("vault_chat:" <> rest, _params, socket) do
    case String.split(rest, ":", parts: 2) do
      [vault, room_id] when vault in ["personal", "private", "social"] ->
        case Chat.get_room(room_id) do
          nil ->
            {:error, %{reason: "room_not_found"}}

          room when room.vault == vault ->
            uid = socket.assigns.user_id

            # Private rooms: must already be a member — no auto-join
            if vault == "private" and not room.is_dm and not Chat.is_member?(room_id, uid) do
              {:error, %{reason: "not_a_member"}}
            else
              socket =
                socket
                |> assign(:vault, vault)
                |> assign(:room_id, room_id)

              unless room.is_dm do
                Chat.add_member(room_id, uid, socket.assigns.username)
              end

              send(self(), :after_join)
              {:ok, %{user_id: uid, username: socket.assigns.username}, socket}
            end

          _ ->
            {:error, %{reason: "vault_mismatch"}}
        end

      _ ->
        {:error, %{reason: "invalid_topic"}}
    end
  end

  def join(_, _, _), do: {:error, %{reason: "invalid_topic"}}

  @impl true
  def handle_info(:after_join, socket) do
    {:ok, _} =
      Presence.track(socket, socket.assigns.user_id, %{
        online_at: System.system_time(:second),
        username:  socket.assigns.username
      })

    push(socket, "presence_state", Presence.list(socket))

    # Push message history
    messages = Chat.list_messages(socket.assigns.room_id, limit: 50)
    push(socket, "message_history", %{messages: Enum.map(messages, &Chat.message_json/1)})

    # Push current member list
    members = Chat.list_members(socket.assigns.room_id)
    push(socket, "member_list", %{members: Enum.map(members, &Chat.member_json/1)})

    {:noreply, socket}
  end

  # ── Inbound events ───────────────────────────────────────────────────────────

  @impl true
  def handle_in("send_message", params, socket) do
    attrs = %{
      room_id:     socket.assigns.room_id,
      user_id:     socket.assigns.user_id,
      username:    socket.assigns.username,
      body:        params["body"] |> to_string() |> String.slice(0, 4000),
      msg_type:    Map.get(params, "msg_type", "text"),
      file_doc_id: Map.get(params, "file_doc_id"),
      file_name:   Map.get(params, "file_name"),
      file_type:   Map.get(params, "file_type"),
      vault:       socket.assigns.vault
    }

    case Chat.create_message(attrs) do
      {:ok, msg} ->
        broadcast!(socket, "new_message", Chat.message_json(msg))
        {:reply, {:ok, Chat.message_json(msg)}, socket}

      {:error, changeset} ->
        errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
        {:reply, {:error, %{errors: errors}}, socket}
    end
  end

  def handle_in("typing", _params, socket) do
    broadcast_from!(socket, "typing", %{username: socket.assigns.username})
    {:noreply, socket}
  end

  def handle_in("delete_message", %{"id" => id}, socket) do
    case Chat.soft_delete_message(id, socket.assigns.user_id) do
      {:ok, _}               -> broadcast!(socket, "message_deleted", %{id: id})
                                 {:reply, :ok, socket}
      {:error, :unauthorized} -> {:reply, {:error, %{reason: "unauthorized"}}, socket}
      {:error, :not_found}    -> {:reply, {:error, %{reason: "not_found"}}, socket}
    end
  end

  def handle_in("load_more", %{"before_id" => before_id}, socket) do
    messages = Chat.list_messages(socket.assigns.room_id, limit: 30, before_id: before_id)
    {:reply, {:ok, %{messages: Enum.map(messages, &Chat.message_json/1)}}, socket}
  end

  # Broadcast a "room_invite" event to a user topic so invited user sees the room.
  # Broadcasts to both the short Pleroma user_id and the DID key since clients may
  # subscribe using either identifier.
  def notify_invite(user_id, did_key, room) do
    payload = Chat.room_json(room)
    AlemWeb.Endpoint.broadcast("user:#{user_id}", "room_invite", payload)
    if did_key, do: AlemWeb.Endpoint.broadcast("user:#{did_key}", "room_invite", payload)
  end
end
