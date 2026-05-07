defmodule AlemWeb.Chat.RoomController do
  use AlemWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias AlemWeb.Presence
  alias Phoenix.PubSub
  alias OpenApiSpex.Schema

  @default_rooms [
    %{id: "lobby",  name: "Lobby",  emoji: "🏠"},
    %{id: "tamil",  name: "Tamil",  emoji: "🗣️"},
    %{id: "gaming", name: "Gaming", emoji: "🎮"}
  ]
  @max_members 5

  tags ["Chat - Rooms"]

  operation :index,
    summary: "List all chat rooms",
    responses: %{
      200 => {"Rooms", "application/json", %Schema{type: :object}}
    }

  operation :show,
    summary: "Get room details + members",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: %{200 => {"Room", "application/json", %Schema{type: :object}}}

  operation :status,
    summary: "Check room full or available",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: %{200 => {"Status", "application/json", %Schema{type: :object}}}

  operation :join,
    summary: "Join room — member or audience",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Join", "application/json", %Schema{
      type: :object,
      properties: %{
        username: %Schema{type: :string, example: "karthiga"}
      }
    }},
    responses: %{200 => {"Joined", "application/json", %Schema{type: :object}}}

  operation :leave,
    summary: "Leave a room",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Leave", "application/json", %Schema{
      type: :object,
      properties: %{
        username: %Schema{type: :string, example: "karthiga"}
      }
    }},
    responses: %{200 => {"Left", "application/json", %Schema{type: :object}}}

  operation :members,
    summary: "Get online members",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: %{200 => {"Members", "application/json", %Schema{type: :object}}}

  operation :create,
    summary: "Create new room",
    request_body: {"Room", "application/json", %Schema{
      type: :object,
      required: [:name],
      properties: %{
        name:  %Schema{type: :string, example: "general"},
        emoji: %Schema{type: :string, example: "💬"}
      }
    }},
    responses: %{200 => {"Created", "application/json", %Schema{type: :object}}}

  # ── ACTIONS ─────────────────────────────────────────────────

  def index(conn, _params) do
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
          is_full:      count >= @max_members
        })
      end)

    json(conn, %{rooms: all_rooms})
  end

  def create(conn, params) do
    name  = Map.get(params, "name", "") |> String.trim()
    emoji = Map.get(params, "emoji", "💬")

    if name == "" do
      conn |> put_status(422) |> json(%{error: "Room name required"})
    else
      id   = name |> String.downcase() |> String.replace(" ", "-")
      room = %{id: id, name: name, emoji: emoji}
      :ets.insert(:chat_rooms, {id, room})
      json(conn, %{ok: true, room: room})
    end
  end

  def show(conn, %{"id" => id}) do
    members = get_room_members(id)
    count   = length(members)
    json(conn, %{
      id: id, members: members,
      count: count, max: @max_members,
      is_full: count >= @max_members
    })
  end

  def members(conn, %{"id" => id}) do
    members = get_room_members(id)
    json(conn, %{room: id, members: members, count: length(members)})
  end

  def status(conn, %{"id" => id}) do
    count   = get_room_members(id) |> length()
    is_full = count >= @max_members
    json(conn, %{
      room: id, count: count, max: @max_members,
      is_full: is_full,
      mode: if(is_full, do: "audience", else: "member")
    })
  end

  def join(conn, params) do
    id       = params["id"]
    username =
      get_session(conn, :username) ||
      Map.get(params, "username") ||
      "anon"

    members = get_room_members(id)
    count   = length(members)

    if count < @max_members do
      add_member(id, username)
      PubSub.broadcast(Alem.PubSub, "room:#{id}", {:user_joined, username})
      json(conn, %{ok: true, mode: "member", is_audience: false, room: id})
    else
      json(conn, %{ok: true, mode: "audience", is_audience: true, room: id,
                   message: "Room full — joined as audience (read only)"})
    end
  end

  def leave(conn, params) do
    id       = params["id"]
    username =
      get_session(conn, :username) ||
      Map.get(params, "username") ||
      "anon"

    remove_member(id, username)
    PubSub.broadcast(Alem.PubSub, "room:#{id}", {:user_left, username})
    json(conn, %{ok: true, username: username, room: id})
  end

  defp get_room_members(room_id) do
    key = "members:#{room_id}"
    case :ets.lookup(:chat_rooms, key) do
      [{^key, members}] -> members
      []                -> []
    end
  end

  defp add_member(room_id, username) do
    key     = "members:#{room_id}"
    members = get_room_members(room_id)
    updated = Enum.uniq([username | members])
    :ets.insert(:chat_rooms, {key, updated})
  end

  defp remove_member(room_id, username) do
    key     = "members:#{room_id}"
    members = get_room_members(room_id)
    updated = Enum.reject(members, & &1 == username)
    :ets.insert(:chat_rooms, {key, updated})
  end
end
