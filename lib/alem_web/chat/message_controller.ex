defmodule AlemWeb.Chat.MessageController do
  @moduledoc """
  Chat Message Controller — PostgreSQL-backed messages.

  - Public messages: persisted in DB + broadcast via Phoenix Channel
  - Private messages: NOT persisted, broadcast via PubSub to private topic
  - @mentions: detected in group messages → private PubSub + ActivityStream inbox
  - User info (username, DID) comes from DB via ChatAuth plug — no manual input needed
  - Max 4000 characters per message
  """

  use AlemWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Alem.Chat
  alias AlemWeb.Endpoint
  alias Phoenix.PubSub
  alias OpenApiSpex.Schema

  @max_length 4000

  tags ["Chat - Messages"]

  operation :index,
    summary: "Get paginated message history for a room",
    parameters: [
      room_id:   [in: :path,  type: :string,  required: true],
      per_page:  [in: :query, type: :integer, required: false, description: "Max messages (default: 50)"],
      before_id: [in: :query, type: :string,  required: false, description: "Cursor for older messages"]
    ],
    responses: %{
      200 => {"Messages", "application/json", %Schema{type: :object}},
      401 => {"Unauthorized", "application/json", %Schema{type: :object}}
    }

  operation :send_message,
    summary: "Send a message to a room",
    description: """
    Sends and persists a public message to the room.
    Broadcasts via Phoenix Channel so all connected clients receive it immediately.
    If the message contains @username, that user gets a private PubSub push
    and an ActivityStream inbox notification — other room members do NOT see it separately.
    Username and DID come from your login token — no need to pass them manually.
    Max 4000 characters.
    """,
    parameters: [
      room_id: [in: :path, type: :string, required: true]
    ],
    request_body: {"Message", "application/json", %Schema{
      type: :object,
      required: [:body],
      properties: %{
        body:        %Schema{type: :string,  example: "hey @ravi check this out"},
        msg_type:    %Schema{type: :string,  example: "text",
                             description: "text | file | image"},
        file_doc_id: %Schema{type: :string,  example: "doc-uuid"},
        file_name:   %Schema{type: :string,  example: "report.pdf"},
        file_type:   %Schema{type: :string,  example: "application/pdf"}
      }
    }},
    responses: %{
      200 => {"Sent",         "application/json", %Schema{type: :object}},
      401 => {"Unauthorized", "application/json", %Schema{type: :object}},
      404 => {"Not found",    "application/json", %Schema{type: :object}},
      422 => {"Error",        "application/json", %Schema{type: :object}}
    }

  operation :send_private,
    summary: "Send a private message to a specific user",
    description: """
    NOT persisted. Delivered via PubSub to both sender and receiver.
    Use the Phoenix Channel 'typing' event for real-time — this REST endpoint
    is a fallback / integration path when not connected via channel.
    """,
    request_body: {"Private message", "application/json", %Schema{
      type: :object,
      required: [:to, :body],
      properties: %{
        to:   %Schema{type: :string, example: "johndoe", description: "Target username"},
        body: %Schema{type: :string, example: "hey, only you see this"}
      }
    }},
    responses: %{
      200 => {"Delivered",    "application/json", %Schema{type: :object}},
      401 => {"Unauthorized", "application/json", %Schema{type: :object}},
      422 => {"Error",        "application/json", %Schema{type: :object}}
    }

  # ── ACTIONS ──────────────────────────────────────────────────────────────────

  def index(conn, %{"room_id" => room_id} = params) do
    limit     = parse_int(Map.get(params, "per_page", "50"), 50)
    before_id = Map.get(params, "before_id")

    messages = Chat.list_messages(room_id, limit: limit, before_id: before_id)

    json(conn, %{
      room:     room_id,
      messages: Enum.map(messages, &Chat.message_json/1),
      total:    length(messages)
    })
  end

  def send_message(conn, %{"room_id" => room_id} = params) do
    user = conn.assigns.current_user
    body = Map.get(params, "body", "") |> to_string()

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
        case Chat.get_room(room_id) do
          nil ->
            conn |> put_status(404) |> json(%{error: "Room not found"})

          room ->
            attrs = %{
              room_id:     room_id,
              user_id:     user.id,
              username:    user.username,
              body:        body,
              msg_type:    Map.get(params, "msg_type", "text"),
              file_doc_id: Map.get(params, "file_doc_id"),
              file_name:   Map.get(params, "file_name"),
              file_type:   Map.get(params, "file_type"),
              vault:       room.vault
            }

            case Chat.create_message(attrs) do
              {:ok, msg} ->
                msg_json = Chat.message_json(msg) |> Map.put(:did, user.did)

                # Existing broadcast — touch வேண்டாம்
                # Room-ல உள்ள எல்லாருக்கும் message போகும்
                Endpoint.broadcast(
                  "vault_chat:#{room.vault}:#{room_id}",
                  "new_message",
                  msg_json
                )

                # @mention detect பண்ணி mentioned user-க்கு
                # private-ஆ notify பண்ணு
                detect_and_notify_mentions(body, user, room)

                json(conn, %{ok: true, message: msg_json})

              {:error, changeset} ->
                errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
                conn |> put_status(422) |> json(%{error: errors})
            end
        end
    end
  end

  def send_private(conn, params) do
    user   = conn.assigns.current_user
    target = Map.get(params, "to", "") |> to_string()
    body   = Map.get(params, "body", "") |> to_string()

    cond do
      String.trim(target) == "" ->
        conn |> put_status(422) |> json(%{error: "Target username (to) is required"})

      String.trim(body) == "" ->
        conn |> put_status(422) |> json(%{error: "Message cannot be empty"})

      String.length(body) > @max_length ->
        conn |> put_status(422) |> json(%{error: "Message too long", max: @max_length})

      true ->
        msg = %{
          user:    user.username,
          did:     user.did,
          body:    body,
          to:      target,
          private: true
        }

        # Receiver-க்கு push
        PubSub.broadcast(Alem.PubSub, "private:#{target}", {:new_msg, msg})

        # Sender-க்கு echo (own sent message காண்பிக்க)
        if target != user.username do
          PubSub.broadcast(Alem.PubSub, "private:#{user.username}", {:new_msg, msg})
        end

        json(conn, %{ok: true, delivered_to: target})
    end
  end

  # ── PRIVATE ──────────────────────────────────────────────────────────────────

  # body-ல @username scan பண்ணி each mentioned user-க்கு
  # private PubSub push + ActivityStream inbox notification
  defp detect_and_notify_mentions(body, actor, room) do
    ~r/@(\w+)/
    |> Regex.scan(body)
    |> Enum.each(fn [_, username] ->

      # Self-mention skip
      if username != actor.username do

        case Alem.Repo.get_by(Alem.Pleroma.User, nickname: username) do
          nil ->
            # User இல்லன்னா skip — error throw வேண்டாம்
            :ok

          target ->
            # 1. Real-time PubSub push — WebSocket connected இருந்தா
            #    உடனே target-க்கு private-ஆ தெரியும்
            #    Room-ல மத்தவங்களுக்கு இந்த push போகாது
            PubSub.broadcast(
              Alem.PubSub,
              "private:#{target.id}",
              {:mention, %{
                from:      actor.username,
                from_id:   actor.id,
                body:      body,
                room_id:   room.id,
                room_name: room.name,
                vault:     room.vault,
                private:   true
              }}
            )

            # 2. ActivityStream inbox-ல persist பண்ணு —
            #    offline இருந்தாலும் inbox-ல தெரியும்
            Alem.ActivityStream.publish(
              "Mention",
              actor.id,
              actor.username,
              "Note",
              %{
                body:      String.slice(body, 0, 200),
                room_id:   room.id,
                room_name: room.name,
                vault:     room.vault
              },
              recipients:        [%{user_id: target.id, username: username}],
              room_id:           room.id,
              vault:             room.vault,
              object_id:         room.id,
              notification_type: "mention"
            )
        end
      end
    end)
  end

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end
  defp parse_int(val, _) when is_integer(val), do: val
  defp parse_int(_, default), do: default
end
