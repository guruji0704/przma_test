defmodule AlemWeb.Chat.UserController do
  @moduledoc "Returns active users for the invite/DM picker."

  use AlemWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Alem.Chat
  alias OpenApiSpex.Schema

  tags ["Chat - Users"]

  operation :index,
    summary: "List active users for invite/DM picker",
    parameters: [
      search: [in: :query, type: :string, required: false,
               description: "Filter by username or display name"]
    ],
    responses: %{
      200 => {"Users",        "application/json", %Schema{type: :object}},
      401 => {"Unauthorized", "application/json", %Schema{type: :object}}
    }

  def index(conn, params) do
    search = Map.get(params, "search")
    users  = Chat.list_users(search)
    json(conn, %{users: Enum.map(users, &Chat.user_json/1)})
  end
end
