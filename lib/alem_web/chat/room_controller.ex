defmodule AlemWeb.Chat.RoomController do
  @moduledoc """
  Chat Room Controller — PostgreSQL-backed rooms with vault scoping.

  All user identity (username, DID) comes from DB via ChatAuth plug.
  Rooms are scoped to vault: personal | private | social.
  DM rooms are created via /dm endpoint.
  Presence data is read from Phoenix.Presence.

  Invite flow (Teams / private vault):
    1. Owner calls POST /rooms/:id/invite  { user_id: "..." }
    2. Target user is added as a DB member + receives room_invite channel event
    3. Target's App refreshes room list automatically (they're now a member)

  Share-link flow (Social / public vault):
    1. Owner copies room ID (the invite code)
    2. Anyone pastes it into "Join by code" → POST /rooms/join_with_token?token=:room_id
    3. Backend adds them as member if room is not full
  """

  use AlemWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Alem.Chat
  alias AlemWeb.{Endpoint, Presence}
  alias Phoenix.PubSub
  alias OpenApiSpex.Schema

  tags ["Chat - Rooms"]

  operation :index,
    summary: "List rooms for a vault",
    parameters: [
      vault: [in: :query, type: :string, required: false,
              description: "personal | private | social (default: personal)"]
    ],
    responses: %{
      200 => {"Rooms",        "application/json", %Schema{type: :object}},
      401 => {"Unauthorized", "application/json", %Schema{type: :object}}
    }

  operation :create,
    summary: "Create a room",
    request_body: {"Room", "application/json", %Schema{
      type: :object,
      required: [:name],
      properties: %{
        name:        %Schema{type: :string,  example: "general"},
        vault:       %Schema{type: :string,  example: "personal"},
        description: %Schema{type: :string,  example: "Team announcements"},
        max_members: %Schema{type: :integer, example: 50}
      }
    }},
    responses: %{
      200 => {"Created",      "application/json", %Schema{type: :object}},
      401 => {"Unauthorized", "application/json", %Schema{type: :object}},
      422 => {"Error",        "application/json", %Schema{type: :object}}
    }

  operation :show,
    summary: "Get room details + member list",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: %{
      200 => {"Room",         "application/json", %Schema{type: :object}},
      401 => {"Unauthorized", "application/json", %Schema{type: :object}},
      404 => {"Not found",    "application/json", %Schema{type: :object}}
    }

  operation :members,
    summary: "Get room members with online presence status",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: %{
      200 => {"Members",      "application/json", %Schema{type: :object}},
      401 => {"Unauthorized", "application/json", %Schema{type: :object}}
    }

  operation :status,
    summary: "Check if room is full (audience mode check)",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: %{
      200 => {"Status",       "application/json", %Schema{type: :object}},
      401 => {"Unauthorized", "application/json", %Schema{type: :object}}
    }

  operation :join,
    summary: "Join a room as member or audience",
    description: """
    Joins using your authenticated username + DID from DB.
    - Private vault rooms require an existing membership (invite first).
    - Room available → mode: member (can send messages)
    - Room full      → mode: audience (read only)
    """,
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: %{
      200 => {"Joined",       "application/json", %Schema{type: :object}},
      401 => {"Unauthorized", "application/json", %Schema{type: :object}},
      403 => {"Forbidden",    "application/json", %Schema{type: :object}},
      404 => {"Not found",    "application/json", %Schema{type: :object}}
    }

  operation :invite,
    summary: "Invite a user to a room (owner only)",
    description: """
    Adds the target user as a DB member AND sends a real-time room_invite
    event to their user channel so their app updates immediately.
    Only the room owner can invite.
    """,
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Invite", "application/json", %Schema{
      type: :object,
      required: [:user_id],
      properties: %{
        user_id:  %Schema{type: :string, example: "abc123"},
        username: %Schema{type: :string, example: "johndoe"}
      }
    }},
    responses: %{
      200 => {"Invited",      "application/json", %Schema{type: :object}},
      401 => {"Unauthorized", "application/json", %Schema{type: :object}},
      403 => {"Forbidden",    "application/json", %Schema{type: :object}},
      404 => {"Not found",    "application/json", %Schema{type: :object}}
    }

  operation :join_with_token,
    summary: "Join a room using a shareable invite code (room ID)",
    description: """
    Used for Social/public rooms. The invite code is the room ID.
    For private (Teams) rooms, use the /invite endpoint instead.
    """,
    parameters: [
      token: [in: :query, type: :string, required: true,
              description: "Room ID (the invite code)"]
    ],
    responses: %{
      200 => {"Joined",       "application/json", %Schema{type: :object}},
      401 => {"Unauthorized", "application/json", %Schema{type: :object}},
      403 => {"Forbidden",    "application/json", %Schema{type: :object}},
      404 => {"Invalid code", "application/json", %Schema{type: :object}}
    }

  operation :leave,
    summary: "Leave a room",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: %{
      200 => {"Left",         "application/json", %Schema{type: :object}},
      401 => {"Unauthorized", "application/json", %Schema{type: :object}},
      404 => {"Not found",    "application/json", %Schema{type: :object}}
    }

  operation :delete,
    summary: "Delete a room and all its messages (owner only)",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: %{
      200 => {"Deleted",       "application/json", %Schema{type: :object}},
      401 => {"Unauthorized",  "application/json", %Schema{type: :object}},
      403 => {"Forbidden",     "application/json", %Schema{type: :object}},
      404 => {"Not found",     "application/json", %Schema{type: :object}}
    }

  operation :dm,
    summary: "Get or create a DM room with another user",
    request_body: {"DM", "application/json", %Schema{
      type: :object,
      required: [:user_id],
      properties: %{
        user_id:  %Schema{type: :string, example: "abc123"},
        username: %Schema{type: :string, example: "johndoe"},
        vault:    %Schema{type: :string, example: "personal"}
      }
    }},
    responses: %{
      200 => {"DM Room",      "application/json", %Schema{type: :object}},
      401 => {"Unauthorized", "application/json", %Schema{type: :object}},
      422 => {"Error",        "application/json", %Schema{type: :object}}
    }

  # ── ACTIONS ──────────────────────────────────────────────────────────────────

  def index(conn, params) do
    user  = conn.assigns.current_user
    vault = Map.get(params, "vault", "personal")

    rooms           = Chat.list_rooms(vault, user.id)
    member_room_ids = Chat.list_user_room_ids(user.id)

    rooms_json =
      Enum.map(rooms, fn room ->
        status    = Chat.room_status(room.id)
        count     = status.member_count
        is_member = MapSet.member?(member_room_ids, room.id)

        base =
          Chat.room_json(room)
          |> Map.merge(%{
            member_count: count,
            max:          room.max_members,
            is_full:      count >= room.max_members,
            is_member:    is_member,
            is_owner:     room.owner_user_id == user.id,
            mode:         if(count >= room.max_members, do: "audience", else: "member")
          })

        if room.is_dm do
          partner_id = (room.dm_user_ids || []) |> Enum.find(fn uid -> uid != user.id end)
          partner_member =
            if partner_id do
              Chat.list_members(room.id) |> Enum.find(fn m -> m.user_id == partner_id end)
            end
          Map.merge(base, %{
            partner_user_id:  partner_id,
            partner_username: if(partner_member, do: partner_member.username, else: partner_id)
          })
        else
          base
        end
      end)

    json(conn, %{rooms: rooms_json, vault: vault})
  end

  def create(conn, params) do
    user  = conn.assigns.current_user
    vault = Map.get(params, "vault", "personal")

    attrs = %{
      name:           params["name"],
      vault:          vault,
      owner_user_id:  user.id,
      owner_username: user.username,
      description:    params["description"],
      max_members:    Map.get(params, "max_members", 50)
    }

    case Chat.create_room(attrs) do
      {:ok, room} ->
        json(conn, %{ok: true, room: Chat.room_json(room)})

      {:error, changeset} ->
        errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
        conn |> put_status(422) |> json(%{error: errors})
    end
  end

  def show(conn, %{"id" => id}) do
    case Chat.get_room(id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "Room not found"})

      room ->
        status  = Chat.room_status(id)
        members = Chat.list_members(id)
        count   = status.member_count

        json(conn,
          Chat.room_json(room)
          |> Map.merge(%{
            members:      Enum.map(members, &Chat.member_json/1),
            member_count: count,
            max:          room.max_members,
            is_full:      count >= room.max_members
          })
        )
    end
  end

  def members(conn, %{"id" => id}) do
    case Chat.get_room(id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "Room not found"})

      room ->
        members    = Chat.list_members(id)
        topic      = "vault_chat:#{room.vault}:#{id}"
        online_ids = Presence.list(topic) |> Map.keys() |> MapSet.new()

        members_json =
          Enum.map(members, fn m ->
            Chat.member_json(m) |> Map.put(:online, MapSet.member?(online_ids, m.user_id))
          end)

        json(conn, %{room: id, members: members_json, count: length(members)})
    end
  end

  def status(conn, %{"id" => id}) do
    case Chat.get_room(id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "Room not found"})

      room ->
        status  = Chat.room_status(id)
        count   = status.member_count
        is_full = count >= room.max_members

        json(conn, %{
          room:    id,
          count:   count,
          max:     room.max_members,
          is_full: is_full,
          mode:    if(is_full, do: "audience", else: "member")
        })
    end
  end

  def join(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case Chat.get_room(id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "Room not found"})

      room ->
        # Private vault rooms require an existing membership (invite-only)
        if room.vault == "private" and not room.is_dm and not Chat.is_member?(id, user.id) do
          conn
          |> put_status(403)
          |> json(%{error: "private_room_requires_invite",
                    message: "Ask the room owner to invite you first"})
        else
          status  = Chat.room_status(id)
          count   = status.member_count
          is_full = count >= room.max_members

          unless is_full do
            Chat.add_member(id, user.id, user.username)

            PubSub.broadcast(Alem.PubSub, "vault_chat:#{room.vault}:#{id}", {:user_joined, %{
              username: user.username,
              did:      user.did
            }})
          end

          json(conn, %{
            ok:          true,
            mode:        if(is_full, do: "audience", else: "member"),
            is_audience: is_full,
            room:        id,
            vault:       room.vault,
            username:    user.username,
            did:         user.did,
            message:     if(is_full,
              do:   "Room full (#{count}/#{room.max_members}) — joined as audience, read only",
              else: "Joined as member — you can send messages"
            )
          })
        end
    end
  end

  def invite(conn, params) do
    user      = conn.assigns.current_user
    room_id   = params["id"]
    target_id = Map.get(params, "user_id", "") |> to_string()
    target_username = Map.get(params, "username", target_id)

    with {:room, room} when not is_nil(room) <- {:room, Chat.get_room(room_id)},
         :ok <- check_owner(room, user.id) do

      # 1. Add target as a DB member so they can join the channel
      Chat.add_member(room_id, target_id, target_username)

      # 2. Look up their DID key for the user channel topic
      did_key =
        case Alem.Repo.get(Alem.Pleroma.User, target_id) do
          nil  -> nil
          u    -> extract_did_key(u.did_id)
        end

      # 3. Push room_invite event to their live user channel
      AlemWeb.ChatChannel.notify_invite(target_id, did_key, room)

      json(conn, %{ok: true, invited: target_id, room: room_id})
    else
      {:room, nil} -> conn |> put_status(404) |> json(%{error: "Room not found"})
      {:error, :not_owner} -> conn |> put_status(403) |> json(%{error: "Only room owner can invite"})
    end
  end

  def join_with_token(conn, %{"token" => token}) do
    user = conn.assigns.current_user

    # The invite code / token is the room ID itself
    case Chat.get_room(token) do
      nil ->
        conn |> put_status(404) |> json(%{error: "Invalid invite code"})

      %{is_dm: true} ->
        conn |> put_status(403) |> json(%{error: "Cannot join DM rooms via invite code"})

      room ->
        # Token IS the authorization — no prior membership check needed.
        # Private rooms are hidden from the room list; possessing the room ID (the share link) is enough.
        status  = Chat.room_status(room.id)
        count   = status.member_count
        is_full = count >= room.max_members

        unless is_full do
          Chat.add_member(room.id, user.id, user.username)

          PubSub.broadcast(Alem.PubSub, "vault_chat:#{room.vault}:#{room.id}", {:user_joined, %{
            username: user.username,
            did:      user.did
          }})
        end

        json(conn, %{
          ok:      true,
          room:    Chat.room_json(room),
          mode:    if(is_full, do: "audience", else: "member"),
          message: if(is_full, do: "Joined as audience (room full)", else: "Joined as member")
        })
    end
  end

  def leave(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case Chat.get_room(id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "Room not found"})

      room ->
        Chat.remove_member(id, user.id)

        PubSub.broadcast(Alem.PubSub, "vault_chat:#{room.vault}:#{id}", {:user_left, %{
          username: user.username,
          did:      user.did
        }})

        json(conn, %{ok: true, username: user.username, did: user.did, room: id})
    end
  end

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    # Fetch room first so we know its vault for the targeted broadcast
    with {:room, room} when not is_nil(room) <- {:room, Chat.get_room(id)},
         {:ok, _} <- Chat.delete_room(id, user.id) do
      # Push room_deleted to every connected WebSocket client in this channel topic
      Endpoint.broadcast("vault_chat:#{room.vault}:#{id}", "room_deleted", %{room_id: id})
      json(conn, %{ok: true, room: id})
    else
      {:room, nil}            -> conn |> put_status(404) |> json(%{error: "Room not found"})
      {:error, :not_found}    -> conn |> put_status(404) |> json(%{error: "Room not found"})
      {:error, :unauthorized} -> conn |> put_status(403) |> json(%{error: "Only room owner can delete"})
    end
  end

  def dm(conn, params) do
    user            = conn.assigns.current_user
    target_id       = Map.get(params, "user_id", "") |> to_string()
    target_username = Map.get(params, "username", target_id)
    vault           = Map.get(params, "vault", "personal")

    if String.trim(target_id) == "" do
      conn |> put_status(422) |> json(%{error: "user_id is required"})
    else
      case Chat.get_or_create_dm(vault, [user.id, target_id], [user.username, target_username]) do
        {:ok, room} ->
          json(conn, %{ok: true, room: Chat.room_json(room)})

        {:error, changeset} ->
          errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
          conn |> put_status(422) |> json(%{error: errors})
      end
    end
  end

  # ── PRIVATE ──────────────────────────────────────────────────────────────────

  defp check_owner(%{owner_user_id: owner_id}, user_id) when owner_id == user_id, do: :ok
  defp check_owner(_, _), do: {:error, :not_owner}

  defp extract_did_key(nil), do: nil
  defp extract_did_key("did:przma:" <> key), do: key
  defp extract_did_key(did), do: did
end
