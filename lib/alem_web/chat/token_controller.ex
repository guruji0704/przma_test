defmodule AlemWeb.Chat.TokenController do
  use AlemWeb, :controller
  use OpenApiSpex.ControllerSpecs
  alias OpenApiSpex.Schema

  tags ["Chat"]

  operation :create,
    summary: "Get Chat WebSocket Token",
    description: """
    Exchange your Pleroma Bearer token for a chat token.

    ## Flow:
    1. Login → POST /api/v1/oauth/token → get access_token
    2. Call this endpoint with Bearer access_token in header
    3. Use returned chat_token for WebSocket connection
    """,
    request_body: {"Token request", "application/json", %Schema{
      type: :object,
      required: [:username],
      properties: %{
        username: %Schema{type: :string, example: "karthiga"}
      }
    }},
    responses: %{
      200 => {"Token issued", "application/json", %Schema{
        type: :object,
        properties: %{
          chat_token: %Schema{type: :string},
          username:   %Schema{type: :string},
          expires_in: %Schema{type: :integer}
        }
      }},
      401 => {"Unauthorized", "application/json", %Schema{
        type: :object,
        properties: %{error: %Schema{type: :string}}
      }}
    }

  def create(conn, params) do
    # Header-இல் Pleroma Bearer token இருக்கா check பண்ணு
    pleroma_token =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token] -> token
        _                    -> nil
      end

    if is_nil(pleroma_token) do
      conn
      |> put_status(401)
      |> json(%{error: "Pleroma Bearer token required. Login via /api/v1/oauth/token first."})
    else
      username = Map.get(params, "username", "anon") |> String.trim()

      # Chat token generate பண்ணு
      chat_token = Base.encode64("#{username}:#{pleroma_token}:#{System.system_time(:second)}")

      conn
      |> put_session(:username, username)
      |> put_session(:pleroma_token, pleroma_token)
      |> json(%{
        chat_token: chat_token,
        username:   username,
        expires_in: 3600
      })
    end
  end
end
