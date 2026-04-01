defmodule ChatAppWeb.ChatLive do
  use ChatAppWeb, :live_view

  alias Phoenix.PubSub
  alias ChatAppWeb.Presence
  alias ChatApp.Message

  @topic "chat_room"

  def mount(_params, session, socket) do
    username = session["username"]

    if is_nil(username) do
      {:ok,
       socket
       |> put_flash(:error, "Please enter your name first!")
       |> push_navigate(to: "/")}
    else
      if connected?(socket) do
        PubSub.subscribe(ChatApp.PubSub, @topic)
        Presence.track(self(), @topic, username, %{
          online_at: System.system_time(:second)
        })
      end

      messages = Message.last_50("general")
      users    = Presence.list(@topic) |> Map.keys()

      {:ok,
       assign(socket,
         username:       username,
         room:           "general",
         message:        "",
         messages:       messages,
         users:          users,
         # @mention autocomplete
         show_mentions:  false,
         mention_query:  "",
         filtered_users: []
       )}
    end
  end

  # ── SEND MESSAGE ──────────────────────────────
  def handle_event("send", %{"message" => msg}, socket) do
    msg = String.trim(msg)

    if msg != "" do
      case Message.save(socket.assigns.username, msg, socket.assigns.room) do
        {:ok, saved} ->
          PubSub.broadcast(ChatApp.PubSub, @topic, {:new_msg, saved})
          {:noreply, assign(socket,
            message:       "",
            show_mentions: false,
            filtered_users: []
          )}

        {:error, changeset} ->
          {:noreply,
           put_flash(socket, :error, format_errors(changeset))}
      end
    else
      {:noreply, socket}
    end
  end

  # ── TYPING — detect @mention ──────────────────
  def handle_event("update_message", %{"message" => msg}, socket) do
    {show_mentions, mention_query} = check_mention(msg)

    filtered_users =
      if show_mentions do
        socket.assigns.users
        |> Enum.reject(fn u -> u == socket.assigns.username end)
        |> Enum.filter(fn u ->
          String.downcase(u)
          |> String.contains?(String.downcase(mention_query))
        end)
      else
        []
      end

    {:noreply,
     assign(socket,
       message:        msg,
       show_mentions:  show_mentions,
       mention_query:  mention_query,
       filtered_users: filtered_users
     )}
  end

  # ── SELECT MENTION FROM DROPDOWN ─────────────
  def handle_event("select_mention", %{"username" => username}, socket) do
    # Replace the @partial at end of message with @selected_user
    new_msg =
      Regex.replace(
        ~r/@[\w-]*$/,
        socket.assigns.message,
        "@#{username} "
      )

    {:noreply,
     assign(socket,
       message:        new_msg,
       show_mentions:  false,
       mention_query:  "",
       filtered_users: []
     )}
  end

  # ── DISMISS MENTION DROPDOWN ──────────────────
  def handle_event("dismiss_mentions", _params, socket) do
    {:noreply, assign(socket, show_mentions: false, filtered_users: [])}
  end

  # ── NEW MESSAGE ARRIVED ───────────────────────
  def handle_info({:new_msg, message}, socket) do
    {:noreply,
     update(socket, :messages, fn msgs -> msgs ++ [message] end)}
  end

  # ── PRESENCE — user joined or left ───────────
  def handle_info(
        %Phoenix.Socket.Broadcast{
          event:   "presence_diff",
          payload: %{joins: joins, leaves: leaves}
        },
        socket
      ) do
    Enum.each(joins,  fn {name, _} -> IO.puts("✅ #{name} joined") end)
    Enum.each(leaves, fn {name, _} -> IO.puts("❌ #{name} left")   end)

    users = Presence.list(@topic) |> Map.keys()

    {:noreply, assign(socket, users: users)}
  end

  # ── HELPERS ───────────────────────────────────

  # Detect @mention being typed at end of message
  # "Hello @Al"  → {true,  "Al"}
  # "Hello "     → {false, ""}
  # "Hi @x done" → {false, ""}  ← space after = finished
  defp check_mention(msg) do
    case Regex.run(~r/@([\w-]*)$/, msg) do
      [_full, query] -> {true, query}
      nil            -> {false, ""}
    end
  end

  def format_time(nil), do: ""
  def format_time(datetime) do
    Calendar.strftime(datetime, "%I:%M %p")
  rescue
    _ -> ""
  end

  def highlight_mentions(body, current_username) do
    Regex.replace(~r/@([\w-]+)/, body, fn full, name ->
      if name == current_username do
        "<span class='bg-yellow-200 text-yellow-800
          font-semibold px-1 rounded'>#{full}</span>"
      else
        "<span class='text-blue-500 font-semibold'>#{full}</span>"
      end
    end)
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
    |> Enum.map(fn {field, msgs} ->
      "#{field}: #{Enum.join(msgs, ", ")}"
    end)
    |> Enum.join(" | ")
  end
end
