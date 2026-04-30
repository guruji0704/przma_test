defmodule AlemWeb.UserLive do
  use AlemWeb, :live_view
  import Ecto.Query
  alias Alem.Schemas.Document
  alias Alem.Repo
  require Logger

  @impl true
  def mount(_params, session, socket) do
    user = case session["user_id"] do
      nil -> nil
      uid ->
        try do Alem.Repo.get(Alem.Pleroma.User, uid)
        rescue _ -> nil end
    end

    if is_nil(user) do
      {:ok, redirect(socket, to: "/panel/login")}
    else
      uid = user.id
      stats = load_stats(uid)
      {:ok,
       socket
       |> assign(:page_title,     "My Panel")
       |> assign(:user,           user)
       |> assign(:page,           :home)
       |> assign(:stats,          stats)
       |> assign(:files,          [])
       |> assign(:files_filter,   "all")
       |> assign(:files_search,   "")
       |> assign(:sessions,       [])
       |> assign(:flash_msg,      nil)
       |> assign(:flash_type,     :success)
       |> assign(:confirm_action, nil)
       |> assign(:edit_profile,   false)}
    end
  end

  defp load_stats(uid) do
    try do
      total = Repo.aggregate(from(d in Document, where: d.user_id == ^uid), :count, :id)

      by_type = Repo.all(
        from d in Document,
        where: d.user_id == ^uid,
        group_by: d.content_type,
        select: {d.content_type, count(d.id)}
      ) |> Enum.into(%{})

      by_month = Repo.all(
        from d in Document,
        where: d.user_id == ^uid,
        group_by: fragment("DATE_TRUNC('month', ?)", d.inserted_at),
        order_by: fragment("DATE_TRUNC('month', ?)", d.inserted_at),
        select: {fragment("DATE_TRUNC('month', ?)", d.inserted_at), count(d.id)},
        limit: 6
      )

      last_sync = Repo.one(
        from d in Document,
        where: d.user_id == ^uid,
        order_by: [desc: d.inserted_at],
        limit: 1,
        select: d.inserted_at
      )

      %{
        total:     total,
        by_type:   by_type,
        by_month:  by_month,
        last_sync: last_sync,
        audio:     count_type(by_type, "audio/"),
        video:     count_type(by_type, "video/"),
        image:     count_type(by_type, "image/"),
        document:  count_doc(by_type)
      }
    rescue
      _ -> %{total: 0, by_type: %{}, by_month: [], last_sync: nil, audio: 0, video: 0, image: 0, document: 0}
    end
  end

  defp count_type(by_type, prefix) do
    by_type |> Enum.filter(fn {k, _} -> String.starts_with?(k || "", prefix) end)
            |> Enum.reduce(0, fn {_, v}, acc -> acc + v end)
  end

  defp count_doc(by_type) do
    by_type |> Enum.filter(fn {k, _} ->
      String.contains?(k || "", "pdf") or String.contains?(k || "", "document") or
      String.contains?(k || "", "text") or String.contains?(k || "", "word")
    end) |> Enum.reduce(0, fn {_, v}, acc -> acc + v end)
  end

  # ── Navigation ─────────────────────────────────────────────────────────────

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
      Repo.all(
        from d in Document,
        where: d.user_id == ^uid,
        order_by: [desc: d.inserted_at],
        limit: 200,
        select: %{id: d.id, filename: d.filename, content_type: d.content_type,
                  status: d.status, inserted_at: d.inserted_at}
      )
    rescue _ -> [] end
    assign(socket, :files, files)
  end

  defp load_page(socket, :sessions) do
    uid = socket.assigns.user.id
    sessions = try do
      Repo.all(
        from s in Alem.Session,
        where: s.user_id == ^uid and is_nil(s.revoked_at),
        order_by: [desc: s.last_active_at],
        limit: 20,
        select: %{id: s.id, device: s.device, last_active_at: s.last_active_at, inserted_at: s.inserted_at}
      )
    rescue _ -> [] end
    assign(socket, :sessions, sessions)
  end

  defp load_page(socket, _), do: socket

  # ── Events ─────────────────────────────────────────────────────────────────

  def handle_event("filter_files", %{"filter" => f}, socket) do
    {:noreply, assign(socket, :files_filter, f)}
  end

  def handle_event("search_files", %{"search" => q}, socket) do
    {:noreply, assign(socket, :files_search, q)}
  end

  def handle_event("revoke_session", %{"id" => id}, socket) do
    try do
      Repo.get(Alem.Session, id)
      |> Ecto.Changeset.change(%{revoked_at: DateTime.utc_now()})
      |> Repo.update()
    rescue _ -> :ok end
    socket = load_page(assign(socket, :page, :sessions), :sessions)
    {:noreply, flash(socket, "Session revoked", :success)}
  end

  def handle_event("toggle_edit", _, socket) do
    {:noreply, assign(socket, :edit_profile, !socket.assigns.edit_profile)}
  end

  def handle_event("save_profile", %{"nickname" => nick}, socket) do
    user = Map.put(socket.assigns.user, :nickname, nick)
    {:noreply, socket |> assign(:user, user) |> assign(:edit_profile, false) |> flash("Profile updated", :success)}
  end

  def handle_event("confirm_action", %{"action" => a, "label" => l}, socket) do
    {:noreply, assign(socket, :confirm_action, %{action: a, label: l})}
  end

  def handle_event("cancel_confirm", _, socket) do
    {:noreply, assign(socket, :confirm_action, nil)}
  end

  def handle_event("execute_confirm", _, socket) do
    {:noreply, socket |> assign(:confirm_action, nil) |> flash("Action completed", :success)}
  end

  def handle_event("logout", _, socket) do
    {:noreply, redirect(socket, to: "/panel/logout")}
  end

  def handle_event("dismiss_flash", _, socket) do
    {:noreply, assign(socket, :flash_msg, nil)}
  end

  defp flash(socket, msg, type) do
    socket |> assign(:flash_msg, msg) |> assign(:flash_type, type)
  end

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    files   = assigns.files
    filter  = assigns.files_filter
    search  = assigns.files_search
    filtered = Enum.filter(files, fn f ->
      ms = search == "" or String.contains?(String.downcase(f.filename || ""), String.downcase(search))
      mt = case filter do
        "audio"    -> String.starts_with?(f.content_type || "", "audio/")
        "image"    -> String.starts_with?(f.content_type || "", "image/")
        "video"    -> String.starts_with?(f.content_type || "", "video/")
        "document" -> String.contains?(f.content_type || "", "pdf") or
                      String.contains?(f.content_type || "", "document") or
                      String.contains?(f.content_type || "", "text") or
                      String.contains?(f.content_type || "", "word")
        _ -> true
      end
      ms and mt
    end)
    assigns = assign(assigns, :filtered, filtered)

    # Build chart data
    type_data = [
      assigns.stats.audio,
      assigns.stats.video,
      assigns.stats.image,
      assigns.stats.document
    ]
    month_labels = assigns.stats.by_month |> Enum.map(fn {dt, _} ->
      case dt do
        %NaiveDateTime{} -> Calendar.strftime(dt, "%b %Y")
        %DateTime{} -> Calendar.strftime(dt, "%b %Y")
        _ -> "?"
      end
    end)
    month_values = assigns.stats.by_month |> Enum.map(fn {_, c} -> c end)
    assigns = assigns
      |> assign(:chart_type_data,   Jason.encode!(type_data))
      |> assign(:chart_month_labels, Jason.encode!(month_labels))
      |> assign(:chart_month_values, Jason.encode!(month_values))

    ~H"""
    <style>
      *{box-sizing:border-box;margin:0;padding:0}
      body{font-family:'Segoe UI',system-ui,sans-serif;background:#f1f5f9}
      .shell{display:flex;height:100vh}
      /* Sidebar */
      .sb{width:210px;min-width:210px;background:#0f172a;display:flex;flex-direction:column;overflow-y:auto;flex-shrink:0}
      .sb-logo{padding:20px 16px 14px;border-bottom:1px solid rgba(255,255,255,.07)}
      .sb-logo .brand{font-size:14px;font-weight:800;color:#fff;letter-spacing:-.2px}
      .sb-logo .tag{font-size:10px;color:#475569;margin-top:2px}
      .sb-prof{padding:12px 16px;border-bottom:1px solid rgba(255,255,255,.07);display:flex;align-items:center;gap:9px}
      .av{width:32px;height:32px;border-radius:50%;background:linear-gradient(135deg,#2563eb,#7c3aed);display:flex;align-items:center;justify-content:center;font-size:12px;font-weight:700;color:#fff;flex-shrink:0}
      .uname{font-size:12px;font-weight:600;color:#e2e8f0}
      .umail{font-size:10px;color:#475569;margin-top:1px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:130px}
      .sb-nav{flex:1;padding:8px 0}
      .ns{padding:12px 16px 3px;font-size:9px;font-weight:700;color:#334155;letter-spacing:1.2px;text-transform:uppercase}
      .ni{display:flex;align-items:center;gap:8px;padding:7px 16px;font-size:12px;color:#64748b;cursor:pointer;border:none;background:none;width:100%;text-align:left;font-family:inherit;transition:.1s;border-left:2px solid transparent}
      .ni:hover{background:rgba(255,255,255,.04);color:#cbd5e1}
      .ni.on{background:rgba(37,99,235,.15);color:#60a5fa;border-left-color:#3b82f6}
      .ni .ic{width:15px;text-align:center;flex-shrink:0;font-size:13px}
      .nb{margin-left:auto;background:#1e40af;color:#93c5fd;font-size:9px;padding:1px 5px;border-radius:8px}
      .sb-foot{padding:10px 0;border-top:1px solid rgba(255,255,255,.07)}
      .ni-out{display:flex;align-items:center;gap:8px;padding:7px 16px;font-size:12px;color:#ef4444;cursor:pointer;border:none;background:none;width:100%;text-align:left;font-family:inherit;transition:.1s}
      .ni-out:hover{background:rgba(239,68,68,.08)}
      /* Main */
      .main{flex:1;display:flex;flex-direction:column;overflow:hidden}
      .topbar{background:#fff;border-bottom:1px solid #e2e8f0;height:48px;display:flex;align-items:center;padding:0 20px;gap:10px;flex-shrink:0}
      .topbar .tt{font-size:14px;font-weight:700;color:#0f172a}
      .topbar .sp{flex:1}
      .body{flex:1;overflow-y:auto;padding:20px;display:flex;flex-direction:column;gap:16px}
      /* Stat row */
      .srow{display:grid;grid-template-columns:repeat(4,1fr);gap:12px}
      .sc{background:#fff;border:1px solid #e2e8f0;border-radius:10px;padding:14px 16px;display:flex;align-items:center;gap:12px}
      .sc-ico{width:38px;height:38px;border-radius:9px;display:flex;align-items:center;justify-content:center;font-size:18px;flex-shrink:0}
      .sc-ico.blue{background:#eff6ff}
      .sc-ico.green{background:#ecfdf5}
      .sc-ico.purple{background:#faf5ff}
      .sc-ico.orange{background:#fff7ed}
      .sc-ico.red{background:#fef2f2}
      .sc .sl{font-size:11px;color:#94a3b8;margin-bottom:3px}
      .sc .sv{font-size:18px;font-weight:800;color:#0f172a}
      /* Charts row */
      .crow{display:grid;grid-template-columns:1fr 2fr;gap:12px}
      .chart-card{background:#fff;border:1px solid #e2e8f0;border-radius:10px;padding:16px}
      .chart-title{font-size:13px;font-weight:700;color:#0f172a;margin-bottom:14px}
      /* Panel card */
      .pc{background:#fff;border:1px solid #e2e8f0;border-radius:10px;overflow:hidden}
      .ph{padding:12px 16px;border-bottom:1px solid #e2e8f0;display:flex;align-items:center;gap:8px}
      .ph .pt{font-size:13px;font-weight:700;color:#0f172a}
      .ph .pct{font-size:11px;color:#94a3b8}
      .ph .sp{flex:1}
      .pb{padding:16px}
      /* Upload area */
      .upl-area{border:2px dashed #e2e8f0;border-radius:10px;padding:28px;text-align:center;transition:.15s}
      .upl-area:hover{border-color:#2563eb;background:#eff6ff}
      .upl-types{display:grid;grid-template-columns:repeat(4,1fr);gap:10px}
      .upl-type{display:flex;flex-direction:column;align-items:center;gap:6px;padding:14px 10px;background:#f8fafc;border:1px solid #e2e8f0;border-radius:9px;cursor:pointer;transition:.12s;text-decoration:none}
      .upl-type:hover{background:#eff6ff;border-color:#93c5fd}
      .upl-type .ti{font-size:24px}
      .upl-type .tn{font-size:12px;font-weight:600;color:#0f172a}
      .upl-type .td{font-size:10px;color:#94a3b8}
      /* File filter */
      .filter-row{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
      .ftab{padding:5px 12px;border-radius:20px;font-size:12px;font-weight:500;cursor:pointer;border:1px solid #e2e8f0;background:#fff;color:#475569;transition:.1s;font-family:inherit}
      .ftab:hover{background:#f1f5f9}
      .ftab.on{background:#2563eb;color:#fff;border-color:#2563eb}
      /* Table */
      table{width:100%;border-collapse:collapse}
      th{padding:8px 14px;text-align:left;font-size:10px;font-weight:700;color:#94a3b8;text-transform:uppercase;letter-spacing:.5px;border-bottom:1px solid #e2e8f0;background:#f8fafc}
      td{padding:10px 14px;font-size:13px;color:#0f172a;border-bottom:1px solid #f1f5f9}
      tr:last-child td{border-bottom:none}
      tr:hover td{background:#f8fafc}
      .b{display:inline-block;padding:2px 8px;border-radius:20px;font-size:11px;font-weight:600}
      .bg2{background:#f1f5f9;color:#64748b}
      .bb{background:#eff6ff;color:#2563eb}
      .bgn{background:#ecfdf5;color:#059669}
      .by{background:#fffbeb;color:#d97706}
      /* Buttons */
      .btn{display:inline-flex;align-items:center;gap:5px;padding:6px 14px;border-radius:7px;font-size:12px;font-weight:600;cursor:pointer;border:none;font-family:inherit;transition:.1s}
      .bp{background:#2563eb;color:#fff}.bp:hover{background:#1d4ed8}
      .bo{background:transparent;color:#475569;border:1px solid #e2e8f0}.bo:hover{background:#f1f5f9}
      .bd2{background:transparent;color:#dc2626;border:1px solid #fecaca}.bd2:hover{background:#fef2f2}
      .bsm{padding:4px 10px;font-size:11px}
      /* Form */
      .fi{background:#f8fafc;border:1px solid #e2e8f0;border-radius:7px;padding:7px 10px;color:#0f172a;font-size:13px;font-family:inherit;width:100%}
      .fi:focus{outline:none;border-color:#2563eb}
      select.fi{cursor:pointer}
      .fl{font-size:12px;font-weight:600;color:#475569;margin-bottom:4px;display:block}
      .fg{margin-bottom:12px}
      /* Sessions */
      .sess{display:flex;align-items:center;justify-content:space-between;padding:11px;border:1px solid #e2e8f0;border-radius:7px;margin-bottom:7px}
      .sessd{font-size:13px;font-weight:600;color:#0f172a}
      .sessm{font-size:11px;color:#94a3b8;margin-top:2px}
      /* DID */
      .did-box{background:linear-gradient(135deg,#eff6ff,#f5f3ff);border:1px solid #c7d2fe;border-radius:10px;padding:16px;margin-bottom:14px}
      .did-val{font-family:monospace;font-size:11px;color:#2563eb;word-break:break-all;background:#fff;border:1px solid #e2e8f0;border-radius:6px;padding:9px;margin:7px 0}
      /* Danger */
      .dz{border:1px solid #fecaca;border-radius:10px;padding:16px;background:#fff5f5}
      .dt{font-size:13px;font-weight:700;color:#dc2626;margin-bottom:11px}
      .di{display:flex;align-items:center;justify-content:space-between;padding:10px;background:#fff;border-radius:7px;border:1px solid #fecaca;margin-bottom:7px}
      /* Flash */
      .fls{position:fixed;top:16px;right:16px;z-index:9999;display:flex;align-items:center;gap:9px;padding:10px 16px;border-radius:8px;font-size:13px;font-weight:500;box-shadow:0 4px 20px rgba(0,0,0,.1);animation:slin .2s}
      .fls-s{background:#fff;color:#059669;border:1px solid #a7f3d0}
      .fls-e{background:#fff;color:#dc2626;border:1px solid #fecaca}
      @keyframes slin{from{transform:translateX(30px);opacity:0}to{transform:none;opacity:1}}
      /* Modal */
      .mbg{position:fixed;inset:0;background:rgba(15,23,42,.4);z-index:500;display:flex;align-items:center;justify-content:center}
      .md{background:#fff;border-radius:10px;padding:24px;width:360px;box-shadow:0 20px 60px rgba(0,0,0,.15)}
      .md h3{font-size:15px;font-weight:700;margin-bottom:7px}
      .md p{font-size:13px;color:#475569;margin-bottom:20px}
      .mda{display:flex;gap:8px;justify-content:flex-end}
      /* Empty */
      .emp{text-align:center;padding:40px;color:#94a3b8}
      .emp .ei{font-size:36px;margin-bottom:10px}
      /* Info table */
      td.irl{color:#94a3b8;width:130px;font-size:12px;font-weight:500}
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

    <div class="shell">
      <!-- Sidebar -->
      <nav class="sb">
        <div class="sb-logo">
          <div class="brand">⬡ PRZMA</div>
          <div class="tag">Sovereign File Platform</div>
        </div>
        <div class="sb-prof">
          <div class="av"><%= String.first(@user.nickname || "U") |> String.upcase() %></div>
          <div style="overflow:hidden">
            <div class="uname"><%= @user.nickname %></div>
            <div class="umail"><%= @user.email %></div>
          </div>
        </div>
        <div class="sb-nav">
          <div class="ns">Main</div>
          <button class={"ni #{if @page == :home, do: "on"}"} phx-click="nav" phx-value-page="home"><span class="ic">📊</span> Dashboard</button>
          <button class={"ni #{if @page == :files, do: "on"}"} phx-click="nav" phx-value-page="files">
            <span class="ic">📁</span> My Files
            <%= if @stats.total > 0 do %><span class="nb"><%= @stats.total %></span><% end %>
          </button>
          <button class={"ni #{if @page == :upload, do: "on"}"} phx-click="nav" phx-value-page="upload"><span class="ic">⬆️</span> Upload</button>
          <div class="ns">Account</div>
          <button class={"ni #{if @page == :identity, do: "on"}"} phx-click="nav" phx-value-page="identity"><span class="ic">🪪</span> Identity</button>
          <button class={"ni #{if @page == :sessions, do: "on"}"} phx-click="nav" phx-value-page="sessions"><span class="ic">🔐</span> Sessions</button>
          <button class={"ni #{if @page == :settings, do: "on"}"} phx-click="nav" phx-value-page="settings"><span class="ic">⚙️</span> Settings</button>
        </div>
        <div class="sb-foot">
          <button class="ni-out" phx-click="logout"><span class="ic">🚪</span> Sign Out</button>
        </div>
      </nav>

      <!-- Main -->
      <div class="main">
        <div class="topbar">
          <span class="tt"><%= plbl(@page) %></span>
          <span class="sp"></span>
          <span style="font-size:11px;color:#94a3b8">Welcome, <%= @user.nickname %></span>
          <%= if @user.is_admin do %>
            <a href="/admin" class="btn bo bsm">⬡ Admin Panel</a>
          <% end %>
        </div>

        <div class="body">
          <%= render_page(assigns) %>
        </div>
      </div>
    </div>

    <script>
      window.addEventListener("phx:update", () => { renderCharts(); });
      window.addEventListener("phx:mounted", () => { renderCharts(); });
      document.addEventListener("DOMContentLoaded", () => { renderCharts(); });

      function renderCharts() {
        renderDonut();
        renderBar();
      }

      function renderDonut() {
        var el = document.getElementById("chart-types");
        if (!el || !window.Chart) return;
        if (el._chart) { el._chart.destroy(); }
        var data = JSON.parse(el.dataset.values || "[0,0,0,0]");
        el._chart = new Chart(el, {
          type: "doughnut",
          data: {
            labels: ["Audio", "Video", "Images", "Documents"],
            datasets: [{
              data: data,
              backgroundColor: ["#3b82f6","#8b5cf6","#10b981","#f59e0b"],
              borderWidth: 0
            }]
          },
          options: {
            responsive: true,
            maintainAspectRatio: false,
            plugins: {
              legend: { position: "bottom", labels: { font: { size: 11 }, padding: 10 } }
            },
            cutout: "65%"
          }
        });
      }

      function renderBar() {
        var el = document.getElementById("chart-monthly");
        if (!el || !window.Chart) return;
        if (el._chart) { el._chart.destroy(); }
        var labels = JSON.parse(el.dataset.labels || "[]");
        var values = JSON.parse(el.dataset.values || "[]");
        el._chart = new Chart(el, {
          type: "bar",
          data: {
            labels: labels,
            datasets: [{
              label: "Uploads",
              data: values,
              backgroundColor: "#3b82f6",
              borderRadius: 6,
              borderSkipped: false
            }]
          },
          options: {
            responsive: true,
            maintainAspectRatio: false,
            plugins: { legend: { display: false } },
            scales: {
              y: { beginAtZero: true, ticks: { stepSize: 1, font: { size: 11 } }, grid: { color: "#f1f5f9" } },
              x: { ticks: { font: { size: 11 } }, grid: { display: false } }
            }
          }
        });
      }
    </script>
    """
  end

  defp plbl(:home),     do: "Dashboard"
  defp plbl(:files),    do: "My Files"
  defp plbl(:upload),   do: "Upload Files"
  defp plbl(:identity), do: "Identity (DID)"
  defp plbl(:sessions), do: "Active Sessions"
  defp plbl(:settings), do: "Account Settings"
  defp plbl(_),         do: "Panel"

  # ── Pages ──────────────────────────────────────────────────────────────────

  defp render_page(%{page: :home} = assigns) do
    ~H"""
    <!-- Stats -->
    <div class="srow">
      <div class="sc">
        <div class="sc-ico blue">📄</div>
        <div><div class="sl">Total Files</div><div class="sv"><%= @stats.total %></div></div>
      </div>
      <div class="sc">
        <div class="sc-ico green">🎵</div>
        <div><div class="sl">Audio</div><div class="sv"><%= @stats.audio %></div></div>
      </div>
      <div class="sc">
        <div class="sc-ico purple">🖼️</div>
        <div><div class="sl">Images</div><div class="sv"><%= @stats.image %></div></div>
      </div>
      <div class="sc">
        <div class="sc-ico orange">📕</div>
        <div><div class="sl">Documents</div><div class="sv"><%= @stats.document %></div></div>
      </div>
    </div>

    <!-- Charts -->
    <div class="crow">
      <div class="chart-card">
        <div class="chart-title">Files by Type</div>
        <div style="height:200px;position:relative">
          <canvas id="chart-types"
            data-values={@chart_type_data}>
          </canvas>
        </div>
      </div>
      <div class="chart-card">
        <div class="chart-title">Monthly Uploads</div>
        <div style="height:200px;position:relative">
          <canvas id="chart-monthly"
            data-labels={@chart_month_labels}
            data-values={@chart_month_values}>
          </canvas>
        </div>
      </div>
    </div>

    <!-- Recent Files -->
    <div class="pc">
      <div class="ph">
        <span class="pt">Recent Files</span>
        <span class="sp"></span>
        <button class="btn bo bsm" phx-click="nav" phx-value-page="files">View All</button>
      </div>
      <%= if @stats.total == 0 do %>
        <div class="emp">
          <div class="ei">📂</div>
          <div style="margin-bottom:10px">No files yet</div>
          <button class="btn bp" phx-click="nav" phx-value-page="upload">Upload Your First File</button>
        </div>
      <% else %>
        <table>
          <thead><tr><th>File</th><th>Type</th><th>Status</th><th>Date</th></tr></thead>
          <tbody>
            <%= for f <- Enum.take(@filtered, 5) do %>
              <tr>
                <td><div style="display:flex;align-items:center;gap:8px"><span style="font-size:16px"><%= ficon(f.content_type) %></span><span style="font-weight:500"><%= f.filename %></span></div></td>
                <td><span class="b bg2"><%= ftype(f.content_type) %></span></td>
                <td><span class={"b #{sbadge(f.status)}"}><%= fstatus(f.status) %></span></td>
                <td style="color:#94a3b8;font-size:11px"><%= fdate(f.inserted_at) %></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% end %>
    </div>
    """
  end

  defp render_page(%{page: :files} = assigns) do
    ~H"""
    <!-- Filter tabs -->
    <div class="pc">
      <div class="ph">
        <div class="filter-row">
          <button class={"ftab #{if @files_filter == "all", do: "on"}"} phx-click="filter_files" phx-value-filter="all">All (<%= @stats.total %>)</button>
          <button class={"ftab #{if @files_filter == "audio", do: "on"}"} phx-click="filter_files" phx-value-filter="audio">🎵 Audio (<%= @stats.audio %>)</button>
          <button class={"ftab #{if @files_filter == "video", do: "on"}"} phx-click="filter_files" phx-value-filter="video">🎬 Video (<%= @stats.video %>)</button>
          <button class={"ftab #{if @files_filter == "image", do: "on"}"} phx-click="filter_files" phx-value-filter="image">🖼️ Images (<%= @stats.image %>)</button>
          <button class={"ftab #{if @files_filter == "document", do: "on"}"} phx-click="filter_files" phx-value-filter="document">📄 Documents (<%= @stats.document %>)</button>
        </div>
        <span class="sp"></span>
        <form phx-submit="search_files" style="display:flex;gap:6px">
          <input class="fi" name="search" placeholder="Search..." value={@files_search} style="width:160px"/>
          <button class="btn bp bsm" type="submit">Search</button>
        </form>
        <a href="/demo" class="btn bp bsm">+ Upload</a>
      </div>
      <%= if @filtered == [] do %>
        <div class="emp">
          <div class="ei">🔍</div>
          <div>No files found</div>
        </div>
      <% else %>
        <table>
          <thead><tr><th>File</th><th>Type</th><th>Status</th><th>Uploaded</th></tr></thead>
          <tbody>
            <%= for f <- @filtered do %>
              <tr>
                <td><div style="display:flex;align-items:center;gap:9px"><span style="font-size:18px"><%= ficon(f.content_type) %></span><span style="font-weight:500"><%= f.filename %></span></div></td>
                <td><span class="b bg2"><%= ftype(f.content_type) %></span></td>
                <td><span class={"b #{sbadge(f.status)}"}><%= fstatus(f.status) %></span></td>
                <td style="color:#94a3b8;font-size:12px"><%= fdate(f.inserted_at) %></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% end %>
    </div>
    """
  end

  defp render_page(%{page: :upload} = assigns) do
    ~H"""
    <div class="pc">
      <div class="ph"><span class="pt">Upload Files</span></div>
      <div class="pb">
        <p style="font-size:13px;color:#475569;margin-bottom:16px">
          Choose a file type to upload. Each file is stored in S3, indexed in PostgreSQL, and generates a 446-dimensional HOLNN perception vector in LanceDB.
        </p>
        <div class="upl-types">
          <a href="/demo" class="upl-type">
            <span class="ti">🎵</span>
            <span class="tn">Audio</span>
            <span class="td">MP3, WAV, FLAC</span>
          </a>
          <a href="/demo" class="upl-type">
            <span class="ti">🎬</span>
            <span class="tn">Video</span>
            <span class="td">MP4, MOV, AVI</span>
          </a>
          <a href="/demo" class="upl-type">
            <span class="ti">🖼️</span>
            <span class="tn">Images</span>
            <span class="td">JPG, PNG, GIF</span>
          </a>
          <a href="/demo" class="upl-type">
            <span class="ti">📄</span>
            <span class="tn">Documents</span>
            <span class="td">PDF, DOCX, TXT</span>
          </a>
        </div>
        <div style="margin-top:16px;padding:14px;background:#f8fafc;border-radius:9px;border:1px solid #e2e8f0">
          <div style="font-size:12px;font-weight:600;color:#475569;margin-bottom:8px">What happens when you upload:</div>
          <div style="display:flex;flex-direction:column;gap:6px;font-size:12px;color:#64748b">
            <div>☁️ File encrypted and stored in Linode S3 (perkeep bucket)</div>
            <div>🗄️ Metadata saved to PostgreSQL (documents table)</div>
            <div>🦀 446-dim HOLNN vector written to LanceDB via Rust NIF</div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp render_page(%{page: :identity} = assigns) do
    ~H"""
    <div class="did-box">
      <div style="font-size:13px;font-weight:700;margin-bottom:3px">Your Decentralized Identifier</div>
      <div style="font-size:11px;color:#475569;margin-bottom:7px">Your unique sovereign identity — safe to share publicly</div>
      <div class="did-val"><%= @user.did_id || "Not assigned" %></div>
      <%= if @user.did_id do %>
        <button class="btn bo bsm" onclick={"navigator.clipboard.writeText('#{@user.did_id}').then(function(){alert('DID copied!')})"}>📋 Copy DID</button>
      <% end %>
    </div>
    <div class="pc">
      <div class="ph"><span class="pt">Identity Details</span></div>
      <div class="pb">
        <table><tbody>
          <tr><td class="irl">DID Method</td><td style="font-family:monospace;font-size:12px">przma</td></tr>
          <tr><td class="irl">Fingerprint</td><td style="font-family:monospace;font-size:12px"><%= if @user.did_id, do: String.slice(@user.did_id, -8, 8), else: "-" %></td></tr>
          <tr><td class="irl">Namespace Key</td><td style="color:#94a3b8;font-size:12px">Hidden — internal routing only</td></tr>
          <tr><td class="irl">Vault Encryption</td><td style="color:#059669;font-size:12px">✓ AES-256-GCM</td></tr>
          <tr><td class="irl">Epoch Key ID</td><td style="font-size:12px">228</td></tr>
          <tr><td class="irl">Verified</td><td><span class={"b #{if @user.is_verified, do: "bgn", else: "by"}"}><%= if @user.is_verified, do: "Verified", else: "Unverified" %></span></td></tr>
        </tbody></table>
      </div>
    </div>
    """
  end

  defp render_page(%{page: :sessions} = assigns) do
    ~H"""
    <div class="pc">
      <div class="ph">
        <span class="pt">Active Sessions</span>
        <span class="pct"><%= length(@sessions) %></span>
      </div>
      <div class="pb">
        <%= if @sessions == [] do %>
          <div class="emp" style="padding:24px"><div class="ei">🔐</div><div>No active sessions</div></div>
        <% else %>
          <%= for s <- @sessions do %>
            <div class="sess">
              <div>
                <div class="sessd"><%= devico(s[:device]) %> <%= devnm(s[:device]) %></div>
                <div class="sessm">Last active: <%= ago(s[:last_active_at]) %> · Since: <%= fdate(s[:inserted_at]) %></div>
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
    <div class="pc" style="margin-bottom:13px">
      <div class="ph">
        <span class="pt">Profile</span>
        <span class="sp"></span>
        <button class="btn bo bsm" phx-click="toggle_edit"><%= if @edit_profile, do: "Cancel", else: "Edit" %></button>
      </div>
      <div class="pb">
        <%= if @edit_profile do %>
          <form phx-submit="save_profile">
            <div class="fg"><label class="fl">Nickname</label><input class="fi" name="nickname" value={@user.nickname}/></div>
            <button class="btn bp" type="submit">Save</button>
          </form>
        <% else %>
          <table><tbody>
            <tr><td class="irl">Nickname</td><td style="font-weight:600;font-size:13px"><%= @user.nickname %></td></tr>
            <tr><td class="irl">Email</td><td style="font-size:13px"><%= mask(@user.email) %></td></tr>
            <tr><td class="irl">Status</td><td><span class="b bgn">Active</span> <%= if @user.is_verified do %><span class="b bb" style="margin-left:4px">Verified</span><% end %></td></tr>
          </tbody></table>
        <% end %>
      </div>
    </div>
    <div class="dz">
      <div class="dt">⚠ Danger Zone</div>
      <div class="di">
        <div><div style="font-size:13px;font-weight:600">Disable Account</div><div style="font-size:11px;color:#64748b">Temporarily disable your account</div></div>
        <button class="btn bd2 bsm" phx-click="confirm_action" phx-value-action="disable" phx-value-label="Disable your account?">Disable</button>
      </div>
      <div class="di" style="margin-bottom:0">
        <div><div style="font-size:13px;font-weight:600;color:#dc2626">Delete Account</div><div style="font-size:11px;color:#64748b">Permanently delete all data</div></div>
        <button class="btn bd2 bsm" phx-click="confirm_action" phx-value-action="delete" phx-value-label="PERMANENTLY delete your account and all files?">Delete</button>
      </div>
    </div>
    """
  end

  defp render_page(assigns) do
    ~H"""
    <div class="pc"><div class="emp"><div class="ei">📌</div><div>Select a page from the sidebar</div></div></div>
    """
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp ficon(t) when is_binary(t) do
    cond do
      String.starts_with?(t, "audio/") -> "🎵"
      String.starts_with?(t, "video/") -> "🎬"
      String.starts_with?(t, "image/") -> "🖼️"
      String.contains?(t, "pdf")       -> "📕"
      String.contains?(t, "word")      -> "📝"
      String.contains?(t, "text")      -> "📄"
      true -> "📁"
    end
  end
  defp ficon(_), do: "📁"

  defp ftype(t) when is_binary(t) do
    cond do
      String.starts_with?(t, "audio/") -> "Audio"
      String.starts_with?(t, "video/") -> "Video"
      String.starts_with?(t, "image/") -> "Image"
      String.contains?(t, "pdf")       -> "PDF"
      String.contains?(t, "document")  -> "Document"
      String.contains?(t, "text")      -> "Text"
      true -> t
    end
  end
  defp ftype(_), do: "File"

  defp fstatus("synced"),     do: "Uploaded"
  defp fstatus("indexed"),    do: "Ready"
  defp fstatus("processing"), do: "Processing"
  defp fstatus(s),            do: s || "Unknown"

  defp sbadge("indexed"),    do: "bgn"
  defp sbadge("synced"),     do: "bb"
  defp sbadge("processing"), do: "by"
  defp sbadge(_),            do: "bg2"

  defp devico(d) when is_binary(d) do
    cond do
      String.contains?(d, "mobile") -> "📱"
      String.contains?(d, "tablet") -> "📟"
      true -> "💻"
    end
  end
  defp devico(_), do: "💻"

  defp devnm(nil), do: "Desktop"
  defp devnm(d),   do: String.capitalize(d)

  defp fdate(nil), do: "-"
  defp fdate(%NaiveDateTime{} = dt), do: NaiveDateTime.to_date(dt) |> Date.to_string()
  defp fdate(%DateTime{} = dt),      do: DateTime.to_date(dt) |> Date.to_string()
  defp fdate(_), do: "-"

  defp ago(nil), do: "Never"
  defp ago(%NaiveDateTime{} = dt) do
    diff = NaiveDateTime.diff(NaiveDateTime.utc_now(), dt, :minute)
    cond do
      diff < 1    -> "Just now"
      diff < 60   -> "#{diff}m ago"
      diff < 1440 -> "#{div(diff, 60)}h ago"
      true        -> "#{div(diff, 1440)}d ago"
    end
  end
  defp ago(%DateTime{} = dt), do: ago(DateTime.to_naive(dt))
  defp ago(_), do: "-"

  defp mask(nil), do: "-"
  defp mask(email) do
    [u, d] = String.split(email, "@", parts: 2)
    String.first(u) <> String.duplicate("*", max(0, String.length(u) - 1)) <> "@" <> d
  end
end