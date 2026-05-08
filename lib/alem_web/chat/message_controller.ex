defmodule AlemWeb.Chat.MessageController do
  use AlemWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Phoenix.PubSub
  alias OpenApiSpex.Schema

  @max_length 280

  tags ["Chat"]

  operation :index,
    summary: "Get paginated message history",
    parameters: [
      id:       [in: :path,  type: :string,  required: true],
      page:     [in: :query, type: :integer, required: false],
      per_page: [in: :query, type: :integer, required: false]
    ],
    responses: %{
      200 => {"Messages", "application/json", %Schema{type: :object}},
      401 => {"Unauthorized", "application/json", %Schema{type: :object}}
    }

  operation :send_message,
    summary: "Send message to room",
    description: "Max 280 chars. Use @username for private DM.",
    parameters: [id: [in: :path, type: :string, required: true]],
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
      200 => {"Sent",  "application/json", %Schema{type: :object}},
      401 => {"Unauthorized", "application/json", %Schema{type: :object}},
      422 => {"Error", "application/json", %Schema{type: :object}}
    }

  operation :send_private,
    summary: "Send private DM to specific user",
    request_body: {"DM", "application/json", %Schema{
      type: :object,
      required: [:to, :body],
      properties: %{
        to:   %Schema{type: :string, example: "johndoe"},
        body: %Schema{type: :string, example: "hey only you see this"}
      }
    }},
    responses: %{
      200 => {"Delivered", "application/json", %Schema{type: :object}},
      401 => {"Unauthorized", "application/json", %Schema{type: :object}},
      422 => {"Error",     "application/json", %Schema{type: :object}}
    }

  # ── ACTIONS ─────────────────────────────────────────────────

  def index(conn, %{"id" => room_id} = params) do
    page     = Map.get(params, "page",     "1")  |> String.to_integer()
    per_page = Map.get(params, "per_page", "20") |> String.to_integer()

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

    # ✅ DB-இல் இருந்து login பண்ணின user — auto வரும்
    # username params-ல போட வேண்டாம்!
    user     = conn.assigns[:current_user]
    username = user.username
    did      = user.did

    cond do
      String.trim(body) == "" ->
        conn |> put_status(422) |> json(%{error: "Empty message"})

      String.length(body) > @max_length ->
        conn |> put_status(422) |> json(%{
          error: "Message too long",
          max:   @max_length,
          current_length: String.length(body)
        })

      true ->
        tagged = extract_tag(body)
        msg    = %{
          user:   username,
          did:    did,
          body:   body,
          tagged: tagged
        }

        case tagged do
          nil ->
            # Public message — ETS-ல store + room-க்கு broadcast
            :ets.insert(:chat_messages, {
              System.unique_integer([:positive]), room_id, msg
            })
            PubSub.broadcast(Alem.PubSub, "room:#{room_id}", {:new_msg, msg})

          target ->
            # Private @tag — ETS-ல store வேண்டாம்
            PubSub.broadcast(Alem.PubSub, "private:#{target}", {:new_msg, msg})
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

    # ✅ DB-இல் இருந்து auto
    user     = conn.assigns[:current_user]
    username = user.username
    did      = user.did

    cond do
      String.trim(target) == "" ->
        conn |> put_status(422) |> json(%{error: "Target username required"})

      String.trim(body) == "" ->
        conn |> put_status(422) |> json(%{error: "Empty message"})

      String.length(body) > @max_length ->
        conn |> put_status(422) |> json(%{error: "Too long", max: @max_length})

      true ->
        msg = %{user: username, did: did, body: body, tagged: target, private: true}
        PubSub.broadcast(Alem.PubSub, "private:#{target}", {:new_msg, msg})
        json(conn, %{ok: true, delivered_to: target})
    end
  end

  defp extract_tag(body) do
    case Regex.run(~r/@(\S+)/, body) do
      [_full, name] -> name
      nil           -> nil
    end
  end
end
