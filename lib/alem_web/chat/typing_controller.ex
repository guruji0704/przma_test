defmodule AlemWeb.Chat.TypingController do
  use AlemWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Phoenix.PubSub
  alias OpenApiSpex.Schema

  tags ["Chat - Typing"]

  operation :notify,
    summary: "Broadcast typing indicator",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Typing", "application/json", %Schema{
      type: :object,
      properties: %{
        username: %Schema{type: :string, example: "karthiga"}
      }
    }},
    responses: %{200 => {"OK", "application/json", %Schema{type: :object}}}

  def notify(conn, params) do
    room_id  = params["id"]
    username =
      get_session(conn, :username) ||
      Map.get(params, "username") ||
      "anon"

    PubSub.broadcast(Alem.PubSub, "room:#{room_id}", {:typing, username})
    json(conn, %{ok: true})
  end
end
