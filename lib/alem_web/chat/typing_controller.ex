defmodule AlemWeb.Chat.TypingController do
  use AlemWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Phoenix.PubSub
  alias OpenApiSpex.Schema

  tags ["Chat"]

  operation :notify,
    summary: "Broadcast typing indicator",
    description: "Others in room will see 'johndoe is typing...'",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: %{
      200 => {"OK", "application/json", %Schema{type: :object}},
      401 => {"Unauthorized", "application/json", %Schema{type: :object}}
    }

  def notify(conn, params) do
    room_id  = params["id"]

    # ✅ DB-இல் இருந்து auto — username போட வேண்டாம்
    user     = conn.assigns[:current_user]
    username = user.username

    PubSub.broadcast(Alem.PubSub, "room:#{room_id}", {:typing, username})
    json(conn, %{ok: true, typing: username})
  end
end
