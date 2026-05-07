defmodule AlemWeb.ChatLive do
  use AlemWeb, :live_view
  import Ecto.Query
  alias Alem.{Chat, Social, Repo}
  alias Alem.Schemas.{Conversation, ConversationMember, Message}
  alias Alem.Pleroma.User
  require Logger

  @impl true
  def mount(%{"id" => conversation_id}, session, socket) do
    user = get_user(session)
    if is_nil(user), do: {:ok, redirect(socket, to: "/panel/login")}

    conversation = Repo.get(Conversation, conversation_id)
    did = user.did_id

    # Security: must be a member
    unless is_member?(conversation_id, did) do
      {:ok, redirect(socket, to: "/panel")}
    else
      if connected?(socket) do
        # Subscribe to real-time messages
        Phoenix.PubSub.subscribe(Alem.PubSub, "conversation:#{conversation_id}")
      end

      messages = Chat.load_messages(conversation_id, did, limit: 50)
      members  = load_members(conversation_id)
      Chat.mark_read(conversation_id, did)

      {:ok,
       socket
       |> assign(:user,            user)
       |> assign(:did,             did)
       |> assign(:conversation,    conversation)
       |> assign(:conversation_id, conversation_id)
       |> assign(:messages,        messages)
       |> assign(:members,         members)
       |> assign(:message_input,   "")
       |> assign(:flash_msg,       nil)
       |> assign(:show_members,    false)
       |> assign(:reply_to,        nil)}
    end
  end

  # ── Events ────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("send_message", %{"body" => body}, socket) do
    did  = socket.assigns.did
    cid  = socket.assigns.conversation_id
    body = String.trim(body)

    if body == "" do
      {:noreply, socket}
    else
      case Chat.send_message(cid, did, body) do
        {:ok, _msg} ->
          {:noreply, assign(socket, :message_input, "")}
        {:error, reason} ->
          {:noreply, flash(socket, "Error: #{inspect(reason)}", :error)}
      end
    end
  end

  def handle_event("set_input", %{"value" => val}, socket) do
    {:noreply, assign(socket, :message_input, val)}
  end

  def handle_event("delete_for_me", %{"id" => msg_id}, socket) do
    case Chat.delete_for_me(msg_id, socket.assigns.did) do
      {:ok, _} ->
        messages = Chat.load_messages(
          socket.assigns.conversation_id,
          socket.assigns.did
        )
        {:noreply, assign(socket, :messages, messages)}
      {:error, reason} ->
        {:noreply, flash(socket, "#{inspect(reason)}", :error)}
    end
  end

  def handle_event("delete_for_everyone", %{"id" => msg_id}, socket) do
    case Chat.delete_for_everyone(msg_id, socket.assigns.did) do
      {:ok, _} -> {:noreply, socket}
      {:error, reason} ->
        {:noreply, flash(socket, "#{inspect(reason)}", :error)}
    end
  end

  def handle_event("toggle_members", _, socket) do
    {:noreply, assign(socket, :show_members, !socket.assigns.show_members)}
  end

  def handle_event("reply_to", %{"id" => msg_id}, socket) do
    msg = Enum.find(socket.assigns.messages, &(&1.id == msg_id))
    {:noreply, assign(socket, :reply_to, msg)}
  end

  def handle_event("cancel_reply", _, socket) do
    {:noreply, assign(socket, :reply_to, nil)}
  end

  def handle_event("dismiss_flash", _, socket) do
    {:noreply, assign(socket, :flash_msg, nil)}
  end

  # ── PubSub handlers ───────────────────────────────────────────────────────

  @impl true
  def handle_info({:new_message, msg}, socket) do
    did = socket.assigns.did
    Chat.mark_read(socket.assigns.conversation_id, did)

    # Only append if message is visible to this user
    if Message.visible_to?(msg, did) do
      messages = socket.assigns.messages ++ [msg]
      {:noreply, assign(socket, :messages, messages)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:message_deleted, message_id}, socket) do
    messages =
      Enum.map(socket.assigns.messages, fn msg ->
        if msg.id == message_id do
          %{msg | deleted_for_everyone_at: DateTime.utc_now()}
        else
          msg
        end
      end)
    {:noreply, assign(socket, :messages, messages)}
  end

  # ── Render ────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <style>
      .chat-shell{display:flex;height:100vh;background:var(--bg)}
      .chat-sidebar{width:280px;background:var(--bg-2);border-right:1px solid var(--border);
        display:flex;flex-direction:column;overflow:hidden}
      .chat-main{flex:1;display:flex;flex-direction:column;overflow:hidden}
      .chat-header{padding:12px 16px;background:var(--bg-2);border-bottom:1px solid var(--border);
        display:flex;align-items:center;gap:12px;flex-shrink:0}
      .chat-avatar{width:36px;height:36px;border-radius:50%;background:linear-gradient(135deg,var(--primary),var(--purple));
        display:flex;align-items:center;justify-content:center;font-size:14px;font-weight:700;color:#fff;flex-shrink:0}
      .chat-name{font-size:14px;font-weight:600;color:var(--text)}
      .chat-meta{font-size:11px;color:var(--text-3)}
      .messages-area{flex:1;overflow-y:auto;padding:16px;display:flex;flex-direction:column;gap:8px}
      .msg{display:flex;gap:8px;max-width:75%;animation:fadeUp .15s ease}
      .msg.mine{align-self:flex-end;flex-direction:row-reverse}
      .msg.theirs{align-self:flex-start}
      .msg-avatar{width:28px;height:28px;border-radius:50%;background:var(--bg-4);
        display:flex;align-items:center;justify-content:center;font-size:11px;
        font-weight:700;color:var(--text-2);flex-shrink:0;align-self:flex-end}
      .msg-bubble{padding:8px 12px;border-radius:16px;max-width:100%;position:relative}
      .msg.mine .msg-bubble{background:var(--primary);color:#fff;border-bottom-right-radius:4px}
      .msg.theirs .msg-bubble{background:var(--bg-3);color:var(--text);border-bottom-left-radius:4px;
        border:1px solid var(--border)}
      .msg-text{font-size:13px;line-height:1.5;word-break:break-word}
      .msg-time{font-size:10px;opacity:.6;margin-top:3px}
      .msg-deleted{font-style:italic;opacity:.5;font-size:12px}
      .msg-actions{display:none;position:absolute;top:-28px;right:0;background:var(--bg-2);
        border:1px solid var(--border);border-radius:8px;padding:3px;
        display:flex;gap:2px;z-index:10}
      .msg:hover .msg-actions{display:flex}
      .msg-action-btn{background:none;border:none;cursor:pointer;padding:3px 6px;
        font-size:11px;color:var(--text-2);border-radius:4px}
      .msg-action-btn:hover{background:var(--bg-3);color:var(--text)}
      .reply-banner{background:var(--bg-3);border-left:3px solid var(--primary);
        padding:6px 12px;font-size:12px;color:var(--text-2);
        display:flex;justify-content:space-between;align-items:center}
      .chat-input-area{padding:12px 16px;background:var(--bg-2);
        border-top:1px solid var(--border);flex-shrink:0}
      .chat-input-row{display:flex;gap:8px;align-items:flex-end}
      .chat-input{flex:1;background:var(--bg-3);border:1px solid var(--border);
        border-radius:20px;padding:8px 16px;font-size:13px;color:var(--text);
        font-family:inherit;resize:none;outline:none;max-height:120px;
        line-height:1.5}
      .chat-input:focus{border-color:var(--primary)}
      .chat-send-btn{width:38px;height:38px;border-radius:50%;background:var(--primary);
        border:none;color:#fff;cursor:pointer;font-size:16px;
        display:flex;align-items:center;justify-content:center;flex-shrink:0}
      .chat-send-btn:hover{filter:brightness(1.1)}
      .member-list{padding:8px}
      .member-item{display:flex;align-items:center;gap:8px;padding:8px 10px;
        border-radius:8px;transition:background .15s}
      .member-item:hover{background:var(--bg-3)}
      .member-name{font-size:13px;color:var(--text)}
      .member-role{font-size:10px;color:var(--text-3)}
      @keyframes fadeUp{from{opacity:0;transform:translateY(4px)}to{opacity:1;transform:none}}
    </style>

    <!-- Flash -->
    <%= if @flash_msg do %>
      <div style="position:fixed;top:14px;right:14px;z-index:999;
                  background:var(--bg-2);border:1px solid var(--border);
                  border-radius:10px;padding:10px 16px;font-size:13px;
                  color:var(--text);box-shadow:var(--shadow)">
        <%= @flash_msg %>
        <button phx-click="dismiss_flash" style="margin-left:10px;background:none;border:none;cursor:pointer">×</button>
      </div>
    <% end %>

    <div class="chat-shell">

      <!-- Members sidebar (toggle) -->
      <%= if @show_members do %>
        <div class="chat-sidebar">
          <div style="padding:12px 16px;font-size:12px;font-weight:700;
                      color:var(--text-3);text-transform:uppercase;
                      letter-spacing:.8px;border-bottom:1px solid var(--border)">
            Members (<%= length(@members) %>)
          </div>
          <div class="member-list" style="flex:1;overflow-y:auto">
            <%= for m <- @members do %>
              <div class="member-item">
                <div class="chat-avatar" style="width:28px;height:28px;font-size:11px">
                  <%= String.first(m.nickname || "?") |> String.upcase() %>
                </div>
                <div>
                  <div class="member-name"><%= m.nickname %></div>
                  <div class="member-role"><%= m.role %></div>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>

      <!-- Main chat area -->
      <div class="chat-main">

        <!-- Header -->
        <div class="chat-header">
          <a href="/panel" style="color:var(--text-2);text-decoration:none;font-size:18px">←</a>
          <div class="chat-avatar">
            <%= if @conversation.type == "group" do %>
              👥
            <% else %>
              <%= get_other_member_initial(@members, @did) %>
            <% end %>
          </div>
          <div>
            <div class="chat-name">
              <%= if @conversation.type == "group" do %>
                <%= @conversation.name %>
              <% else %>
                <%= get_other_member_name(@members, @did) %>
              <% end %>
            </div>
            <div class="chat-meta">
              <%= if @conversation.type == "group" do %>
                <%= length(@members) %> members
              <% else %>
                Direct Message
              <% end %>
            </div>
          </div>
          <div style="flex:1"></div>
          <%= if @conversation.type == "group" do %>
            <button phx-click="toggle_members"
              style="background:none;border:none;cursor:pointer;
                     color:var(--text-2);font-size:18px"
              title="Members">👥</button>
          <% end %>
        </div>

        <!-- Messages -->
        <div class="messages-area" id="messages-area" phx-hook="ScrollBottom">
          <%= if @messages == [] do %>
            <div style="text-align:center;color:var(--text-3);
                        font-size:13px;padding:40px 0">
              No messages yet. Say hello! 👋
            </div>
          <% end %>

          <%= for msg <- @messages do %>
            <% is_mine = msg.sender_did == @did %>
            <% sender  = Enum.find(@members, &(&1.did == msg.sender_did)) %>

            <div class={"msg #{if is_mine, do: "mine", else: "theirs"}"}>

              <%= unless is_mine do %>
                <div class="msg-avatar">
                  <%= String.first(sender && sender.nickname || "?") |> String.upcase() %>
                </div>
              <% end %>

              <div style="display:flex;flex-direction:column;
                          #{if is_mine, do: "align-items:flex-end", else: "align-items:flex-start"}">

                <%= unless is_mine or @conversation.type == "direct" do %>
                  <div style="font-size:10px;color:var(--text-3);
                              margin-bottom:3px;padding:0 4px">
                    <%= sender && sender.nickname || "Unknown" %>
                  </div>
                <% end %>

                <div style="position:relative">
                  <!-- Action buttons on hover -->
                  <div class="msg-actions">
                    <button class="msg-action-btn" phx-click="reply_to"
                      phx-value-id={msg.id} title="Reply">↩</button>
                    <%= if is_mine do %>
                      <button class="msg-action-btn" phx-click="delete_for_me"
                        phx-value-id={msg.id} title="Delete for me"
                        style="color:var(--amber)">🗂</button>
                      <button class="msg-action-btn" phx-click="delete_for_everyone"
                        phx-value-id={msg.id} title="Delete for everyone"
                        style="color:var(--red)">🗑</button>
                    <% end %>
                  </div>

                  <div class="msg-bubble">
                    <%= if msg.deleted_for_everyone_at do %>
                      <div class="msg-deleted">🚫 This message was deleted</div>
                    <% else %>
                      <%= case msg.content_type do %>
                        <% "text" -> %>
                          <div class="msg-text"><%= msg.body %></div>
                        <% "perception_link" -> %>
                          <div class="msg-text">
                            📎 Shared a file
                            <a href="#" style="color:#{if is_mine, do: "#fff", else: "var(--primary)"};
                                               text-decoration:underline;font-size:12px">
                              View
                            </a>
                          </div>
                        <% "system" -> %>
                          <div class="msg-text" style="opacity:.6;font-style:italic">
                            <%= msg.body %>
                          </div>
                        <% _ -> %>
                          <div class="msg-text"><%= msg.body %></div>
                      <% end %>
                    <% end %>
                    <div class="msg-time"><%= format_time(msg.sent_at) %></div>
                  </div>
                </div>
              </div>
            </div>
          <% end %>
        </div>

        <!-- Reply banner -->
        <%= if @reply_to do %>
          <div class="reply-banner">
            <div>
              Replying to <strong><%= get_sender_name(@members, @reply_to.sender_did) %></strong>:
              <span style="opacity:.7"><%= String.slice(@reply_to.body || "", 0, 60) %></span>
            </div>
            <button phx-click="cancel_reply"
              style="background:none;border:none;cursor:pointer;
                     color:var(--text-3);font-size:16px">×</button>
          </div>
        <% end %>

        <!-- Input area -->
        <div class="chat-input-area">
          <form phx-submit="send_message">
            <div class="chat-input-row">
              <textarea
                class="chat-input"
                name="body"
                placeholder="Type a message..."
                rows="1"
                value={@message_input}
                phx-change="set_input"
                phx-key="Enter"
                phx-keydown="send_message"
              ></textarea>
              <button type="submit" class="chat-send-btn">➤</button>
            </div>
          </form>
        </div>
      </div>
    </div>

    <script>
      // Auto-scroll to bottom on new messages
      window.addEventListener("phx:update", function() {
        var el = document.getElementById("messages-area");
        if (el) el.scrollTop = el.scrollHeight;
      });
      // Auto-scroll on mount
      document.addEventListener("DOMContentLoaded", function() {
        var el = document.getElementById("messages-area");
        if (el) el.scrollTop = el.scrollHeight;
      });
      // Enter to send (Shift+Enter for new line)
      document.addEventListener("keydown", function(e) {
        if (e.key === "Enter" && !e.shiftKey && document.activeElement.name === "body") {
          e.preventDefault();
          document.querySelector("form").requestSubmit();
        }
      });
    </script>
    """
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp get_user(session) do
    case session["user_id"] do
      nil -> nil
      uid -> Repo.get(User, uid)
    end
  end

  defp is_member?(conversation_id, did) do
    import Ecto.Query
    Repo.exists?(
      from m in ConversationMember,
      where: m.conversation_id == ^conversation_id and
             m.member_did == ^did and
             is_nil(m.left_at)
    )
  end

  defp load_members(conversation_id) do
    Repo.all(
      from m in ConversationMember,
      join: u in User, on: u.did_id == m.member_did,
      where: m.conversation_id == ^conversation_id and is_nil(m.left_at),
      select: %{
        did:      m.member_did,
        role:     m.role,
        nickname: u.nickname,
        avatar:   u.avatar
      }
    )
  end

  defp get_other_member_name(members, my_did) do
    case Enum.find(members, &(&1.did != my_did)) do
      nil -> "Unknown"
      m   -> m.nickname
    end
  end

  defp get_other_member_initial(members, my_did) do
    name = get_other_member_name(members, my_did)
    String.first(name) |> String.upcase()
  end

  defp get_sender_name(members, sender_did) do
    case Enum.find(members, &(&1.did == sender_did)) do
      nil -> "Unknown"
      m   -> m.nickname
    end
  end

  defp format_time(nil), do: ""
  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M")
  end
  defp format_time(%NaiveDateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M")
  end

  defp flash(socket, msg, _type) do
    assign(socket, :flash_msg, msg)
  end
end
