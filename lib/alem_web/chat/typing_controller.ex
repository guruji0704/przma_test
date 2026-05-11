defmodule AlemWeb.Chat.TypingController do
  @moduledoc """
  Typing Indicator Controller.
  - Broadcasts typing status to room via PubSub
  - Username comes from DB via ChatAuth plug — no manual input needed
  """

  use AlemWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Phoenix.PubSub
  alias OpenApiSpex.Schema

  tags ["Chat - Typing"]

  operation :notify,
    summary: "Broadcast typing indicator to room",
    description: """
    Call this when user is typing.
    Others in the room will see 'johndoe is typing...'
    Username comes from your login token — no body needed.
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
      401 => {"Unauthorized", "application/json", %Schema{type: :object}}
    }

  def notify(conn, params) do
    room_id = params["id"]

    # Get username from DB — set by ChatAuth plug
    # No manual username input needed
    user     = conn.assigns[:current_user]
    username = user.username
    did      = user.did

    # Broadcast typing indicator to everyone in the room
    PubSub.broadcast(Alem.PubSub, "room:#{room_id}", {:typing, %{
      username: username,
      did:      did
    }})

    json(conn, %{ok: true, typing: username})
  end
end
