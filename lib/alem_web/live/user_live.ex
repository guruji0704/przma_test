defmodule AlemWeb.UserLive do
  use AlemWeb, :live_view
  import Ecto.Query
  alias Alem.Schemas.Document
  alias Alem.Repo
  require Logger

  @impl true
  def mount(_params, _session, socket) do
    user = %{id: "demo_user", nickname: "Demo User", email: "demo@przma.com",
             did_id: "did:przma:demo001", is_active: true, is_verified: true, plan: "free"}
    {:ok,
     socket
     |> assign(:page_title,     "My Panel")
     |> assign(:user,           user)
     |> assign(:page,           :home)
     |> assign(:files,          [])
     |> assign(:files_filter,   "all")
     |> assign(:files_search,   "")
     |> assign(:sessions,       [])
     |> assign(:storage_stats,  nil)
     |> assign(:lance_tables,   [])
     |> assign(:total_files,    count_files("demo_user"))
     |> assign(:last_sync,      get_last_sync("demo_user"))
     |> assign(:flash_msg,      nil)
     |> assign(:flash_type,     :success)
     |> assign(:confirm_action, nil)
     |> assign(:edit_profile,   false)}
  end

  defp count_files(uid) do
    try do Repo.aggregate(from(d in Document, where: d.user_id == ^uid), :count, :id)
    rescue _ -> 0 end
  end

  defp get_last_sync(uid) do
    try do
      Repo.one(from d in Document, where: d.user_id == ^uid,
        order_by: [desc: d.updated_at], limit: 1, select: d.updated_at)
    rescue _ -> nil end
  end

  @impl true
  def handle_event("nav", %{"page" => page}, socket) do
    page_atom = String.to_existing_atom(page)
    socket = socket |> assign(:page, page_atom) |> assign(:confirm_action, nil) |> load_page(page_atom)
    {:noreply, socket}
  rescue
    _ -> {:noreply, socket}
  end

  defp load_page(socket, :files) do
    uid = socket.assigns.user.id
    files = try do
      Repo.all(from d in Document, where: d.user_id == ^uid,
        order_by: [desc: d.inserted_at], limit: 100,
        select: %{id: d.id, filename: d.filename, content_type: d.content_type,
                  status: d.status, inserted_at: d.inserted_at})
    rescue _ -> [] end
    assign(socket, :files, files)
  end

  defp load_page(socket, :storage) do
    uid = socket.assigns.user.id
    stats = try do
      total = Repo.aggregate(from(d in Document, where: d.user_id == ^uid), :count, :id)
      by_type = Repo.all(from d in Document, where: d.user_id == ^uid,
        group_by: d.content_type, select: {d.content_type, count(d.id)})
      %{total_files: total, by_type: Enum.into(by_type, %{})}
    rescue _ -> %{total_files: 0, by_type: %{}} end
    assign(socket, :storage_stats, stats)
  end

  defp load_page(socket, :sessions) do
    uid = socket.assigns.user.id
    sessions = try do
      Repo.all(from s in Alem.Session, where: s.user_id == ^uid and is_nil(s.revoked_at),
        order_by: [desc: s.last_active_at], limit: 20,
        select: %{id: s.id, device: s.device, last_active_at: s.last_active_at, inserted_at: s.inserted_at})
    rescue _ -> [] end
    assign(socket, :sessions, sessions)
  end

  defp load_page(socket, :lance) do
    tables = try do
      case Alem.LanceDB.list_tables() do {:ok, t} -> t; _ -> [] end
    rescue _ -> [] end
    assign(socket, :lance_tables, tables)
  end

  defp load_page(socket, _), do: socket

  def handle_event("search_files", %{"search" => q}, socket), do: {:noreply, assign(socket, :files_search, q)}
  def handle_event("filter_files", %{"filter" => f}, socket), do: {:noreply, assign(socket, :files_filter, f)}

  def handle_event("revoke_session", %{"id" => id}, socket) do
    try do
      Repo.get(Alem.Session, id) |> Ecto.Changeset.change(%{revoked_at: DateTime.utc_now()}) |> Repo.update()
    rescue _ -> :ok end
    socket = load_page(assign(socket, :page, :sessions), :sessions)
    {:noreply, flash(socket, "Session revoked", :success)}
  end

  def handle_event("revoke_all_sessions", _, socket) do
    try do
      uid = socket.assigns.user.id
      Repo.update_all(from(s in Alem.Session, where: s.user_id == ^uid and is_nil(s.revoked_at)),
        set: [revoked_at: DateTime.utc_now()])
    rescue _ -> :ok end
    {:noreply, flash(assign(socket, :sessions, []), "All sessions revoked", :success)}
  end

  def handle_event("toggle_edit", _, socket), do: {:noreply, assign(socket, :edit_profile, !socket.assigns.edit_profile)}

  def handle_event("save_profile", %{"nickname" => nick}, socket) do
    user = Map.put(socket.assigns.user, :nickname, nick)
    {:noreply, socket |> assign(:user, user) |> assign(:edit_profile, false) |> flash("Profile updated", :success)}
  end

  def handle_event("confirm_action", %{"action" => a, "label" => l}, socket) do
    {:noreply, assign(socket, :confirm_action, %{action: a, label: l})}
  end

  def handle_event("cancel_confirm", _, socket), do: {:noreply, assign(socket, :confirm_action, nil)}

  def handle_event("execute_confirm", _, socket) do
    {:noreply, socket |> assign(:confirm_action, nil) |> flash("Done", :success)}
  end

  def handle_event("dismiss_flash", _, socket), do: {:noreply, assign(socket, :flash_msg, nil)}

  defp flash(socket, msg, type), do: socket |> assign(:flash_msg, msg) |> assign(:flash_type, type)

  @impl true
  def render(assigns) do
    filtered = filter_files(assigns.files, assigns.files_search, assigns.files_filter)
    assigns = assign(assigns, :filtered_files, filtered)
    ~H"""
    <style>
      *{box-sizing:border-box;margin:0;padding:0}
      body{font-family:'Segoe UI',system-ui,sans-serif}
      .up{display:flex;height:100vh;background:#f8fafc}
      .sb{width:224px;min-width:224px;background:#fff;border-right:1px solid #e2e8f0;display:flex;flex-direction:column;overflow-y:auto;flex-shrink:0}
      .sbl{padding:18px 16px 12px;border-bottom:1px solid #e2e8f0}
      .sbl .br{font-size:14px;font-weight:800;color:#0f172a}
      .sbl .tg{font-size:10px;color:#94a3b8;margin-top:2px}
      .sbp{padding:12px 16px;border-bottom:1px solid #e2e8f0;display:flex;align-items:center;gap:9px}
      .av{width:34px;height:34px;border-radius:50%;background:linear-gradient(135deg,#2563eb,#7c3aed);display:flex;align-items:center;justify-content:center;font-size:13px;font-weight:700;color:#fff;flex-shrink:0}
      .un{font-size:13px;font-weight:600;color:#0f172a}
      .up2{font-size:11px;color:#94a3b8}
      .sbn{flex:1;padding:8px 0}
      .ns{padding:12px 16px 3px;font-size:10px;font-weight:700;color:#94a3b8;letter-spacing:1px;text-transform:uppercase}
      .ni{display:flex;align-items:center;gap:8px;padding:8px 16px;font-size:13px;color:#475569;cursor:pointer;border:none;background:none;width:100%;text-align:left;font-family:inherit;transition:.1s;border-right:2px solid transparent}
      .ni:hover{background:#f1f5f9;color:#0f172a}
      .ni.on{background:rgba(37,99,235,.07);color:#2563eb;font-weight:600;border-right-color:#2563eb}
      .ni .ic{width:17px;text-align:center;flex-shrink:0}
      .nb{margin-left:auto;background:#2563eb;color:#fff;font-size:10px;padding:1px 6px;border-radius:10px}
      .mn{flex:1;display:flex;flex-direction:column;min-width:0;overflow:hidden}
      .tp{background:#fff;border-bottom:1px solid #e2e8f0;height:50px;display:flex;align-items:center;padding:0 20px;gap:10px;flex-shrink:0}
      .tp .tt{font-size:14px;font-weight:700;color:#0f172a}
      .tp .sp{flex:1}
      .bd{flex:1;overflow-y:auto;padding:20px}
      .sg{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin-bottom:16px}
      .sc{background:#fff;border:1px solid #e2e8f0;border-radius:9px;padding:14px}
      .sc .sl{font-size:10px;color:#94a3b8;font-weight:700;text-transform:uppercase;letter-spacing:.5px;margin-bottom:5px}
      .sc .sv{font-size:19px;font-weight:800;color:#0f172a}
      .sc .ss{font-size:11px;color:#94a3b8;margin-top:2px}
      .pc{background:#fff;border:1px solid #e2e8f0;border-radius:9px;overflow:hidden;margin-bottom:13px}
      .ph{padding:12px 16px;border-bottom:1px solid #e2e8f0;display:flex;align-items:center;gap:7px}
      .ph .pt{font-size:13px;font-weight:700;color:#0f172a}
      .ph .pc2{font-size:11px;color:#94a3b8}
      .ph .sp{flex:1}
      .pb2{padding:16px}
      table{width:100%;border-collapse:collapse}
      th{padding:8px 13px;text-align:left;font-size:10px;font-weight:700;color:#94a3b8;text-transform:uppercase;letter-spacing:.5px;border-bottom:1px solid #e2e8f0;background:#f8fafc}
      td{padding:10px 13px;font-size:13px;color:#0f172a;border-bottom:1px solid #e2e8f0}
      tr:last-child td{border-bottom:none}
      tr:hover td{background:#f8fafc}
      .b{display:inline-block;padding:2px 7px;border-radius:20px;font-size:11px;font-weight:600}
      .bg2{background:#f1f5f9;color:#64748b}
      .bb{background:#eff6ff;color:#2563eb}
      .bgn{background:#ecfdf5;color:#059669}
      .by{background:#fffbeb;color:#d97706}
      .btn{display:inline-flex;align-items:center;gap:5px;padding:6px 13px;border-radius:6px;font-size:12px;font-weight:500;cursor:pointer;border:none;font-family:inherit;transition:.1s}
      .bp{background:#2563eb;color:#fff}.bp:hover{background:#1d4ed8}
      .bo{background:transparent;color:#475569;border:1px solid #cbd5e1}.bo:hover{background:#f1f5f9}
      .bd2{background:transparent;color:#dc2626;border:1px solid #fecaca}.bd2:hover{background:#fef2f2}
      .bsm{padding:4px 9px;font-size:11px}
      .fi{background:#f8fafc;border:1px solid #cbd5e1;border-radius:6px;padding:7px 10px;color:#0f172a;font-size:13px;font-family:inherit;width:100%}
      .fi:focus{outline:none;border-color:#2563eb}
      select.fi{cursor:pointer}
      .fl{font-size:12px;font-weight:600;color:#475569;margin-bottom:4px;display:block}
      .fg{margin-bottom:12px}
      .did-box{background:linear-gradient(135deg,#eff6ff,#f5f3ff);border:1px solid #c7d2fe;border-radius:9px;padding:16px;margin-bottom:13px}
      .did-val{font-family:monospace;font-size:12px;color:#2563eb;word-break:break-all;background:#fff;border:1px solid #e2e8f0;border-radius:6px;padding:9px;margin:7px 0}
      .prw{background:#f1f5f9;border-radius:999px;height:6px;overflow:hidden}
      .prf{height:100%;border-radius:999px}
      .sessc{display:flex;align-items:center;justify-content:space-between;padding:12px;border:1px solid #e2e8f0;border-radius:7px;margin-bottom:7px}
      .sessd{font-size:13px;font-weight:600;color:#0f172a}
      .sessm{font-size:11px;color:#94a3b8;margin-top:2px}
      .dz{border:1px solid #fecaca;border-radius:9px;padding:16px;background:#fff5f5}
      .dt{font-size:13px;font-weight:700;color:#dc2626;margin-bottom:11px}
      .di{display:flex;align-items:center;justify-content:space-between;padding:10px;background:#fff;border-radius:6px;border:1px solid #fecaca;margin-bottom:7px}
      .fls{position:fixed;top:16px;right:16px;z-index:9999;display:flex;align-items:center;gap:9px;padding:10px 15px;border-radius:8px;font-size:13px;font-weight:500;box-shadow:0 4px 20px rgba(0,0,0,.1);animation:slin .2s}
      .fls-s{background:#fff;color:#059669;border:1px solid #a7f3d0}
      .fls-e{background:#fff;color:#dc2626;border:1px solid #fecaca}
      @keyframes slin{from{transform:translateX(30px);opacity:0}to{transform:none;opacity:1}}
      .mbg{position:fixed;inset:0;background:rgba(15,23,42,.4);z-index:500;display:flex;align-items:center;justify-content:center}
      .md{background:#fff;border-radius:9px;padding:24px;width:360px;box-shadow:0 20px 60px rgba(0,0,0,.15)}
      .md h3{font-size:15px;font-weight:700;margin-bottom:7px}
      .md p{font-size:13px;color:#475569;margin-bottom:20px}
      .mda{display:flex;gap:8px;justify-content:flex-end}
      .emp{text-align:center;padding:40px 20px;color:#94a3b8}
      .ei{font-size:34px;margin-bottom:10px}
      .qa{display:flex;align-items:center;gap:12px;padding:11px;background:#f8fafc;border-radius:7px;margin-bottom:7px;border:1px solid #e2e8f0}
      .lr{display:flex;align-items:center;justify-content:space-between;padding:10px 12px;background:#f8fafc;border-radius:6px;margin-bottom:6px;border:1px solid #e2e8f0}
      .ln{font-family:monospace;font-size:13px;color:#2563eb}
      td.irl{color:#94a3b8;width:130px;font-size:12px}
    </style>

    <%= if @flash_msg do %>
      <div class={"fls fls-#{if @flash_type == :success, do: "s", else: "e"}"}>
        <%= if @flash_type == :success, do: "✓", else: "✕" %> <%= @flash_msg %>
        <button phx-click="dismiss_flash" style="background:none;border:none;color:inherit;cursor:pointer;font-size:16px;margin-left:6px">×</button>
      </div>
    <% end %>

    <%= if @confirm_action do %>
      <div class="mbg">
        <div class="md">
          <h3>Confirm</h3>
          <p><%= @confirm_action.label %></p>
          <div class="mda">
            <button class="btn bo" phx-click="cancel_confirm">Cancel</button>
            <button class="btn bd2" phx-click="execute_confirm">Confirm</button>
          </div>
        </div>
      </div>
    <% end %>

    <div class="up">
      <nav class="sb">
        <div class="sbl">
          <div class="br">⬡ PRZMA</div>
          <div class="tg">Sovereign File Platform</div>
        </div>
        <div class="sbp">
          <div class="av"><%= String.first(@user.nickname) |> String.upcase() %></div>
          <div>
            <div class="un"><%= @user.nickname %></div>
            <div class="up2">Free · 5 GB</div>
          </div>
        </div>
        <div class="sbn">
          <div class="ns">Overview</div>
          <button class={"ni #{if @page == :home, do: "on"}"} phx-click="nav" phx-value-page="home"><span class="ic">🏠</span> Home</button>
          <div class="ns">Files</div>
          <button class={"ni #{if @page == :files, do: "on"}"} phx-click="nav" phx-value-page="files">
            <span class="ic">📁</span> My Files
            <%= if @total_files > 0 do %><span class="nb"><%= @total_files %></span><% end %>
          </button>
          <button class={"ni #{if @page == :storage, do: "on"}"} phx-click="nav" phx-value-page="storage"><span class="ic">💾</span> Storage</button>
          <button class={"ni #{if @page == :lance, do: "on"}"} phx-click="nav" phx-value-page="lance"><span class="ic">🦀</span> LanceDB Vectors</button>
          <div class="ns">Account</div>
          <button class={"ni #{if @page == :identity, do: "on"}"} phx-click="nav" phx-value-page="identity"><span class="ic">🪪</span> Identity (DID)</button>
          <button class={"ni #{if @page == :sessions, do: "on"}"} phx-click="nav" phx-value-page="sessions"><span class="ic">🔐</span> Sessions</button>
          <button class={"ni #{if @page == :settings, do: "on"}"} phx-click="nav" phx-value-page="settings"><span class="ic">⚙️</span> Settings</button>
        </div>
      </nav>

      <div class="mn">
        <div class="tp">
          <span class="tt"><%= plbl(@page) %></span>
          <span class="sp"></span>
          <a href="/demo" class="btn bo bsm">🚀 Upload</a>
          <a href="/admin" class="btn bo bsm">⬡ Admin</a>
        </div>
        <div class="bd">
          <%= render_page(assigns) %>
        </div>
      </div>
    </div>
    """
  end

  defp plbl(:home), do: "Overview"
  defp plbl(:files), do: "My Files"
  defp plbl(:storage), do: "Storage"
  defp plbl(:lance), do: "LanceDB Vectors"
  defp plbl(:identity), do: "Identity (DID)"
  defp plbl(:sessions), do: "Sessions"
  defp plbl(:settings), do: "Settings"
  defp plbl(_), do: "Panel"

  defp render_page(%{page: :home} = assigns) do
    ~H"""
    <div class="sg">
      <div class="sc"><div class="sl">Files</div><div class="sv"><%= @total_files %></div><div class="ss">Uploaded</div></div>
      <div class="sc"><div class="sl">Storage</div><div class="sv">0 B</div><div class="ss">of 5 GB</div></div>
      <div class="sc"><div class="sl">Vectors</div><div class="sv"><%= @total_files %></div><div class="ss">446-dim HOLNN</div></div>
      <div class="sc"><div class="sl">Last Sync</div><div class="sv" style="font-size:12px"><%= fmt_last(@last_sync) %></div></div>
    </div>
    <div class="pc">
      <div class="ph"><span class="pt">Upload Files</span></div>
      <div class="pb2">
        <%= for {ico, lbl, desc} <- [{"🎵","Audio (MP3, WAV)","MFCC energy → 256 dims"},{"🖼️","Images (JPG, PNG)","Pixel intensity → 256 dims"},{"🎬","Video (MP4, MOV)","Frame sampling → 256 dims"},{"📄","Documents (PDF)","Byte histogram → 256 dims"}] do %>
          <div class="qa">
            <span style="font-size:20px"><%= ico %></span>
            <div style="flex:1"><div style="font-size:13px;font-weight:600"><%= lbl %></div><div style="font-size:11px;color:#94a3b8"><%= desc %></div></div>
            <a href="/demo" class="btn bp bsm">Upload</a>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp render_page(%{page: :files} = assigns) do
    ~H"""
    <div class="pc" style="margin-bottom:12px">
      <div class="pb2" style="padding:10px 13px">
        <div style="display:flex;gap:9px;align-items:center;flex-wrap:wrap">
          <form phx-submit="search_files" style="display:flex;gap:7px;flex:1;min-width:150px">
            <input class="fi" name="search" placeholder="Search files..." value={@files_search} style="flex:1"/>
            <button class="btn bp bsm" type="submit">Search</button>
          </form>
          <form phx-change="filter_files">
            <select class="fi" name="filter" style="width:auto">
              <option value="all" selected={@files_filter=="all"}>All Types</option>
              <option value="audio" selected={@files_filter=="audio"}>🎵 Audio</option>
              <option value="image" selected={@files_filter=="image"}>🖼 Images</option>
              <option value="video" selected={@files_filter=="video"}>🎬 Video</option>
              <option value="document" selected={@files_filter=="document"}>📄 Docs</option>
            </select>
          </form>
          <span style="font-size:11px;color:#94a3b8"><%= length(@filtered_files) %> files</span>
          <a href="/demo" class="btn bp bsm">+ Upload</a>
        </div>
      </div>
    </div>
    <%= if @filtered_files == [] do %>
      <div class="pc"><div class="emp"><div class="ei">📂</div><div style="margin-bottom:12px">No files yet</div><a href="/demo" class="btn bp">Upload First File</a></div></div>
    <% else %>
      <div class="pc">
        <table>
          <thead><tr><th>File</th><th>Type</th><th>Status</th><th>Uploaded</th></tr></thead>
          <tbody>
            <%= for f <- @filtered_files do %>
              <tr>
                <td><div style="display:flex;align-items:center;gap:8px"><span style="font-size:17px"><%= ficon(f.content_type) %></span><span style="font-weight:500"><%= f.filename %></span></div></td>
                <td><span class="b bg2"><%= ftype(f.content_type) %></span></td>
                <td><span class={"b #{sbadge(f.status)}"}><%= fstatus(f.status) %></span></td>
                <td style="color:#94a3b8;font-size:12px"><%= fdate(f.inserted_at) %></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    <% end %>
    """
  end

  defp render_page(%{page: :storage} = assigns) do
    ~H"""
    <div class="sg" style="grid-template-columns:repeat(3,1fr)">
      <div class="sc"><div class="sl">Files</div><div class="sv"><%= (@storage_stats && @storage_stats.total_files) || 0 %></div></div>
      <div class="sc"><div class="sl">Used</div><div class="sv">0 B</div><div class="ss">of 5 GB</div></div>
      <div class="sc"><div class="sl">Plan</div><div class="sv" style="font-size:13px">Free</div></div>
    </div>
    <div class="pc">
      <div class="ph"><span class="pt">Files by Type</span></div>
      <div class="pb2">
        <%= if @storage_stats && @storage_stats.by_type != %{} do %>
          <%= for {type, count} <- @storage_stats.by_type do %>
            <div style="display:flex;align-items:center;gap:10px;margin-bottom:9px">
              <span style="width:80px;font-size:12px;color:#475569"><%= ficon(type) %> <%= ftype(type) %></span>
              <div class="prw" style="flex:1"><div class="prf" style={"width:#{min(100,count*20)}%;background:#2563eb"}></div></div>
              <span style="font-size:12px;color:#94a3b8;width:20px"><%= count %></span>
            </div>
          <% end %>
        <% else %>
          <div class="emp" style="padding:20px"><div class="ei">📊</div><div>No files yet</div></div>
        <% end %>
      </div>
    </div>
    """
  end

  defp render_page(%{page: :lance} = assigns) do
    ~H"""
    <div class="sg" style="grid-template-columns:repeat(3,1fr)">
      <div class="sc"><div class="sl">Tables</div><div class="sv"><%= length(@lance_tables) %></div></div>
      <div class="sc"><div class="sl">Dimensions</div><div class="sv">446</div><div class="ss">HOLNN</div></div>
      <div class="sc"><div class="sl">NIF</div><div class="sv" style="font-size:12px;color:#059669">🦀 Loaded</div></div>
    </div>
    <div class="pc">
      <div class="ph"><span class="pt">Tables</span></div>
      <div class="pb2">
        <%= if @lance_tables == [] do %>
          <div class="emp" style="padding:20px"><div class="ei">🦀</div><div>Upload files to create vectors</div></div>
        <% else %>
          <%= for t <- @lance_tables do %>
            <div class="lr"><span class="ln">🦀 <%= t %></span><span class="b bgn">Active</span></div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  defp render_page(%{page: :identity} = assigns) do
    ~H"""
    <div class="did-box">
      <div style="font-size:14px;font-weight:700;margin-bottom:3px">Your Decentralized Identifier</div>
      <div style="font-size:12px;color:#475569;margin-bottom:7px">Your unique sovereign identity on PRZMA</div>
      <div class="did-val"><%= @user.did_id %></div>
      <button class="btn bo bsm" onclick={"navigator.clipboard.writeText('#{@user.did_id}').then(function(){alert('Copied!')})"}>📋 Copy</button>
    </div>
    <div class="pc">
      <div class="ph"><span class="pt">Details</span></div>
      <div class="pb2">
        <table><tbody>
          <tr><td class="irl">Method</td><td style="font-family:monospace">przma</td></tr>
          <tr><td class="irl">Fingerprint</td><td style="font-family:monospace"><%= String.slice(@user.did_id, -8, 8) %></td></tr>
          <tr><td class="irl">Namespace Key</td><td style="color:#94a3b8">Hidden — internal only</td></tr>
          <tr><td class="irl">Encryption</td><td style="color:#059669">✓ AES-256-GCM</td></tr>
          <tr><td class="irl">Epoch ID</td><td>228</td></tr>
        </tbody></table>
      </div>
    </div>
    """
  end

  defp render_page(%{page: :sessions} = assigns) do
    ~H"""
    <div class="pc">
      <div class="ph">
        <span class="pt">Sessions</span><span class="pc2"><%= length(@sessions) %></span>
        <span class="sp"></span>
        <%= if length(@sessions) > 1 do %>
          <button class="btn bd2 bsm" phx-click="confirm_action" phx-value-action="logout_all" phx-value-label="Log out all devices?">Revoke All</button>
        <% end %>
      </div>
      <div class="pb2">
        <%= if @sessions == [] do %>
          <div class="emp" style="padding:20px"><div class="ei">🔐</div><div>No active sessions</div></div>
        <% else %>
          <%= for s <- @sessions do %>
            <div class="sessc">
              <div>
                <div class="sessd"><%= devico(s[:device]) %> <%= devnm(s[:device]) %></div>
                <div class="sessm">Last: <%= ago(s[:last_active_at]) %> · Since: <%= fdate(s[:inserted_at]) %></div>
              </div>
              <button class="btn bd2 bsm" phx-click="revoke_session" phx-value-id={s.id}>Revoke</button>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  defp render_page(%{page: :settings} = assigns) do
    ~H"""
    <div class="pc">
      <div class="ph"><span class="pt">Profile</span><span class="sp"></span>
        <button class="btn bo bsm" phx-click="toggle_edit"><%= if @edit_profile, do: "Cancel", else: "Edit" %></button>
      </div>
      <div class="pb2">
        <%= if @edit_profile do %>
          <form phx-submit="save_profile">
            <div class="fg"><label class="fl">Nickname</label><input class="fi" name="nickname" value={@user.nickname}/></div>
            <button class="btn bp" type="submit">Save</button>
          </form>
        <% else %>
          <table><tbody>
            <tr><td class="irl">Nickname</td><td style="font-weight:600"><%= @user.nickname %></td></tr>
            <tr><td class="irl">Email</td><td><%= mask(@user.email) %></td></tr>
            <tr><td class="irl">Status</td><td><span class="b bgn">Active</span> <span class="b bb">Verified</span></td></tr>
          </tbody></table>
        <% end %>
      </div>
    </div>
    <div class="pc">
      <div class="ph"><span class="pt">Security</span></div>
      <div class="pb2" style="display:flex;flex-direction:column">
        <div style="display:flex;align-items:center;justify-content:space-between;padding:9px 0;border-bottom:1px solid #e2e8f0">
          <div style="font-size:13px;font-weight:600">Change Password</div>
          <button class="btn bo bsm">Change</button>
        </div>
        <div style="display:flex;align-items:center;justify-content:space-between;padding:9px 0">
          <div style="font-size:13px;font-weight:600">Log Out All Devices</div>
          <button class="btn bd2 bsm" phx-click="revoke_all_sessions">Log Out All</button>
        </div>
      </div>
    </div>
    <div class="dz">
      <div class="dt">⚠ Danger Zone</div>
      <div class="di">
        <div><div style="font-size:13px;font-weight:600">Disable Account</div><div style="font-size:11px;color:#64748b">Temporarily disable</div></div>
        <button class="btn bd2 bsm" phx-click="confirm_action" phx-value-action="disable" phx-value-label="Disable your account?">Disable</button>
      </div>
      <div class="di" style="margin-bottom:0">
        <div><div style="font-size:13px;font-weight:600;color:#dc2626">Delete Account</div><div style="font-size:11px;color:#64748b">Cannot be undone</div></div>
        <button class="btn bd2 bsm" phx-click="confirm_action" phx-value-action="delete" phx-value-label="PERMANENTLY delete your account?">Delete</button>
      </div>
    </div>
    """
  end

  defp render_page(assigns) do
    ~H"""
    <div class="pc"><div class="emp"><div class="ei">📌</div><div>Select from sidebar</div></div></div>
    """
  end

  defp filter_files(files, search, filter) do
    Enum.filter(files, fn f ->
      ms = search == "" or String.contains?(String.downcase(f.filename || ""), String.downcase(search))
      mt = case filter do
        "audio" -> String.starts_with?(f.content_type || "", "audio/")
        "image" -> String.starts_with?(f.content_type || "", "image/")
        "video" -> String.starts_with?(f.content_type || "", "video/")
        "document" -> String.contains?(f.content_type || "", "pdf") or String.contains?(f.content_type || "", "document")
        _ -> true
      end
      ms and mt
    end)
  end

  defp ficon(t) when is_binary(t) do
    cond do
      String.starts_with?(t, "audio/") -> "🎵"
      String.starts_with?(t, "video/") -> "🎬"
      String.starts_with?(t, "image/") -> "🖼️"
      String.contains?(t, "pdf") -> "📕"
      true -> "📄"
    end
  end
  defp ficon(_), do: "📄"

  defp ftype(t) when is_binary(t) do
    cond do
      String.starts_with?(t, "audio/") -> "Audio"
      String.starts_with?(t, "video/") -> "Video"
      String.starts_with?(t, "image/") -> "Image"
      String.contains?(t, "pdf") -> "PDF"
      String.contains?(t, "document") -> "Document"
      true -> t
    end
  end
  defp ftype(_), do: "File"

  defp fstatus("synced"), do: "Uploaded"
  defp fstatus("indexed"), do: "Ready"
  defp fstatus("processing"), do: "Syncing..."
  defp fstatus(s), do: s || "Unknown"

  defp sbadge("indexed"), do: "bgn"
  defp sbadge("synced"), do: "bb"
  defp sbadge("processing"), do: "by"
  defp sbadge(_), do: "bg2"

  defp devico(d) when is_binary(d) do
    cond do
      String.contains?(d, "mobile") -> "📱"
      String.contains?(d, "tablet") -> "📟"
      true -> "💻"
    end
  end
  defp devico(_), do: "💻"

  defp devnm(nil), do: "Desktop"
  defp devnm(d), do: String.capitalize(d)

  defp fdate(nil), do: "-"
  defp fdate(%NaiveDateTime{} = dt), do: NaiveDateTime.to_date(dt) |> Date.to_string()
  defp fdate(%DateTime{} = dt), do: DateTime.to_date(dt) |> Date.to_string()
  defp fdate(_), do: "-"

  defp ago(nil), do: "Never"
  defp ago(%NaiveDateTime{} = dt) do
    diff = NaiveDateTime.diff(NaiveDateTime.utc_now(), dt, :minute)
    cond do
      diff < 1 -> "Just now"
      diff < 60 -> "#{diff}m ago"
      diff < 1440 -> "#{div(diff, 60)}h ago"
      true -> "#{div(diff, 1440)}d ago"
    end
  end
  defp ago(%DateTime{} = dt), do: ago(DateTime.to_naive(dt))
  defp ago(_), do: "-"

  defp fmt_last(nil), do: "Never"
  defp fmt_last(dt), do: fdate(dt)

  defp mask(nil), do: "-"
  defp mask(email) do
    [u, d] = String.split(email, "@", parts: 2)
    String.first(u) <> String.duplicate("*", max(0, String.length(u) - 1)) <> "@" <> d
  end
end