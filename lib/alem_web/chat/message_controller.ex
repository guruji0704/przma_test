defmodule AlemWeb.Chat.MessageController do
  use AlemWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Phoenix.PubSub
  alias OpenApiSpex.Schema

  @max_length 280

  tags ["Chat - Messages"]

  operation :index,
    summary: "Get paginated message history",
    parameters: [
      id:       [in: :path,  type: :string,  required: true],
      page:     [in: :query, type: :integer, required: false],
      per_page: [in: :query, type: :integer, required: false]
    ],
    responses: %{200 => {"Messages", "application/json", %Schema{type: :object}}}

  operation :send_message,
    summary: "Send message — use @username for private",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Message", "application/json", %Schema{
      type: :object,
      required: [:body],
      properties: %{
        body:     %Schema{type: :string, example: "hello @ravi"},
        username: %Schema{type: :string, example: "karthiga"}
      }
    }},
    responses: %{
      200 => {"Sent",  "application/json", %Schema{type: :object}},
      422 => {"Error", "application/json", %Schema{type: :object}}
    }

  operation :send_private,
    summary: "Send private DM",
    request_body: {"DM", "application/json", %Schema{
      type: :object,
      required: [:to, :body],
      properties: %{
        to:       %Schema{type: :string, example: "ravi"},
        body:     %Schema{type: :string, example: "hey"},
        username: %Schema{type: :string, example: "karthiga"}
      }
    }},
    responses: %{
      200 => {"Delivered", "application/json", %Schema{type: :object}},
      422 => {"Error",     "application/json", %Schema{type: :object}}
    }

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

    json(conn, %{room: room_id, page: page,
                 per_page: per_page, total: total, messages: messages})
  end

  def send_message(conn, params) do
    body     = Map.get(params, "body", "")
    room_id  = params["id"]
    username =
      get_session(conn, :username) ||
      Map.get(params, "username") ||
      "anon"

    cond do
      String.trim(body) == "" ->
        conn |> put_status(422) |> json(%{error: "Empty message"})

      String.length(body) > @max_length ->
        conn |> put_status(422) |> json(%{error: "Too long", max: @max_length})

      true ->
        tagged = extract_tag(body)
        msg    = %{user: username, body: body, tagged: tagged}

        case tagged do
          nil ->
            :ets.insert(:chat_messages, {
              System.unique_integer([:positive]), room_id, msg
            })
            PubSub.broadcast(Alem.PubSub, "room:#{room_id}", {:new_msg, msg})

          target ->
            PubSub.broadcast(Alem.PubSub, "private:#{target}", {:new_msg, msg})
            if target != username do
              PubSub.broadcast(Alem.PubSub, "private:#{username}", {:new_msg, msg})
            end
        end

        json(conn, %{ok: true, message: msg})
    end
  end

  def send_private(conn, params) do
    target   = Map.get(params, "to",   "")
    body     = Map.get(params, "body", "")
    username =
      get_session(conn, :username) ||
      Map.get(params, "username") ||
      "anon"

    cond do
      String.trim(target) == "" ->
        conn |> put_status(422) |> json(%{error: "Target required"})

      String.trim(body) == "" ->
        conn |> put_status(422) |> json(%{error: "Empty message"})

      true ->
        msg = %{user: username, body: body, tagged: target, private: true}
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
