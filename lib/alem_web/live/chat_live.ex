defmodule AlemWeb.ChatLive do
  use AlemWeb, :live_view
  import Ecto.Query
  alias Alem.{Chat, Repo}
  alias Alem.Schemas.{Conversation, ConversationMember, Message}
  alias Alem.Pleroma.User

  @vaults %{0 => "personal", 1 => "private", 2 => "public"}

  @impl true
  def mount(%{"id" => cid}, session, socket) do
    user = case session["user_id"] do
      nil -> nil
      uid -> Repo.get(User, uid)
    end
    if is_nil(user), do: {:ok, Phoenix.LiveView.redirect(socket, to: "/panel/login")}
    did  = user.did_id
    conv = Repo.get(Conversation, cid)
    unless Repo.exists?(from m in ConversationMember,
      where: m.conversation_id == ^cid and m.member_did == ^did and is_nil(m.left_at)) do
      {:ok, Phoenix.LiveView.redirect(socket, to: "/panel")}
    else
      if connected?(socket), do: Phoenix.PubSub.subscribe(Alem.PubSub, "conversation:#{cid}")
      messages = Chat.load_messages(cid, did, limit: 50)
      members  = Repo.all(from m in ConversationMember,
        join: u in User, on: u.did_id == m.member_did,
        where: m.conversation_id == ^cid and is_nil(m.left_at),
        select: %{did: m.member_did, role: m.role, nickname: u.nickname})
      Chat.mark_read(cid, did)
      {:ok, socket
        |> assign(:user, user) |> assign(:did, did)
        |> assign(:conversation, conv) |> assign(:conversation_id, cid)
        |> assign(:messages, messages) |> assign(:members, members)
        |> assign(:flash_msg, nil) |> assign(:show_members, false)
        |> allow_upload(:chat_file, accept: :any, max_entries: 1,
            max_file_size: 50_000_000, auto_upload: false)}
    end
  end

  @impl true
  def handle_event("send_message", %{"body" => body}, socket) do
    body = String.trim(body)
    if body != "", do: Chat.send_message(socket.assigns.conversation_id, socket.assigns.did, body)
    {:noreply, socket}
  end

  def handle_event("validate_file", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :chat_file, ref)}

  def handle_event("upload_file", _params, socket) do
    user = socket.assigns.user
    cid  = socket.assigns.conversation_id

    case socket.assigns.uploads.chat_file.entries do
      [] ->
        {:noreply, assign(socket, :flash_msg, "No file selected")}

      [entry] ->
        if entry.progress < 100 do
          {:noreply, assign(socket, :flash_msg, "Still uploading, please wait...")}
        else
          # Phase 3: all chat upload logic delegated to ChatApi
          result = consume_uploaded_entries(socket, :chat_file, fn %{path: tmp}, entry ->
            file_params = %{
              path:         tmp,
              filename:     entry.client_name,
              content_type: entry.client_type || "application/octet-stream",
              size:         entry.client_size
            }
            Alem.Api.ChatApi.upload_file(user, cid, file_params)
          end)

          case result do
            [{:ok, %{flash: flash}}] ->
              {:noreply, assign(socket, :flash_msg, flash)}
            _ ->
              {:noreply, assign(socket, :flash_msg, "Upload failed")}
          end
        end
    end
  end

  def handle_event("delete_for_me", %{"id" => mid}, socket) do
    Chat.delete_for_me(mid, socket.assigns.did)
    {:noreply, assign(socket, :messages, Chat.load_messages(socket.assigns.conversation_id, socket.assigns.did))}
  end

  def handle_event("delete_for_everyone", %{"id" => mid}, socket) do
    Chat.delete_for_everyone(mid, socket.assigns.did)
    {:noreply, socket}
  end

  def handle_event("toggle_members", _, socket),
    do: {:noreply, assign(socket, :show_members, !socket.assigns.show_members)}

  def handle_event("dismiss_flash", _, socket),
    do: {:noreply, assign(socket, :flash_msg, nil)}

  @impl true
  def handle_info({:new_message, msg}, socket) do
    Chat.mark_read(socket.assigns.conversation_id, socket.assigns.did)
    {:noreply, assign(socket, :messages, socket.assigns.messages ++ [msg])}
  end

  def handle_info({:message_deleted, mid}, socket) do
    msgs = Enum.map(socket.assigns.messages, fn m ->
      if m.id == mid, do: %{m | deleted_for_everyone_at: DateTime.utc_now()}, else: m
    end)
    {:noreply, assign(socket, :messages, msgs)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <style>
      :root,[data-theme="dark"]{--bg:#0c0e13;--bg-2:#13161e;--bg-3:#1a1e29;--bg-4:#222737;--border:rgba(255,255,255,.07);--text:#f0f2f8;--text-2:#8b92a9;--text-3:#4e566b;--primary:#5c73f2;--green:#10b981;--red:#ef4444;--purple:#a78bfa;color-scheme:dark}
      [data-theme="light"]{--bg:#f2f4f8;--bg-2:#fff;--bg-3:#f8f9fc;--bg-4:#eef0f6;--border:rgba(0,0,0,.07);--text:#0f1117;--text-2:#5a6172;--text-3:#9ca3b4;--primary:#4f63e8;--red:#dc2626;color-scheme:light}
      *,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
      body{font-family:'DM Sans',system-ui,sans-serif;background:var(--bg);color:var(--text)}
      .shell{display:flex;height:100vh}
      .main{flex:1;display:flex;flex-direction:column;overflow:hidden}
      .hdr{padding:12px 16px;background:var(--bg-2);border-bottom:1px solid var(--border);display:flex;align-items:center;gap:12px;flex-shrink:0}
      .av{width:36px;height:36px;border-radius:50%;background:linear-gradient(135deg,var(--primary),var(--purple));display:flex;align-items:center;justify-content:center;font-size:14px;font-weight:700;color:#fff;flex-shrink:0}
      .msgs{flex:1;overflow-y:auto;padding:16px;display:flex;flex-direction:column;gap:8px}
      .msg{display:flex;gap:8px;max-width:75%}
      .msg.mine{align-self:flex-end;flex-direction:row-reverse}
      .msg.theirs{align-self:flex-start}
      .mav{width:28px;height:28px;border-radius:50%;background:var(--bg-4);display:flex;align-items:center;justify-content:center;font-size:11px;font-weight:700;color:var(--text-2);flex-shrink:0;align-self:flex-end}
      .bub{padding:8px 12px;border-radius:16px;position:relative}
      .mine .bub{background:var(--primary);color:#fff;border-bottom-right-radius:4px}
      .theirs .bub{background:var(--bg-3);color:var(--text);border-bottom-left-radius:4px;border:1px solid var(--border)}
      .bt{font-size:13px;line-height:1.5;word-break:break-word}
      .btime{font-size:10px;opacity:.55;margin-top:3px}
      .bdel{font-style:italic;opacity:.5;font-size:12px}
      .acts{display:none;position:absolute;top:-28px;right:0;background:var(--bg-2);border:1px solid var(--border);border-radius:8px;padding:3px;gap:2px;z-index:10}
      .msg:hover .acts{display:flex}
      .ab{background:none;border:none;cursor:pointer;padding:3px 6px;font-size:11px;color:var(--text-2);border-radius:4px}
      .ab:hover{background:var(--bg-3)}
      .ia{padding:12px 16px;background:var(--bg-2);border-top:1px solid var(--border);flex-shrink:0}
      .ir{display:flex;gap:8px;align-items:flex-end}
      .ci{flex:1;background:var(--bg-3);border:1px solid var(--border);border-radius:20px;padding:8px 16px;font-size:13px;color:var(--text);font-family:inherit;resize:none;outline:none;max-height:120px;line-height:1.5}
      .ci:focus{border-color:var(--primary)}
      .sb{width:38px;height:38px;border-radius:50%;background:var(--primary);border:none;color:#fff;cursor:pointer;font-size:16px;display:flex;align-items:center;justify-content:center;flex-shrink:0}
      .al{width:34px;height:34px;border-radius:50%;background:var(--bg-4);border:1px solid var(--border);color:var(--text-2);cursor:pointer;font-size:16px;display:flex;align-items:center;justify-content:center;flex-shrink:0}
      .al:hover{background:var(--bg-3);color:var(--primary)}
      .upbar{background:var(--bg-3);border:1px solid var(--border);border-radius:10px;padding:8px 12px;margin-bottom:8px;display:flex;align-items:center;gap:10px}
      .upname{font-size:12px;font-weight:600;color:var(--text);flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
      .upsend{background:var(--green);color:#fff;border:none;border-radius:6px;padding:5px 12px;font-size:11px;font-weight:600;cursor:pointer;font-family:inherit}
      .upx{background:none;border:none;cursor:pointer;color:var(--text-3);font-size:18px;line-height:1}
    </style>

    <%= if @flash_msg do %>
      <div style="position:fixed;top:14px;right:14px;z-index:999;background:var(--bg-2);border:1px solid var(--border);border-radius:10px;padding:10px 16px;font-size:13px;color:var(--text);box-shadow:0 4px 16px rgba(0,0,0,.3);display:flex;gap:10px;align-items:center">
        <%= @flash_msg %>
        <button phx-click="dismiss_flash" style="background:none;border:none;cursor:pointer;color:var(--text-3)">&#215;</button>
      </div>
    <% end %>

    <div class="shell">
      <div class="main">
        <div class="hdr">
          <a href="/chats" style="color:var(--text-2);text-decoration:none;font-size:20px">&#8592;</a>
          <div class="av">
            <%= if @conversation && @conversation.type == "group", do: "G", else: other_initial(@members, @did) %>
          </div>
          <div>
            <div style="font-size:14px;font-weight:600;color:var(--text)">
              <%= if @conversation && @conversation.type == "group", do: @conversation.name, else: other_name(@members, @did) %>
            </div>
            <div style="font-size:11px;color:var(--text-3)">
              <%= if @conversation && @conversation.type == "group", do: "#{length(@members)} members", else: "Direct Message" %>
            </div>
          </div>
          <div style="flex:1"></div>
          <%= if @conversation && @conversation.type == "group" do %>
            <button phx-click="toggle_members" style="background:none;border:none;cursor:pointer;color:var(--text-2);font-size:18px">M</button>
          <% end %>
        </div>

        <div class="msgs" id="msgs">
          <%= if @messages == [] do %>
            <div style="text-align:center;color:var(--text-3);font-size:13px;padding:40px 0">No messages yet. Say hello!</div>
          <% end %>
          <%= for msg <- @messages do %>
            <% is_mine = msg.sender_did == @did %>
            <% s = Enum.find(@members, &(&1.did == msg.sender_did)) %>
            <div class={if is_mine, do: "msg mine", else: "msg theirs"} id={"msg-#{msg.id}"}>
              <%= unless is_mine do %>
                <div class="mav"><%= String.upcase(String.first((s && s.nickname) || "?")) %></div>
              <% end %>
              <div style={msg_align(is_mine)}>
                <div style="position:relative">
                  <div class="acts">
                    <%= if is_mine do %>
                      <button class="ab" phx-click="delete_for_me" phx-value-id={msg.id} title="Delete for me">D</button>
                      <button class="ab" phx-click="delete_for_everyone" phx-value-id={msg.id} style="color:var(--red)" title="Delete for everyone">X</button>
                    <% end %>
                  </div>
                  <div class="bub">
                    <%= if msg.deleted_for_everyone_at do %>
                      <div class="bdel">This message was deleted</div>
                    <% else %>
                      <%= if msg.content_type == "perception_link" do %>
                        <div style="display:flex;align-items:center;gap:8px;padding:2px 0">
                          <span style="font-size:20px"><%= ficon(msg.body) %></span>
                          <div>
                            <div style="font-size:12px;font-weight:600;max-width:180px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap"><%= msg.body %></div>
                            <div style="font-size:10px;opacity:.6">Shared file</div>
                          </div>
                        </div>
                      <% else %>
                        <div class="bt"><%= msg.body %></div>
                      <% end %>
                    <% end %>
                    <div class="btime"><%= ftime(msg.sent_at) %></div>
                  </div>
                </div>
              </div>
            </div>
          <% end %>
        </div>

        <%= for entry <- @uploads.chat_file.entries do %>
          <div class="upbar">
            <span style="font-size:18px"><%= ficon(entry.client_name) %></span>
            <div class="upname"><%= entry.client_name %> (<%= Float.round(entry.client_size / 1024, 1) %> KB)</div>
            <button class="upsend" phx-click="upload_file">Send</button>
            <button class="upx" phx-click="cancel_upload" phx-value-ref={entry.ref}>&#215;</button>
          </div>
        <% end %>

        <div class="ia">
          <form phx-submit="send_message">
            <div class="ir">
              <label class="al" title="Attach file">
                +
                <.live_file_input upload={@uploads.chat_file} style="display:none" phx-change="validate_file" />
              </label>
              <textarea class="ci" name="body" placeholder="Type a message..." rows="1"></textarea>
              <button type="submit" class="sb">Go</button>
            </div>
          </form>
        </div>
      </div>

      <%= if @show_members do %>
        <div style="width:200px;background:var(--bg-2);border-left:1px solid var(--border);padding:8px;overflow-y:auto">
          <div style="font-size:11px;font-weight:700;color:var(--text-3);text-transform:uppercase;letter-spacing:.8px;padding:8px">Members</div>
          <%= for m <- @members do %>
            <div style="display:flex;align-items:center;gap:8px;padding:6px 8px;border-radius:6px">
              <div class="av" style="width:24px;height:24px;font-size:10px"><%= String.upcase(String.first(m.nickname || "?")) %></div>
              <span style="font-size:12px;color:var(--text)"><%= m.nickname %></span>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    <script>
      (function(){var s=localStorage.getItem("przma-theme");var sys=window.matchMedia("(prefers-color-scheme:light)").matches?"light":"dark";document.documentElement.setAttribute("data-theme",s||sys)})();
      function sb(){var e=document.getElementById("msgs");if(e)e.scrollTop=e.scrollHeight}
      window.addEventListener("phx:update",sb);
      document.addEventListener("DOMContentLoaded",sb);
      document.addEventListener("keydown",function(e){if(e.key==="Enter"&&!e.shiftKey&&document.activeElement.name==="body"){e.preventDefault();document.querySelector("form").requestSubmit()}});
    </script>
    """
  end

  defp msg_align(true),  do: "display:flex;flex-direction:column;align-items:flex-end"
  defp msg_align(false), do: "display:flex;flex-direction:column;align-items:flex-start"

  defp other_name(members, my_did) do
    case Enum.find(members, &(&1.did != my_did)) do
      nil -> "Unknown"
      m   -> m.nickname
    end
  end

  defp other_initial(members, my_did),
    do: String.upcase(String.first(other_name(members, my_did)))

  defp ficon(n) when is_binary(n) do
    cond do
      n =~ ~r/\.pdf$/i  -> "PDF"
      n =~ ~r/\.docx?$/i -> "DOC"
      n =~ ~r/\.(jpg|jpeg|png|gif|webp)$/i -> "IMG"
      n =~ ~r/\.(mp4|mov)$/i -> "VID"
      n =~ ~r/\.mp3$/i  -> "AUD"
      n =~ ~r/\.zip$/i  -> "ZIP"
      true -> "FILE"
    end
  end
  defp ficon(_), do: "FILE"

  defp ftime(nil), do: ""
  defp ftime(%DateTime{} = dt),      do: Calendar.strftime(dt, "%H:%M")
  defp ftime(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%H:%M")
  defp ftime(_), do: ""
end
