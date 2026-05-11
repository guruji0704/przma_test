defmodule AlemWeb.Chat.RoomController do
  @moduledoc """
  Chat Room Controller.
  - Room types: public, private, social
  - Presence list shows who is online
  - Audience mode when room is full
  - All user info comes from DB via ChatAuth plug (no manual username input)
  """

  use AlemWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Phoenix.PubSub
  alias OpenApiSpex.Schema

  # Default rooms with type field
  # public  = anyone can join
  # private = invite only (future)
  # social  = like Discord social channels
  @default_rooms [
    %{id: "lobby",   name: "Lobby",   emoji: "🏠", type: "public"},
    %{id: "tamil",   name: "Tamil",   emoji: "🗣️", type: "social"},
    %{id: "gaming",  name: "Gaming",  emoji: "🎮", type: "public"},
    %{id: "private", name: "Private", emoji: "🔒", type: "private"}
  ]

  @max_members 5

  tags ["Chat - Rooms"]

  operation :index,
    summary: "List all chat rooms with presence",
    description: "Returns all rooms (public/private/social) with live online member count. Bearer token required.",
    responses: %{
      200 => {"Rooms list", "application/json", %Schema{type: :object}},
      401 => {"Unauthorized", "application/json", %Schema{type: :object}}
    }

  operation :create,
    summary: "Create a new room",
    description: "Create a public, private, or social room.",
    request_body: {"Room details", "application/json", %Schema{
      type: :object,
      required: [:name],
      properties: %{
        name:  %Schema{type: :string,  example: "design-team"},
        emoji: %Schema{type: :string,  example: "🎨"},
        type:  %Schema{
          type: :string,
          example: "public",
          description: "Room type: public | private | social"
        }
      }
    }},
    responses: %{
      200 => {"Room created", "application/json", %Schema{type: :object}},
      401 => {"Unauthorized", "application/json", %Schema{type: :object}},
      422 => {"Error",        "application/json", %Schema{type: :object}}
    }

  operation :show,
    summary: "Get room details + online presence list",
    description: "Returns room info and who is currently online.",
    parameters: [
      id: [in: :path, type: :string, required: true,
           description: "Room ID — lobby | tamil | gaming | private"]
    ],
    responses: %{
      200 => {"Room details", "application/json", %Schema{type: :object}},
      401 => {"Unauthorized", "application/json", %Schema{type: :object}}
    }

  operation :members,
    summary: "Get online presence list for a room",
    description: "Shows who is currently online in this room.",
    parameters: [
      id: [in: :path, type: :string, required: true]
    ],
    responses: %{
      200 => {"Online members", "application/json", %Schema{type: :object}},
      401 => {"Unauthorized",   "application/json", %Schema{type: :object}}
    }

  operation :status,
    summary: "Check if room is full (audience mode check)",
    description: "mode: member = can send messages | audience = read only (room full)",
    parameters: [
      id: [in: :path, type: :string, required: true]
    ],
    responses: %{
      200 => {"Room status", "application/json", %Schema{type: :object}},
      401 => {"Unauthorized", "application/json", %Schema{type: :object}}
    }

  operation :join,
    summary: "Join a room — returns member or audience mode",
    description: """
    Joins using your authenticated DID and username from DB.
    No manual username input needed.

    - Room available → mode: member (can send messages)
    - Room full      → mode: audience (read only)
    """,
    parameters: [
      id: [in: :path, type: :string, required: true]
    ],
    responses: %{
      200 => {"Joined room", "application/json", %Schema{
        type: :object,
        properties: %{
          ok:          %Schema{type: :boolean},
          mode:        %Schema{type: :string, description: "member | audience"},
          is_audience: %Schema{type: :boolean},
          room:        %Schema{type: :string},
          username:    %Schema{type: :string, description: "From DB — your login username"},
          did:         %Schema{type: :string, description: "Your DID from DB"}
        }
      }},
      401 => {"Unauthorized", "application/json", %Schema{type: :object}}
    }

  operation :leave,
    summary: "Leave a room",
    description: "Removes you from online presence list.",
    parameters: [
      id: [in: :path, type: :string, required: true]
    ],
    responses: %{
      200 => {"Left room",   "application/json", %Schema{type: :object}},
      401 => {"Unauthorized", "application/json", %Schema{type: :object}}
    }

  # ── ACTIONS ──────────────────────────────────────────────────────────────

  def index(conn, _params) do
    # Get dynamically created rooms from ETS
    dynamic_rooms =
      :ets.tab2list(:chat_rooms)
      |> Enum.map(fn {_id, room} -> room end)

    all_rooms =
      (@default_rooms ++ dynamic_rooms)
      |> Enum.uniq_by(& &1.id)
      |> Enum.map(fn room ->
        members = get_room_members(room.id)
        count   = length(members)

        Map.merge(room, %{
          member_count: count,
          max:          @max_members,
          is_full:      count >= @max_members,
          online:       members   # presence list — who is online
        })
      end)

    json(conn, %{rooms: all_rooms})
  end

  def create(conn, params) do
    name      = Map.get(params, "name",  "") |> String.trim()
    emoji     = Map.get(params, "emoji", "💬")
    room_type = Map.get(params, "type",  "public")

    # Validate room type
    valid_types = ["public", "private", "social"]

    cond do
      name == "" ->
        conn |> put_status(422) |> json(%{error: "Room name required"})

      room_type not in valid_types ->
        conn |> put_status(422) |> json(%{
          error: "Invalid room type",
          valid: valid_types
        })

      true ->
        id   = name |> String.downcase() |> String.replace(" ", "-")
        room = %{id: id, name: name, emoji: emoji, type: room_type}

        :ets.insert(:chat_rooms, {id, room})

        json(conn, %{ok: true, room: room})
    end
  end

  def show(conn, %{"id" => id}) do
    members = get_room_members(id)
    count   = length(members)

    json(conn, %{
      id:      id,
      members: members,   # presence list
      count:   count,
      max:     @max_members,
      is_full: count >= @max_members
    })
  end

  def members(conn, %{"id" => id}) do
    members = get_room_members(id)

    json(conn, %{
      room:    id,
      online:  members,       # presence list
      count:   length(members)
    })
  end

  def status(conn, %{"id" => id}) do
    count   = get_room_members(id) |> length()
    is_full = count >= @max_members

    json(conn, %{
      room:    id,
      count:   count,
      max:     @max_members,
      is_full: is_full,
      mode:    if(is_full, do: "audience", else: "member")
    })
  end

  def join(conn, %{"id" => id}) do
    # Get user from DB — set by ChatAuth plug
    # No manual username input needed
    user     = conn.assigns[:current_user]
    username = user.username
    did      = user.did

    members = get_room_members(id)
    count   = length(members)

    if count < @max_members do
      # Add to presence list
      add_member(id, username)

      # Broadcast join event to room
      PubSub.broadcast(Alem.PubSub, "room:#{id}", {:user_joined, %{
        username: username,
        did:      did
      }})

      json(conn, %{
        ok:          true,
        mode:        "member",
        is_audience: false,
        room:        id,
        username:    username,
        did:         did,
        message:     "Joined as member — you can send messages"
      })
    else
      # Room full — audience mode (read only)
      json(conn, %{
        ok:          true,
        mode:        "audience",
        is_audience: true,
        room:        id,
        username:    username,
        did:         did,
        message:     "Room full (#{count}/#{@max_members}) — joined as audience, read only"
      })
    end
  end

  def leave(conn, %{"id" => id}) do
    user     = conn.assigns[:current_user]
    username = user.username
    did      = user.did

    # Remove from presence list
    remove_member(id, username)

    # Broadcast leave event
    PubSub.broadcast(Alem.PubSub, "room:#{id}", {:user_left, %{
      username: username,
      did:      did
    }})

    json(conn, %{ok: true, username: username, did: did, room: id})
  end

  # ── PRIVATE HELPERS ──────────────────────────────────────────────────────

  # Get current online members for a room from ETS
  defp get_room_members(room_id) do
    key = "members:#{room_id}"
    case :ets.lookup(:chat_rooms, key) do
      [{^key, members}] -> members
      []                -> []
    end
  end

  # Add member to room presence (no duplicates)
  defp add_member(room_id, username) do
    key     = "members:#{room_id}"
    members = get_room_members(room_id)
    updated = Enum.uniq([username | members])
    :ets.insert(:chat_rooms, {key, updated})
  end

  # Remove member from room presence
  defp remove_member(room_id, username) do
    key     = "members:#{room_id}"
    members = get_room_members(room_id)
    updated = Enum.reject(members, & &1 == username)
    :ets.insert(:chat_rooms, {key, updated})
  end
end
