defmodule ChatAppWeb.ChatLive do
  use ChatAppWeb, :live_view

  alias Phoenix.PubSub
  alias ChatAppWeb.Presence

  @max_length 280
  @max_members 5
  @typing_timeout 3000

  def mount(params, _session, socket) do
    #username = session["username"] || "anon"
    #room     = session["room"] || "lobby"

    token = params["token"]

    if is_nil(token) do
      raise "Token missing"
    end

    user =
      case verify_token(token) do
        {:ok, user} -> user
        _ -> raise "Unauthorized access"
      end

    username = user.username
    room = "lobby"

    topic = "room:#{room}"
    #private_topic = "private:#{username}"
    private_topic = "private:#{username}-#{:erlang.unique_integer([:positive])}"

    is_audience =
      if connected?(socket) do
        PubSub.subscribe(ChatApp.PubSub, topic)
        PubSub.subscribe(ChatApp.PubSub, private_topic)

        Process.send_after(self(), :clear_typing, @typing_timeout)

        current_count = Presence.list(topic) |> map_size()

        if current_count < @max_members do
          Presence.track(self(), topic, username, %{
            online_at: System.system_time(:second)
          })
          false
        else
          true
        end
      else
        false
      end

    initial_users = Presence.list(topic) |> Map.keys()

    {:ok,
     assign(socket,
       username: username,
       room: room,
       topic: topic,
       private_topic: private_topic,
       message: "",
       messages:
         :ets.tab2list(:chat_messages)
         |> Enum.filter(fn {_id, msg_room, _msg} -> msg_room == room end)
         |> Enum.sort()
         |> Enum.map(fn {_id, _room, msg} -> msg end),
       users: initial_users,
       remaining: @max_length,
       is_audience: is_audience,
       typing_users: %{},
       mention_query: nil,
       mention_suggestions: []
     ) # FILE UPLOAD
     |> allow_upload(:file,
      accept: ~w(.jpg .jpeg .png .pdf),
      max_entries: 1,
      max_file_size: 5_000_000
      )
    }
  end

  # ========================
  # HANDLE EVENTS
  # ========================

  def handle_event("send", %{"message" => msg}, socket) do
    if not socket.assigns.is_audience and
         String.length(msg) <= @max_length and
         msg != "" do

      # ✅ Extract tagged user FIRST
      tagged_username = extract_tagged_user(msg, socket.assigns.users)

      # File upload
      uploaded_files =
        consume_uploaded_entries(socket, :file, fn %{path: path}, entry ->
          filename = "#{System.unique_integer([:positive])}-#{entry.client_name}"
          dest = Path.join("priv/static/uploads", filename)
          File.cp!(path, dest)

          {:ok, "/uploads/#{filename}"}
        end)

      # ✅ Create message
      message = %{
        user: socket.assigns.username,
        body: msg,
        file: List.first(uploaded_files),
        tagged: tagged_username
      }

      # ✅ FIXED LOGIC (ONLY CHANGE)
      case tagged_username do
        nil ->
          # PUBLIC → store in ETS
          :ets.insert(:chat_messages, {
            System.unique_integer([:positive]),
            socket.assigns.room,
            message
          })

          PubSub.broadcast(
            ChatApp.PubSub,
            socket.assigns.topic,
            {:new_msg, message}
          )

        _ ->
          # PRIVATE → DO NOT store in ETS

          PubSub.broadcast(
            ChatApp.PubSub,
            "private:#{tagged_username}",
            {:new_msg, message}
          )

          if tagged_username != socket.assigns.username do
            PubSub.broadcast(
              ChatApp.PubSub,
              socket.assigns.private_topic,
              {:new_msg, message}
            )
          end
      end

      {:noreply, assign(socket, message: "", remaining: @max_length)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_message", %{"message" => msg}, socket) do
    if not socket.assigns.is_audience do
      PubSub.broadcast(ChatApp.PubSub, socket.assigns.topic, {:typing, socket.assigns.username})
    end

    mention_query =
      case Regex.run(~r/@(\S*)$/, msg) do
        [_full, query] -> query
        nil -> nil
      end

    mention_suggestions =
      if mention_query != nil do
        socket.assigns.users
        |> Enum.filter(fn user ->
          user != socket.assigns.username and
            String.starts_with?(String.downcase(user), String.downcase(mention_query))
        end)
      else
        []
      end

    {:noreply,
     assign(socket,
       message: msg,
       remaining: @max_length - String.length(msg),
       mention_query: mention_query,
       mention_suggestions: mention_suggestions
     )}
  end

  def handle_event("select_mention", %{"username" => selected}, socket) do
    current_msg = socket.assigns.message
    new_msg = Regex.replace(~r/@(\S*)$/, current_msg, "@#{selected} ")

    {:noreply,
     assign(socket,
       message: new_msg,
       remaining: @max_length - String.length(new_msg),
       mention_suggestions: [],
       mention_query: nil
     )}
  end

  # ========================
  # HANDLE INFO
  # ========================

  def handle_info({:new_msg, message}, socket) do
    {:noreply, update(socket, :messages, fn msgs -> msgs ++ [message] end)}
  end

  def handle_info({:typing, user}, socket) do
    if user != socket.assigns.username do
      typing_users = Map.put(socket.assigns.typing_users, user, System.system_time(:millisecond))
      {:noreply, assign(socket, typing_users: typing_users)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:clear_typing, socket) do
    now = System.system_time(:millisecond)

    typing_users =
      socket.assigns.typing_users
      |> Enum.filter(fn {_user, time} -> now - time < @typing_timeout end)
      |> Enum.into(%{})

    Process.send_after(self(), :clear_typing, @typing_timeout)
    {:noreply, assign(socket, typing_users: typing_users)}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    users = Presence.list(socket.assigns.topic) |> Map.keys()
    {:noreply, assign(socket, users: users)}
  end

  # ========================
  # HELPERS
  # ========================

  defp extract_tagged_user(msg, users) do
    Regex.scan(~r/@(\S+)/, msg)
    |> Enum.map(fn [_full, name] -> name end)
    |> Enum.find(fn name -> Enum.member?(users, name) end)
  end

  def highlight_mentions(text) do
    Regex.replace(~r/@(\S+)/, text, fn match, _name ->
      "<span class='font-bold text-blue-600'>#{match}</span>"
    end)
  end

  defp verify_token(nil), do: {:error, :no_token}

  defp verify_token(token) do
    # ✅ TEMP (for testing)
    {:ok, %{username: token}}

    # 🔐 LATER (real implementation):
    # Call PRZMA service OR decode JWT
  end
end