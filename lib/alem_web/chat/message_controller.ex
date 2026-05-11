defmodule AlemWeb.Chat.MessageController do
  @moduledoc """
  Chat Message Controller.
  - User info (username, DID) comes from DB via ChatAuth plug
  - No manual username input in request body
  - Public messages stored in ETS
  - Private @tag messages NOT stored (ephemeral)
  - Max 280 characters per message
  - Paginated message history
  """

  use AlemWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Phoenix.PubSub
  alias OpenApiSpex.Schema

  @max_length 280

  tags ["Chat - Messages"]

  operation :index,
    summary: "Get paginated message history",
    description: "Loads past public messages. Private (@tag) messages are not stored.",
    parameters: [
      id:       [in: :path,  type: :string,  required: true,
                 description: "Room ID"],
      page:     [in: :query, type: :integer, required: false,
                 description: "Page number (default: 1)"],
      per_page: [in: :query, type: :integer, required: false,
                 description: "Messages per page (default: 20)"]
    ],
    responses: %{
      200 => {"Message history", "application/json", %Schema{type: :object}},
      401 => {"Unauthorized",    "application/json", %Schema{type: :object}}
    }

  operation :send_message,
    summary: "Send a message to a room",
    description: """
    Send a public message to the room.
    Use @username in body to send a private DM — only that user sees it.
    Max 280 characters.
    Username and DID come from your login token — no need to pass them manually.
    """,
    parameters: [
      id: [in: :path, type: :string, required: true, description: "Room ID"]
    ],
    request_body: {"Message", "application/json", %Schema{
      type: :object,
      required: [:body],
      properties: %{
        body: %Schema{
          type: :string,
          example: "hello everyone",
          description: "Max 280 chars. Use @username to send private message."
        }
      }
    }},
    responses: %{
      200 => {"Message sent", "application/json", %Schema{
        type: :object,
        properties: %{
          ok:      %Schema{type: :boolean},
          message: %Schema{
            type: :object,
            properties: %{
              user:   %Schema{type: :string, description: "From DB — your login username"},
              did:    %Schema{type: :string, description: "Your DID from DB"},
              body:   %Schema{type: :string},
              tagged: %Schema{type: :string, nullable: true,
                              description: "null = public | username = private DM"}
            }
          }
        }
      }},
      401 => {"Unauthorized", "application/json", %Schema{type: :object}},
      422 => {"Error",        "application/json", %Schema{type: :object}}
    }

  operation :send_private,
    summary: "Send a private DM to a specific user",
    description: "Only sender and receiver see this. Not stored in history.",
    request_body: {"Private DM", "application/json", %Schema{
      type: :object,
      required: [:to, :body],
      properties: %{
        to:   %Schema{type: :string, example: "johndoe",
                      description: "Target username"},
        body: %Schema{type: :string, example: "hey, only you see this"}
      }
    }},
    responses: %{
      200 => {"DM delivered", "application/json", %Schema{type: :object}},
      401 => {"Unauthorized", "application/json", %Schema{type: :object}},
      422 => {"Error",        "application/json", %Schema{type: :object}}
    }

  # ── ACTIONS ──────────────────────────────────────────────────────────────

  def index(conn, %{"id" => room_id} = params) do
    page     = Map.get(params, "page",     "1")  |> String.to_integer()
    per_page = Map.get(params, "per_page", "20") |> String.to_integer()

    # Load all messages for this room from ETS
    all_messages =
      :ets.tab2list(:chat_messages)
      |> Enum.filter(fn {_k, room, _msg} -> room == room_id end)
      |> Enum.sort()
      |> Enum.map(fn {_k, _room, msg} -> msg end)

    total    = length(all_messages)
    messages = all_messages
               |> Enum.drop((page - 1) * per_page)
               |> Enum.take(per_page)

    json(conn, %{
      room:     room_id,
      page:     page,
      per_page: per_page,
      total:    total,
      messages: messages
    })
  end

  def send_message(conn, params) do
    body    = Map.get(params, "body", "")
    room_id = params["id"]

    # Get user from DB — set by ChatAuth plug
    # Username and DID come automatically from login token
    user     = conn.assigns[:current_user]
    username = user.username
    did      = user.did

    cond do
      String.trim(body) == "" ->
        conn |> put_status(422) |> json(%{error: "Message cannot be empty"})

      String.length(body) > @max_length ->
        conn |> put_status(422) |> json(%{
          error:          "Message too long",
          max:            @max_length,
          current_length: String.length(body)
        })

      true ->
        # Check if message has @username tag
        tagged = extract_tag(body)

        msg = %{
          user:   username,
          did:    did,
          body:   body,
          tagged: tagged
        }

        case tagged do
          nil ->
            # Public message — store in ETS + broadcast to whole room
            :ets.insert(:chat_messages, {
              System.unique_integer([:positive]),
              room_id,
              msg
            })
            PubSub.broadcast(Alem.PubSub, "room:#{room_id}", {:new_msg, msg})

          target ->
            # Private @tag message — NOT stored, sent only to target + sender
            PubSub.broadcast(Alem.PubSub, "private:#{target}", {:new_msg, msg})

            # Also send to sender so they see their own private message
            if target != username do
              PubSub.broadcast(Alem.PubSub, "private:#{username}", {:new_msg, msg})
            end
        end

        json(conn, %{ok: true, message: msg})
    end
  end

  def send_private(conn, params) do
    target = Map.get(params, "to",   "")
    body   = Map.get(params, "body", "")

    # Get user from DB — set by ChatAuth plug
    user     = conn.assigns[:current_user]
    username = user.username
    did      = user.did

    cond do
      String.trim(target) == "" ->
        conn |> put_status(422) |> json(%{error: "Target username (to) is required"})

      String.trim(body) == "" ->
        conn |> put_status(422) |> json(%{error: "Message cannot be empty"})

      String.length(body) > @max_length ->
        conn |> put_status(422) |> json(%{error: "Message too long", max: @max_length})

      true ->
        # Private DM — not stored in ETS
        msg = %{user: username, did: did, body: body, to: target, private: true}
        PubSub.broadcast(Alem.PubSub, "private:#{target}", {:new_msg, msg})

        json(conn, %{ok: true, delivered_to: target})
    end
  end

  # Extract @username from message body
  defp extract_tag(body) do
    case Regex.run(~r/@(\S+)/, body) do
      [_full, name] -> name
      nil           -> nil
    end
  end
end
