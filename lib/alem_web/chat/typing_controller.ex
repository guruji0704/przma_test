defmodule AlemWeb.Chat.TypingController do
  @moduledoc """
  REST typing indicator endpoint.

  The Phoenix Channel already handles 'typing' events when clients are connected
  via WebSocket. This REST endpoint is a fallback for clients that need to signal
  typing without an active channel connection (e.g., REST-only integrations).
  """

  use AlemWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Alem.Chat
  alias Phoenix.PubSub
  alias OpenApiSpex.Schema

  tags ["Chat - Typing"]

  operation :notify,
    summary: "Broadcast typing indicator to a room",
    description: """
    Call when user is typing. Others in the room will see 'username is typing…'
    Username comes from your login token — no body needed.
    NOTE: Prefer the Phoenix Channel 'typing' push when connected via WebSocket.
    """,
    parameters: [
      id: [in: :path, type: :string, required: true, description: "Room ID"]
    ],
    responses: %{
      200 => {"Typing broadcast sent", "application/json", %Schema{
        type: :object,
        properties: %{
          ok:     %Schema{type: :boolean},
          typing: %Schema{type: :string, description: "Username who is typing"}
        }
      }},
      401 => {"Unauthorized", "application/json", %Schema{type: :object}},
      404 => {"Not found",    "application/json", %Schema{type: :object}}
    }

  def notify(conn, %{"id" => room_id}) do
    user = conn.assigns.current_user

    case Chat.get_room(room_id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "Room not found"})

      room ->
        PubSub.broadcast(Alem.PubSub, "vault_chat:#{room.vault}:#{room_id}", {:typing, %{
          username: user.username,
          did:      user.did
        }})
        json(conn, %{ok: true, typing: user.username})
    end
  end
end
