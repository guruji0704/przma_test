defmodule AlemWeb.SocialLive do
  use AlemWeb, :live_view
  alias Alem.{Repo, Social}
  alias Alem.Pleroma.User
  import Ecto.Query

  @impl true
  def mount(_params, session, socket) do
    user = case session["user_id"] do
      nil -> nil
      uid -> Repo.get(User, uid)
    end
    if is_nil(user), do: {:ok, redirect(socket, to: "/panel/login")}
    {:ok, load_all(socket, user)}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # ── Reload all social data into assigns ──────────────────────────────────
  defp load_all(socket, user) do
    did   = user.did_id
    users = Repo.all(from u in User,
              where: u.id != ^user.id and not is_nil(u.did_id),
              select: %{id: u.id, nickname: u.nickname, did_id: u.did_id, avatar: u.avatar})

    following  = Social.following_list(did)
    followers  = Social.followers_list(did)
    conns      = Social.connections_list(did)
    pending    = Social.pending_requests(did)

    # Pre-compute connection statuses as a map did → status
    conn_map = Map.new(users, fn u ->
      {u.did_id, Social.connection_status(did, u.did_id)}
    end)

    # Pre-compute who we follow as a MapSet
    following_set = MapSet.new(following, & &1.did)

    socket
    |> assign(:user,           user)
    |> assign(:did,            did)
    |> assign(:all_users,      users)
    |> assign(:connections,    conns)
    |> assign(:pending,        pending)
    |> assign(:followers,      followers)
    |> assign(:following,      following)
    |> assign(:following_set,  following_set)
    |> assign(:conn_map,       conn_map)
    |> assign(:flash_msg,      nil)
  end

  defp reload(socket) do
    user = socket.assigns.user
    load_all(socket, user)
  end

  # ── Events ────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("follow", %{"did" => target_did}, socket) do
    Social.follow(socket.assigns.did, target_did)
    {:noreply, reload(socket) |> assign(:flash_msg, "✅ Following!")}
  end

  def handle_event("unfollow", %{"did" => target_did}, socket) do
    Social.unfollow(socket.assigns.did, target_did)
    {:noreply, reload(socket) |> assign(:flash_msg, "Unfollowed")}
  end

  def handle_event("connect", %{"did" => target_did}, socket) do
    case Social.request_connection(socket.assigns.did, target_did) do
      {:ok, _}         -> {:noreply, reload(socket) |> assign(:flash_msg, "✅ Connection request sent!")}
      {:error, reason} -> {:noreply, assign(socket, :flash_msg, "#{reason}")}
    end
  end

  def handle_event("accept", %{"did" => requester_did}, socket) do
    Social.accept_connection(requester_did, socket.assigns.did)
    {:noreply, reload(socket) |> assign(:flash_msg, "✅ Connected!")}
  end

  def handle_event("reject", %{"did" => requester_did}, socket) do
    Social.reject_connection(requester_did, socket.assigns.did)
    {:noreply, reload(socket) |> assign(:flash_msg, "Rejected")}
  end

  def handle_event("start_chat", %{"did" => target_did}, socket) do
    my_did = socket.assigns.did
    case Alem.Chat.get_or_create_dm(my_did, target_did) do
      {:ok, conv} ->
        {:noreply, Phoenix.LiveView.redirect(socket, to: "/chat/#{conv.id}")}
      {:error, reason} ->
        {:noreply, assign(socket, :flash_msg, "Chat error: #{inspect(reason)}")}
    end
  end

  def handle_event("dismiss_flash", _, socket) do
    {:noreply, assign(socket, :flash_msg, nil)}
  end

  # ── Render ────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <style>
      :root,[data-theme="dark"]{--bg:#0c0e13;--bg-2:#13161e;--bg-3:#1a1e29;--bg-4:#222737;--border:rgba(255,255,255,0.07);--border-2:rgba(255,255,255,0.13);--text:#f0f2f8;--text-2:#8b92a9;--text-3:#4e566b;--primary:#5c73f2;--primary-d:rgba(92,115,242,0.15);--green:#10b981;--green-d:rgba(16,185,129,0.12);--amber:#f59e0b;--red:#ef4444;--red-d:rgba(239,68,68,0.12);--purple:#a78bfa;--shadow:0 1px 3px rgba(0,0,0,0.5),0 4px 16px rgba(0,0,0,0.25);--r:10px;--r-sm:6px;--r-lg:14px;color-scheme:dark}
      [data-theme="light"]{--bg:#f2f4f8;--bg-2:#fff;--bg-3:#f8f9fc;--bg-4:#eef0f6;--border:rgba(0,0,0,0.07);--text:#0f1117;--text-2:#5a6172;--text-3:#9ca3b4;--primary:#4f63e8;--green:#059669;--green-d:rgba(5,150,105,0.1);--red:#dc2626;--red-d:rgba(220,38,38,0.1);--shadow:0 1px 3px rgba(0,0,0,0.08);color-scheme:light}
      *,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
      body{font-family:'DM Sans',system-ui,sans-serif;background:var(--bg);color:var(--text)}
      .sg{display:grid;grid-template-columns:1fr 1fr;gap:16px;max-width:900px}
      @media(max-width:640px){.sg{grid-template-columns:1fr}}
      .sc{background:var(--bg-2);border:1px solid var(--border);border-radius:var(--r-lg);padding:16px}
      .sc h3{font-size:12px;font-weight:700;color:var(--text-3);text-transform:uppercase;letter-spacing:.8px;margin-bottom:12px;padding-bottom:8px;border-bottom:1px solid var(--border)}
      .ur{display:flex;align-items:center;gap:10px;padding:8px 0;border-bottom:1px solid var(--border)}
      .ur:last-child{border-bottom:none}
      .av{width:32px;height:32px;border-radius:50%;background:linear-gradient(135deg,var(--primary),var(--purple));display:flex;align-items:center;justify-content:center;font-size:13px;font-weight:700;color:#fff;flex-shrink:0}
      .un{font-size:13px;font-weight:600;color:var(--text);flex:1}
      .ud{font-size:10px;color:var(--text-3);font-family:monospace;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:160px}
      .btn{padding:5px 11px;border-radius:6px;font-size:11px;font-weight:600;cursor:pointer;border:1px solid transparent;font-family:inherit;transition:filter .15s}
      .btn:hover{filter:brightness(1.1)}
      .bf{background:var(--primary);color:#fff;border-color:var(--primary)}
      .bu{background:var(--bg-4);color:var(--text-2);border-color:var(--border-2)}
      .bc{background:var(--green-d);color:var(--green);border-color:var(--green)}
      .ba{background:var(--green-d);color:var(--green);border-color:var(--green)}
      .br{background:var(--red-d);color:var(--red);border-color:var(--red)}
      .tag{font-size:10px;color:var(--text-3);padding:3px 7px;border-radius:4px;background:var(--bg-3);border:1px solid var(--border)}
      .empty{color:var(--text-3);font-size:12px;text-align:center;padding:20px 0}
      .stat-bar{display:flex;gap:20px;font-size:12px;color:var(--text-2)}
      .stat-bar strong{color:var(--text);font-size:15px;font-weight:700;display:block}
    </style>

    <!-- Flash -->
    <%= if @flash_msg do %>
      <div style="position:fixed;top:14px;right:14px;z-index:999;background:var(--bg-2);border:1px solid var(--border);border-radius:10px;padding:10px 16px;font-size:13px;color:var(--text);box-shadow:var(--shadow);display:flex;gap:12px;align-items:center">
        <%= @flash_msg %>
        <button phx-click="dismiss_flash" style="background:none;border:none;cursor:pointer;color:var(--text-3);font-size:16px;line-height:1">×</button>
      </div>
    <% end %>

    <div style="padding:20px;max-width:960px;margin:0 auto">

      <!-- Header -->
      <div style="display:flex;align-items:center;gap:12px;margin-bottom:20px">
        <a href="/panel" style="color:var(--text-2);text-decoration:none;font-size:20px;line-height:1">←</a>
        <h2 style="font-size:18px;font-weight:700;color:var(--text)">Social</h2>
        <div style="flex:1"></div>
        <!-- Stats -->
        <div class="stat-bar">
          <div style="text-align:center">
            <strong><%= length(@following) %></strong>Following
          </div>
          <div style="text-align:center">
            <strong><%= length(@followers) %></strong>Followers
          </div>
          <div style="text-align:center">
            <strong><%= length(@connections) %></strong>Connected
          </div>
          <div style="text-align:center">
            <strong><%= length(@pending) %></strong>Pending
          </div>
        </div>
      </div>

      <div class="sg">

        <!-- All Users -->
        <div class="sc">
          <h3>👥 All Users</h3>
          <%= if @all_users == [] do %>
            <div class="empty">No other users found</div>
          <% else %>
            <%= for u <- @all_users do %>
              <% is_following = MapSet.member?(@following_set, u.did_id) %>
              <% conn_status  = Map.get(@conn_map, u.did_id, :none) %>
              <div class="ur">
                <div class="av"><%= String.upcase(String.first(u.nickname || "?")) %></div>
                <div style="flex:1;min-width:0">
                  <div class="un"><%= u.nickname %></div>
                  <div class="ud"><%= String.slice(u.did_id || "", 0, 30) %>…</div>
                </div>
                <div style="display:flex;gap:4px;flex-shrink:0">
                  <%= if is_following do %>
                    <button class="btn bu" phx-click="unfollow" phx-value-did={u.did_id}>Unfollow</button>
                  <% else %>
                    <button class="btn bf" phx-click="follow" phx-value-did={u.did_id}>Follow</button>
                  <% end %>
                  <%= case conn_status do %>
                    <% :none -> %>
                      <button class="btn bc" phx-click="connect" phx-value-did={u.did_id}>Connect</button>
                    <% :pending -> %>
                      <span class="tag">Pending</span>
                    <% :accepted -> %>
                      <span class="tag" style="color:var(--green);border-color:var(--green)">✓ Connected</span>
                    <% :rejected -> %>
                      <button class="btn bc" phx-click="connect" phx-value-did={u.did_id}>Re-connect</button>
                    <% _ -> %>
                      <span class="tag"><%= conn_status %></span>
                  <% end %>
                </div>
              </div>
            <% end %>
          <% end %>
        </div>

        <!-- Pending Requests -->
        <div class="sc">
          <h3>🔔 Pending Requests (<%= length(@pending) %>)</h3>
          <%= if @pending == [] do %>
            <div class="empty">No pending requests</div>
          <% else %>
            <%= for p <- @pending do %>
              <div class="ur">
                <div class="av"><%= String.upcase(String.first(p.from_nickname || "?")) %></div>
                <div style="flex:1;min-width:0">
                  <div class="un"><%= p.from_nickname %></div>
                  <div style="font-size:11px;color:var(--text-3)">wants to connect</div>
                </div>
                <div style="display:flex;gap:4px">
                  <button class="btn ba" phx-click="accept" phx-value-did={p.from_did}>✓ Accept</button>
                  <button class="btn br" phx-click="reject" phx-value-did={p.from_did}>✕</button>
                </div>
              </div>
            <% end %>
          <% end %>
        </div>

        <!-- Connections -->
        <div class="sc">
          <h3>💬 Connections (<%= length(@connections) %>)</h3>
          <%= if @connections == [] do %>
            <div class="empty">No connections yet.<br/>Connect with someone to start chatting.</div>
          <% else %>
            <%= for c <- @connections do %>
              <div class="ur">
                <div class="av"><%= String.upcase(String.first(c.nickname || "?")) %></div>
                <div style="flex:1">
                  <div class="un"><%= c.nickname %></div>
                </div>
                <button class="btn" phx-click="start_chat" phx-value-did={c.did}
                  style="font-size:11px;font-weight:600;color:var(--primary);padding:5px 10px;border-radius:6px;border:1px solid var(--primary);background:none;cursor:pointer;font-family:inherit">
                  💬 Chat
                </button>
              </div>
            <% end %>
          <% end %>
        </div>

        <!-- Following -->
        <div class="sc">
          <h3>👣 Following (<%= length(@following) %>)</h3>
          <%= if @following == [] do %>
            <div class="empty">Not following anyone yet</div>
          <% else %>
            <%= for f <- @following do %>
              <div class="ur">
                <div class="av"><%= String.upcase(String.first(f.nickname || "?")) %></div>
                <div style="flex:1"><div class="un"><%= f.nickname %></div></div>
                <button class="btn bu" phx-click="unfollow" phx-value-did={f.did}>Unfollow</button>
              </div>
            <% end %>
          <% end %>
        </div>

      </div>
    </div>
    <script>
      (function(){var s=localStorage.getItem("przma-theme");var sys=window.matchMedia("(prefers-color-scheme: light)").matches?"light":"dark";document.documentElement.setAttribute("data-theme",s||sys)})();
    </script>
    """
  end
end
