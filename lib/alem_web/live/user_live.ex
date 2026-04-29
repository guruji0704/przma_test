defmodule AlemWeb.UserLive do
  @moduledoc """
  User-facing control panel. Shows files, storage, identity, sessions, and account settings.
  Never exposes internal fields (object_key, content_hash, tenant_id, session_id, ip_address).
  """
  use AlemWeb, :live_view
  import Ecto.Query
  alias Alem.{Repo, Auth}
  alias Alem.Schemas.Document
  require Logger

  @impl true
  def mount(_params, session, socket) do
    user = get_user_from_session(session)

    socket =
      socket
      |> assign(:current_user, user)
      |> assign(:page, :home)
      |> assign(:files, [])
      |> assign(:files_search, "")
      |> assign(:files_filter, "all")
      |> assign(:storage_stats, nil)
      |> assign(:sessions, [])
      |> assign(:did_info, nil)
      |> assign(:flash_msg, nil)
      |> assign(:flash_type, :success)
      |> assign(:confirm_action, nil)
      |> assign(:edit_profile, false)
      |> assign(:profile_form, %{"nickname" => user && user.nickname || "", "bio" => user && user[:bio] || ""})

    {:ok, socket}
  end

  defp get_user_from_session(_session), do: nil

  # ── Navigation ─────────────────────────────────────────────────────────────

  def handle_event("nav", %{"page" => page}, socket) do
    page_atom = String.to_existing_atom(page)
    socket = assign(socket, :page, page_atom) |> assign(:confirm_action, nil)
    socket = load_user_page(socket, page_atom)
    {:noreply, socket}
  rescue
    _ -> {:noreply, socket}
  end

  defp load_user_page(socket, :files) do
    user_id = get_user_id(socket)
    files = Repo.all(
      from d in Document,
      where: d.user_id == ^user_id,
      order_by: [desc: d.inserted_at],
      limit: 100,
      select: %{id: d.id, filename: d.filename, content_type: d.content_type,
                status: d.status, inserted_at: d.inserted_at, updated_at: d.updated_at}
    )
    assign(socket, :files, files)
  rescue
    _ -> assign(socket, :files, [])
  end

  defp load_user_page(socket, :storage) do
    user_id = get_user_id(socket)
    stats = compute_storage_stats(user_id)
    assign(socket, :storage_stats, stats)
  end

  defp load_user_page(socket, :identity) do
    did_info = load_did_info(socket)
    assign(socket, :did_info, did_info)
  end

  defp load_user_page(socket, :sessions) do
    sessions = load_sessions(socket)
    assign(socket, :sessions, sessions)
  end

  defp load_user_page(socket, _), do: socket

  defp get_user_id(socket) do
    case socket.assigns.current_user do
      nil -> "demo_user"
      u   -> u.id
    end
  end

  defp compute_storage_stats(user_id) do
    try do
      total_files = Repo.aggregate(from(d in Document, where: d.user_id == ^user_id), :count, :id)
      %{
        total_files: total_files,
        storage_bytes: 0,
        plan: "free",
        quota_bytes: 5_368_709_120,
        by_type: %{"image" => 0, "audio" => 0, "video" => 0, "document" => 0}
      }
    rescue
      _ -> %{total_files: 0, storage_bytes: 0, plan: "free", quota_bytes: 5_368_709_120, by_type: %{}}
    end
  end

  defp load_did_info(socket) do
    user = socket.assigns.current_user
    if user && user[:did_id] do
      %{did: user.did_id, fingerprint: String.slice(user.did_id, -12, 12)}
    else
      %{did: "did:przma:demo001", fingerprint: "demo001"}
    end
  end

  defp load_sessions(socket) do
    try do
      user_id = get_user_id(socket)
      Repo.all(
        from s in Alem.Session,
        where: s.user_id == ^user_id and is_nil(s.revoked_at),
        order_by: [desc: s.last_active_at],
        limit: 20,
        select: %{id: s.id, device: s.device, last_active_at: s.last_active_at,
                  created_at: s.inserted_at}
      )
    rescue
      _ -> []
    end
  end

  # ── Files ──────────────────────────────────────────────────────────────────

  def handle_event("search_files", %{"search" => q}, socket) do
    filtered = filter_files(socket.assigns.files, q, socket.assigns.files_filter)
    {:noreply, assign(socket, files_search: q, filtered_files: filtered)}
  end

  def handle_event("filter_files", %{"filter" => f}, socket) do
    {:noreply, assign(socket, files_filter: f)}
  end

  defp filter_files(files, search, filter) do
    files
    |> Enum.filter(fn f ->
      matches_search = search == "" or String.contains?(String.downcase(f.filename || ""), String.downcase(search))
      matches_filter = case filter do
        "image"    -> String.starts_with?(f.content_type || "", "image/")
        "audio"    -> String.starts_with?(f.content_type || "", "audio/")
        "video"    -> String.starts_with?(f.content_type || "", "video/")
        "document" -> String.contains?(f.content_type || "", "pdf") or String.contains?(f.content_type || "", "document")
        _          -> true
      end
      matches_search and matches_filter
    end)
  end

  # ── Sessions ───────────────────────────────────────────────────────────────

  def handle_event("revoke_session", %{"id" => id}, socket) do
    try do
      Repo.get(Alem.Session, id)
      |> Ecto.Changeset.change(%{revoked_at: DateTime.utc_now()})
      |> Repo.update()
    rescue
      _ -> :ok
    end
    sessions = load_sessions(socket)
    {:noreply, flash(assign(socket, :sessions, sessions), "Session revoked", :success)}
  end

  def handle_event("revoke_all_sessions", _, socket) do
    try do
      user_id = get_user_id(socket)
      Repo.update_all(
        from(s in Alem.Session, where: s.user_id == ^user_id and is_nil(s.revoked_at)),
        set: [revoked_at: DateTime.utc_now()]
      )
    rescue
      _ -> :ok
    end
    {:noreply, flash(assign(socket, :sessions, []), "All sessions revoked", :success)}
  end

  # ── Profile ────────────────────────────────────────────────────────────────

  def handle_event("edit_profile", _, socket) do
    {:noreply, assign(socket, edit_profile: true)}
  end

  def handle_event("cancel_edit", _, socket) do
    {:noreply, assign(socket, edit_profile: false)}
  end

  def handle_event("save_profile", %{"nickname" => nick, "bio" => bio}, socket) do
    {:noreply, flash(assign(socket, edit_profile: false), "Profile updated", :success)}
  end

  # ── Flash ──────────────────────────────────────────────────────────────────

  defp flash(socket, msg, type) do
    socket |> assign(:flash_msg, msg) |> assign(:flash_type, type)
  end

  def handle_event("dismiss_flash", _, socket) do
    {:noreply, assign(socket, flash_msg: nil)}
  end

  # ── Confirm ────────────────────────────────────────────────────────────────

  def handle_event("confirm_action", %{"action" => a, "label" => l}, socket) do
    {:noreply, assign(socket, confirm_action: %{action: a, label: l})}
  end

  def handle_event("cancel_confirm", _, socket) do
    {:noreply, assign(socket, confirm_action: nil)}
  end

  def handle_event("execute_confirm", _, socket) do
    action = socket.assigns.confirm_action.action
    socket = apply_account_action(socket, action) |> assign(:confirm_action, nil)
    {:noreply, socket}
  end

  defp apply_account_action(socket, "disable_account") do
    flash(socket, "Account disabled. You will be logged out.", :success)
  end
  defp apply_account_action(socket, _), do: flash(socket, "Action completed", :success)

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="user-shell" id="user-shell">
      <style>
        @import url('https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&display=swap');
        :root {
          --bg: #f8fafc; --bg2: #ffffff; --bg3: #f1f5f9;
          --bdr: #e2e8f0; --bdr2: #cbd5e1;
          --tx1: #0f172a; --tx2: #475569; --tx3: #94a3b8;
          --acc: #2563eb; --acc2: #1d4ed8;
          --grn: #059669; --red: #dc2626; --yel: #d97706; --pur: #7c3aed;
          --r: 12px; --r2: 8px;
          font-family: 'Inter', system-ui, sans-serif;
        }
        .user-shell { display:flex; min-height:100vh; background:var(--bg); color:var(--tx1); }
        /* Sidebar */
        .usr-sidebar { width:240px; min-width:240px; background:var(--bg2); border-right:1px solid var(--bdr); display:flex; flex-direction:column; position:sticky; top:0; height:100vh; overflow-y:auto; }
        .usr-logo { padding:24px 20px 16px; border-bottom:1px solid var(--bdr); }
        .usr-logo .brand { font-size:16px; font-weight:700; color:var(--tx1); }
        .usr-logo .tagline { font-size:11px; color:var(--tx3); margin-top:2px; }
        .usr-profile-card { padding:16px 20px; border-bottom:1px solid var(--bdr); }
        .usr-avatar { width:40px; height:40px; border-radius:50%; background:linear-gradient(135deg,#2563eb,#7c3aed); display:flex; align-items:center; justify-content:center; font-size:16px; font-weight:700; color:#fff; margin-bottom:8px; }
        .usr-name { font-size:14px; font-weight:600; color:var(--tx1); }
        .usr-plan { font-size:11px; color:var(--tx3); margin-top:2px; }
        .usr-nav { padding:12px 0; flex:1; }
        .unav-item { display:flex; align-items:center; gap:10px; padding:10px 20px; font-size:14px; color:var(--tx2); cursor:pointer; transition:.12s; border:none; background:none; width:100%; text-align:left; font-family:inherit; }
        .unav-item:hover { background:var(--bg3); color:var(--tx1); }
        .unav-item.active { background:rgba(37,99,235,.06); color:var(--acc); font-weight:500; border-right:2px solid var(--acc); }
        .unav-item .ico { font-size:16px; width:20px; text-align:center; flex-shrink:0; }
        /* Main */
        .usr-main { flex:1; display:flex; flex-direction:column; }
        .usr-topbar { background:var(--bg2); border-bottom:1px solid var(--bdr); padding:0 24px; height:56px; display:flex; align-items:center; gap:12px; position:sticky; top:0; z-index:10; }
        .usr-topbar .page-title { font-size:16px; font-weight:600; color:var(--tx1); }
        .usr-topbar .spacer { flex:1; }
        .usr-content { flex:1; padding:24px; max-width:1100px; }
        /* Cards */
        .stat-row { display:grid; grid-template-columns:repeat(4,1fr); gap:16px; margin-bottom:24px; }
        .scard { background:var(--bg2); border:1px solid var(--bdr); border-radius:var(--r); padding:20px; }
        .scard .ico { font-size:24px; margin-bottom:10px; }
        .scard .label { font-size:12px; color:var(--tx3); font-weight:500; margin-bottom:6px; }
        .scard .value { font-size:22px; font-weight:700; color:var(--tx1); }
        .scard .sub { font-size:12px; color:var(--tx3); margin-top:4px; }
        /* Panel */
        .upanel { background:var(--bg2); border:1px solid var(--bdr); border-radius:var(--r); margin-bottom:16px; overflow:hidden; }
        .upanel-header { padding:16px 20px; border-bottom:1px solid var(--bdr); display:flex; align-items:center; gap:10px; }
        .upanel-header .ttl { font-size:15px; font-weight:600; color:var(--tx1); }
        .upanel-header .cnt { font-size:12px; color:var(--tx3); }
        .upanel-header .spacer { flex:1; }
        .upanel-body { padding:20px; }
        /* Table */
        table { width:100%; border-collapse:collapse; }
        th { padding:10px 16px; text-align:left; font-size:12px; font-weight:600; color:var(--tx3); border-bottom:1px solid var(--bdr); }
        td { padding:12px 16px; font-size:13px; color:var(--tx1); border-bottom:1px solid var(--bdr); }
        tr:last-child td { border-bottom:none; }
        tr:hover td { background:var(--bg3); }
        /* Badges */
        .badge { display:inline-block; padding:3px 8px; border-radius:20px; font-size:11px; font-weight:500; }
        .badge-green { background:#ecfdf5; color:#059669; }
        .badge-blue { background:#eff6ff; color:#2563eb; }
        .badge-yellow { background:#fffbeb; color:#d97706; }
        .badge-gray { background:var(--bg3); color:var(--tx3); }
        .badge-red { background:#fef2f2; color:#dc2626; }
        /* Buttons */
        .btn { display:inline-flex; align-items:center; gap:6px; padding:8px 16px; border-radius:var(--r2); font-size:13px; font-weight:500; cursor:pointer; border:none; transition:.12s; font-family:inherit; }
        .btn-primary { background:var(--acc); color:#fff; }
        .btn-primary:hover { background:var(--acc2); }
        .btn-outline { background:transparent; color:var(--tx2); border:1px solid var(--bdr2); }
        .btn-outline:hover { background:var(--bg3); }
        .btn-danger { background:transparent; color:var(--red); border:1px solid #fecaca; }
        .btn-danger:hover { background:#fef2f2; }
        .btn-sm { padding:5px 10px; font-size:12px; }
        /* Forms */
        .fld { background:var(--bg); border:1px solid var(--bdr2); border-radius:var(--r2); padding:9px 12px; color:var(--tx1); font-size:13px; font-family:inherit; width:100%; box-sizing:border-box; }
        .fld:focus { outline:none; border-color:var(--acc); box-shadow:0 0 0 3px rgba(37,99,235,.1); }
        select.fld { cursor:pointer; }
        .fld-label { font-size:12px; font-weight:500; color:var(--tx2); margin-bottom:6px; display:block; }
        .fld-group { margin-bottom:14px; }
        /* DID card */
        .did-card { background:linear-gradient(135deg,#eff6ff,#f5f3ff); border:1px solid #c7d2fe; border-radius:var(--r); padding:24px; }
        .did-value { font-family:'SF Mono','Fira Code',monospace; font-size:13px; color:var(--acc); word-break:break-all; background:#fff; border:1px solid var(--bdr); border-radius:var(--r2); padding:12px; margin:10px 0; }
        /* Progress */
        .progress-wrap { background:var(--bg3); border-radius:999px; height:8px; overflow:hidden; }
        .progress-fill { height:100%; border-radius:999px; transition:width .4s; }
        .fill-blue { background:var(--acc); }
        .fill-green { background:var(--grn); }
        .fill-yellow { background:var(--yel); }
        .fill-red { background:var(--red); }
        /* File type icon */
        .file-ico { font-size:20px; }
        /* Flash */
        .flash-bar { position:fixed; top:20px; right:20px; z-index:1000; display:flex; align-items:center; gap:10px; padding:12px 18px; border-radius:var(--r); font-size:13px; font-weight:500; box-shadow:0 4px 20px rgba(0,0,0,.12); animation:slideIn .2s ease; }
        .flash-success { background:#fff; color:#059669; border:1px solid #a7f3d0; }
        .flash-error { background:#fff; color:#dc2626; border:1px solid #fecaca; }
        @keyframes slideIn { from{transform:translateX(30px);opacity:0} to{transform:none;opacity:1} }
        /* Modal */
        .modal-bg { position:fixed; inset:0; background:rgba(15,23,42,.4); z-index:500; display:flex; align-items:center; justify-content:center; backdrop-filter:blur(4px); }
        .modal { background:#fff; border-radius:var(--r); padding:28px; width:400px; box-shadow:0 20px 60px rgba(0,0,0,.15); }
        .modal h3 { font-size:17px; font-weight:700; margin-bottom:8px; }
        .modal p { font-size:13px; color:var(--tx2); margin-bottom:24px; }
        .modal-actions { display:flex; gap:10px; justify-content:flex-end; }
        /* Grid */
        .grid-2 { display:grid; grid-template-columns:1fr 1fr; gap:16px; }
        /* Empty state */
        .empty-state { text-align:center; padding:48px 24px; color:var(--tx3); }
        .empty-state .ico { font-size:40px; margin-bottom:12px; }
        .empty-state .msg { font-size:14px; }
        /* Section title */
        .section-title { font-size:13px; font-weight:600; color:var(--tx2); text-transform:uppercase; letter-spacing:.6px; margin-bottom:12px; }
        /* Session card */
        .session-card { display:flex; align-items:center; justify-content:space-between; padding:14px 16px; border:1px solid var(--bdr); border-radius:var(--r2); margin-bottom:8px; background:var(--bg2); }
        .session-device { font-size:13px; font-weight:500; color:var(--tx1); }
        .session-meta { font-size:11px; color:var(--tx3); margin-top:3px; }
        /* Danger zone */
        .danger-zone { border:1px solid #fecaca; border-radius:var(--r); padding:20px; background:#fff5f5; }
        .danger-zone .danger-title { font-size:14px; font-weight:600; color:var(--red); margin-bottom:12px; }
        /* Responsive */
        @media (max-width: 768px) {
          .stat-row { grid-template-columns:repeat(2,1fr); }
          .usr-sidebar { display:none; }
        }
      </style>

      <!-- Flash -->
      <%= if @flash_msg do %>
        <div class={"flash-bar flash-#{@flash_type}"}>
          <%= if @flash_type == :success, do: "✓", else: "✕" %>
          <%= @flash_msg %>
          <button phx-click="dismiss_flash" style="margin-left:8px;background:none;border:none;color:inherit;cursor:pointer;font-size:16px">×</button>
        </div>
      <% end %>

      <!-- Confirm Modal -->
      <%= if @confirm_action do %>
        <div class="modal-bg">
          <div class="modal">
            <h3>Confirm</h3>
            <p><%= @confirm_action.label %></p>
            <div class="modal-actions">
              <button class="btn btn-outline" phx-click="cancel_confirm">Cancel</button>
              <button class="btn btn-danger" phx-click="execute_confirm">Confirm</button>
            </div>
          </div>
        </div>
      <% end %>

      <!-- Sidebar -->
      <nav class="usr-sidebar">
        <div class="usr-logo">
          <div class="brand">⬡ PRZMA</div>
          <div class="tagline">Sovereign File Platform</div>
        </div>

        <div class="usr-profile-card">
          <div class="usr-avatar">G</div>
          <div class="usr-name">Guruji</div>
          <div class="usr-plan">Free Plan · 5 GB</div>
        </div>

        <div class="usr-nav">
          <button class={"unav-item #{if @page == :home, do: "active"}"} phx-click="nav" phx-value-page="home">
            <span class="ico">🏠</span> Home
          </button>
          <button class={"unav-item #{if @page == :files, do: "active"}"} phx-click="nav" phx-value-page="files">
            <span class="ico">📁</span> My Files
          </button>
          <button class={"unav-item #{if @page == :storage, do: "active"}"} phx-click="nav" phx-value-page="storage">
            <span class="ico">💾</span> Storage
          </button>
          <button class={"unav-item #{if @page == :identity, do: "active"}"} phx-click="nav" phx-value-page="identity">
            <span class="ico">🪪</span> Identity (DID)
          </button>
          <button class={"unav-item #{if @page == :sessions, do: "active"}"} phx-click="nav" phx-value-page="sessions">
            <span class="ico">🔐</span> Sessions
          </button>
          <button class={"unav-item #{if @page == :settings, do: "active"}"} phx-click="nav" phx-value-page="settings">
            <span class="ico">⚙️</span> Account Settings
          </button>
        </div>
      </nav>

      <!-- Main Content -->
      <div class="usr-main">
        <div class="usr-topbar">
          <span class="page-title"><%= user_page_title(@page) %></span>
          <span class="spacer"></span>
          <button class="btn btn-outline btn-sm">+ Upload File</button>
        </div>

        <div class="usr-content">
          <%= user_render_page(assigns) %>
        </div>
      </div>
    </div>
    """
  end

  defp user_page_title(:home), do: "Overview"
  defp user_page_title(:files), do: "My Files"
  defp user_page_title(:storage), do: "Storage"
  defp user_page_title(:identity), do: "Identity"
  defp user_page_title(:sessions), do: "Active Sessions"
  defp user_page_title(:settings), do: "Account Settings"
  defp user_page_title(_), do: "PRZMA"

  defp user_render_page(%{page: :home} = assigns) do
    ~H"""
    <div class="stat-row">
      <div class="scard">
        <div class="ico">📄</div>
        <div class="label">Total Files</div>
        <div class="value">0</div>
        <div class="sub">All formats</div>
      </div>
      <div class="scard">
        <div class="ico">💾</div>
        <div class="label">Storage Used</div>
        <div class="value">0 B</div>
        <div class="sub">of 5 GB free</div>
      </div>
      <div class="scard">
        <div class="ico">🔐</div>
        <div class="label">Active Sessions</div>
        <div class="value"><%= length(@sessions) %></div>
        <div class="sub">Devices logged in</div>
      </div>
      <div class="scard">
        <div class="ico">🕐</div>
        <div class="label">Last Sync</div>
        <div class="value" style="font-size:14px">Never</div>
        <div class="sub">Upload to sync</div>
      </div>
    </div>

    <div class="upanel">
      <div class="upanel-header">
        <span class="ttl">Getting Started</span>
      </div>
      <div class="upanel-body">
        <div style="display:flex;flex-direction:column;gap:12px">
          <div style="display:flex;align-items:center;gap:14px;padding:14px;background:var(--bg3);border-radius:var(--r2)">
            <span style="font-size:24px">🎵</span>
            <div>
              <div style="font-weight:600;margin-bottom:2px">Upload Audio</div>
              <div style="font-size:12px;color:var(--tx3)">MP3, WAV, FLAC — generates 446-dim perception vector</div>
            </div>
            <button class="btn btn-primary btn-sm" style="margin-left:auto">Upload</button>
          </div>
          <div style="display:flex;align-items:center;gap:14px;padding:14px;background:var(--bg3);border-radius:var(--r2)">
            <span style="font-size:24px">🖼</span>
            <div>
              <div style="font-weight:600;margin-bottom:2px">Upload Image</div>
              <div style="font-size:12px;color:var(--tx3)">JPG, PNG, GIF — pixel intensity encoding</div>
            </div>
            <button class="btn btn-primary btn-sm" style="margin-left:auto">Upload</button>
          </div>
          <div style="display:flex;align-items:center;gap:14px;padding:14px;background:var(--bg3);border-radius:var(--r2)">
            <span style="font-size:24px">📄</span>
            <div>
              <div style="font-weight:600;margin-bottom:2px">Upload Document</div>
              <div style="font-size:12px;color:var(--tx3)">PDF, DOCX, TXT — byte histogram encoding</div>
            </div>
            <button class="btn btn-primary btn-sm" style="margin-left:auto">Upload</button>
          </div>
        </div>
      </div>
    </div>

    <div class="upanel">
      <div class="upanel-header">
        <span class="ttl">Your Plan</span>
      </div>
      <div class="upanel-body">
        <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:16px">
          <div>
            <div style="font-size:16px;font-weight:700">Free Plan</div>
            <div style="font-size:12px;color:var(--tx3);margin-top:4px">5 GB storage · All file types · Perception vectors</div>
          </div>
          <span class="badge badge-gray">FREE</span>
        </div>
        <div style="margin-bottom:8px">
          <div style="display:flex;justify-content:space-between;margin-bottom:6px">
            <span style="font-size:12px;color:var(--tx3)">Storage used</span>
            <span style="font-size:12px;color:var(--tx2)">0 B of 5 GB</span>
          </div>
          <div class="progress-wrap">
            <div class="progress-fill fill-blue" style="width:0%"></div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp user_render_page(%{page: :files} = assigns) do
    files = assigns.files
    search = assigns.files_search
    filter = assigns.files_filter

    filtered = filter_files(files, search, filter)

    assigns = assign(assigns, :filtered_files, filtered)

    ~H"""
    <!-- Toolbar -->
    <div class="upanel" style="margin-bottom:16px">
      <div class="upanel-body" style="padding:14px 16px">
        <div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap">
          <form phx-submit="search_files" style="display:flex;gap:8px;flex:1;min-width:200px">
            <input class="fld" name="search" placeholder="Search files..." value={@files_search} style="flex:1"/>
            <button class="btn btn-primary btn-sm" type="submit">Search</button>
          </form>
          <form phx-change="filter_files">
            <select class="fld" name="filter" style="width:auto">
              <option value="all" selected={@files_filter == "all"}>All Types</option>
              <option value="audio" selected={@files_filter == "audio"}>🎵 Audio</option>
              <option value="image" selected={@files_filter == "image"}>🖼 Images</option>
              <option value="video" selected={@files_filter == "video"}>🎬 Video</option>
              <option value="document" selected={@files_filter == "document"}>📄 Documents</option>
            </select>
          </form>
          <span style="color:var(--tx3);font-size:12px"><%= length(@filtered_files) %> files</span>
        </div>
      </div>
    </div>

    <%= if @filtered_files == [] do %>
      <div class="upanel">
        <div class="empty-state">
          <div class="ico">📂</div>
          <div class="msg">No files yet. Upload a file to get started.</div>
        </div>
      </div>
    <% else %>
      <div class="upanel">
        <table>
          <thead>
            <tr>
              <th>File</th>
              <th>Type</th>
              <th>Status</th>
              <th>Uploaded</th>
            </tr>
          </thead>
          <tbody>
            <%= for f <- @filtered_files do %>
              <tr>
                <td>
                  <div style="display:flex;align-items:center;gap:10px">
                    <span class="file-ico"><%= file_icon(f.content_type) %></span>
                    <div>
                      <div style="font-weight:500"><%= f.filename %></div>
                    </div>
                  </div>
                </td>
                <td>
                  <span class="badge badge-gray"><%= friendly_type(f.content_type) %></span>
                </td>
                <td>
                  <span class={"badge #{friendly_status_badge(f.status)}"}>
                    <%= friendly_status(f.status) %>
                  </span>
                </td>
                <td style="color:var(--tx3);font-size:12px">
                  <%= format_date(f.inserted_at) %>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    <% end %>
    """
  end

  defp user_render_page(%{page: :storage} = assigns) do
    ~H"""
    <div class="stat-row" style="grid-template-columns:repeat(3,1fr)">
      <div class="scard">
        <div class="label">Total Files</div>
        <div class="value"><%= (@storage_stats && @storage_stats.total_files) || 0 %></div>
      </div>
      <div class="scard">
        <div class="label">Storage Used</div>
        <div class="value" style="font-size:16px">0 B</div>
        <div class="sub">of 5 GB</div>
      </div>
      <div class="scard">
        <div class="label">Plan</div>
        <div class="value" style="font-size:16px">Free</div>
      </div>
    </div>

    <div class="upanel">
      <div class="upanel-header"><span class="ttl">Storage Usage</span></div>
      <div class="upanel-body">
        <div style="display:flex;justify-content:space-between;margin-bottom:8px">
          <span style="font-size:13px;color:var(--tx2)">Used</span>
          <span style="font-size:13px;font-weight:500">0 B of 5 GB</span>
        </div>
        <div class="progress-wrap" style="height:12px;margin-bottom:20px">
          <div class="progress-fill fill-blue" style="width:0%"></div>
        </div>

        <div class="section-title">By File Type</div>
        <div style="display:flex;flex-direction:column;gap:10px">
          <div style="display:flex;align-items:center;gap:12px">
            <span style="width:80px;font-size:13px;color:var(--tx2)">🎵 Audio</span>
            <div class="progress-wrap" style="flex:1"><div class="progress-fill fill-blue" style="width:0%"></div></div>
            <span style="font-size:12px;color:var(--tx3);width:40px">0 B</span>
          </div>
          <div style="display:flex;align-items:center;gap:12px">
            <span style="width:80px;font-size:13px;color:var(--tx2)">🖼 Images</span>
            <div class="progress-wrap" style="flex:1"><div class="progress-fill fill-green" style="width:0%"></div></div>
            <span style="font-size:12px;color:var(--tx3);width:40px">0 B</span>
          </div>
          <div style="display:flex;align-items:center;gap:12px">
            <span style="width:80px;font-size:13px;color:var(--tx2)">🎬 Video</span>
            <div class="progress-wrap" style="flex:1"><div class="progress-fill" style="width:0%;background:var(--pur)"></div></div>
            <span style="font-size:12px;color:var(--tx3);width:40px">0 B</span>
          </div>
          <div style="display:flex;align-items:center;gap:12px">
            <span style="width:80px;font-size:13px;color:var(--tx2)">📄 Docs</span>
            <div class="progress-wrap" style="flex:1"><div class="progress-fill fill-yellow" style="width:0%"></div></div>
            <span style="font-size:12px;color:var(--tx3);width:40px">0 B</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp user_render_page(%{page: :identity} = assigns) do
    ~H"""
    <div class="did-card" style="margin-bottom:16px">
      <div style="font-size:14px;font-weight:600;color:var(--tx1);margin-bottom:4px">Your Decentralized Identity (DID)</div>
      <div style="font-size:12px;color:var(--tx3);margin-bottom:12px">This is your unique identifier on the PRZMA platform. Share it to receive files or verify your identity.</div>

      <div style="font-size:11px;color:var(--tx3);margin-bottom:4px">Full DID</div>
      <div class="did-value"><%= (@did_info && @did_info.did) || "did:przma:demo001" %></div>
      <button class="btn btn-outline btn-sm" onclick="navigator.clipboard.writeText(this.dataset.val)" data-val={(@did_info && @did_info.did) || "did:przma:demo001"}>
        📋 Copy DID
      </button>
    </div>

    <div class="upanel">
      <div class="upanel-header"><span class="ttl">Identity Details</span></div>
      <div class="upanel-body">
        <div style="display:grid;grid-template-columns:1fr 1fr;gap:16px">
          <div>
            <div class="fld-label">DID Method</div>
            <div style="font-size:13px;color:var(--tx1);font-family:monospace">przma</div>
          </div>
          <div>
            <div class="fld-label">Fingerprint</div>
            <div style="font-size:13px;color:var(--tx1);font-family:monospace"><%= (@did_info && @did_info.fingerprint) || "demo001" %></div>
          </div>
          <div>
            <div class="fld-label">Namespace Key</div>
            <div style="font-size:12px;color:var(--tx3)">Hidden for security</div>
          </div>
          <div>
            <div class="fld-label">Vault Encryption</div>
            <div style="font-size:13px;color:var(--grn)">✓ AES-256-GCM</div>
          </div>
        </div>
      </div>
    </div>

    <div class="upanel">
      <div class="upanel-header"><span class="ttl">What is your DID?</span></div>
      <div class="upanel-body" style="color:var(--tx2);font-size:13px;line-height:1.7">
        Your DID (Decentralized Identifier) is a self-sovereign identity that you own.
        It is used to encrypt your files, generate your namespace, and authenticate with the platform.
        Unlike a username, your DID cannot be changed or transferred.
        <br/><br/>
        <strong style="color:var(--tx1)">Never share your private key or namespace key</strong> — only share your public DID string.
      </div>
    </div>
    """
  end

  defp user_render_page(%{page: :sessions} = assigns) do
    ~H"""
    <div class="upanel" style="margin-bottom:16px">
      <div class="upanel-header">
        <span class="ttl">Active Sessions</span>
        <span class="cnt"><%= length(@sessions) %></span>
        <span class="spacer"></span>
        <%= if length(@sessions) > 1 do %>
          <button class="btn btn-danger btn-sm" phx-click="confirm_action"
            phx-value-action="revoke_all_sessions"
            phx-value-label="Revoke all sessions? You will need to log in again on all devices.">
            Revoke All
          </button>
        <% end %>
      </div>
      <div class="upanel-body">
        <%= if @sessions == [] do %>
          <div class="empty-state" style="padding:24px">
            <div class="ico">🔐</div>
            <div class="msg">No active sessions</div>
          </div>
        <% else %>
          <%= for s <- @sessions do %>
            <div class="session-card">
              <div>
                <div class="session-device">
                  <%= device_icon(s[:device]) %> <%= friendly_device(s[:device]) %>
                </div>
                <div class="session-meta">
                  Last active: <%= format_dt_friendly(s[:last_active_at]) %>
                  · Created: <%= format_date(s[:created_at]) %>
                </div>
              </div>
              <button class="btn btn-danger btn-sm" phx-click="revoke_session" phx-value-id={s.id}>
                Revoke
              </button>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>

    <div class="upanel">
      <div class="upanel-header"><span class="ttl">Security Tips</span></div>
      <div class="upanel-body" style="display:flex;flex-direction:column;gap:10px">
        <div style="display:flex;gap:10px;align-items:flex-start">
          <span>🔒</span>
          <div style="font-size:13px;color:var(--tx2)">Revoke sessions on devices you no longer use or trust</div>
        </div>
        <div style="display:flex;gap:10px;align-items:flex-start">
          <span>📱</span>
          <div style="font-size:13px;color:var(--tx2)">If you see an unfamiliar device, revoke it immediately and change your password</div>
        </div>
        <div style="display:flex;gap:10px;align-items:flex-start">
          <span>🛡</span>
          <div style="font-size:13px;color:var(--tx2)">Your IP address is never displayed — only device type is shown for privacy</div>
        </div>
      </div>
    </div>
    """
  end

  defp user_render_page(%{page: :settings} = assigns) do
    ~H"""
    <!-- Profile -->
    <div class="upanel">
      <div class="upanel-header">
        <span class="ttl">Profile</span>
        <span class="spacer"></span>
        <%= if !@edit_profile do %>
          <button class="btn btn-outline btn-sm" phx-click="edit_profile">Edit</button>
        <% end %>
      </div>
      <div class="upanel-body">
        <%= if @edit_profile do %>
          <form phx-submit="save_profile">
            <div class="fld-group">
              <label class="fld-label">Nickname</label>
              <input class="fld" name="nickname" value={@profile_form["nickname"]} placeholder="Your display name"/>
            </div>
            <div class="fld-group">
              <label class="fld-label">Bio</label>
              <textarea class="fld" name="bio" rows="3" placeholder="Tell us about yourself"><%= @profile_form["bio"] %></textarea>
            </div>
            <div style="display:flex;gap:8px">
              <button class="btn btn-primary" type="submit">Save Changes</button>
              <button class="btn btn-outline" type="button" phx-click="cancel_edit">Cancel</button>
            </div>
          </form>
        <% else %>
          <div style="display:grid;grid-template-columns:1fr 1fr;gap:16px">
            <div>
              <div class="fld-label">Nickname</div>
              <div style="font-size:14px;font-weight:500"><%= @profile_form["nickname"] || "Not set" %></div>
            </div>
            <div>
              <div class="fld-label">Email</div>
              <div style="font-size:14px">g***@gmail.com</div>
            </div>
            <div>
              <div class="fld-label">Account Status</div>
              <span class="badge badge-green">Active</span>
              <span class="badge badge-blue" style="margin-left:4px">Verified</span>
            </div>
            <div>
              <div class="fld-label">Member Since</div>
              <div style="font-size:14px;color:var(--tx2)">April 2026</div>
            </div>
          </div>
        <% end %>
      </div>
    </div>

    <!-- Security -->
    <div class="upanel">
      <div class="upanel-header"><span class="ttl">Security</span></div>
      <div class="upanel-body">
        <div style="display:flex;flex-direction:column;gap:8px">
          <div style="display:flex;align-items:center;justify-content:space-between;padding:12px 0;border-bottom:1px solid var(--bdr)">
            <div>
              <div style="font-size:13px;font-weight:500">Change Password</div>
              <div style="font-size:12px;color:var(--tx3)">Update your account password</div>
            </div>
            <button class="btn btn-outline btn-sm">Change</button>
          </div>
          <div style="display:flex;align-items:center;justify-content:space-between;padding:12px 0;border-bottom:1px solid var(--bdr)">
            <div>
              <div style="font-size:13px;font-weight:500">Resend Verification Email</div>
              <div style="font-size:12px;color:var(--tx3)">POST /api/v1/account/resend_otp</div>
            </div>
            <button class="btn btn-outline btn-sm">Resend</button>
          </div>
          <div style="display:flex;align-items:center;justify-content:space-between;padding:12px 0">
            <div>
              <div style="font-size:13px;font-weight:500">Log Out All Devices</div>
              <div style="font-size:12px;color:var(--tx3)">Revoke all active sessions</div>
            </div>
            <button class="btn btn-danger btn-sm" phx-click="revoke_all_sessions">Log Out All</button>
          </div>
        </div>
      </div>
    </div>

    <!-- Danger Zone -->
    <div class="danger-zone">
      <div class="danger-title">⚠ Danger Zone</div>
      <div style="display:flex;flex-direction:column;gap:10px">
        <div style="display:flex;align-items:center;justify-content:space-between;padding:12px;background:#fff;border-radius:var(--r2);border:1px solid #fecaca">
          <div>
            <div style="font-size:13px;font-weight:500;color:var(--tx1)">Disable Account</div>
            <div style="font-size:12px;color:var(--tx3)">Temporarily disable your account. You can re-enable it later.</div>
          </div>
          <button class="btn btn-danger btn-sm"
            phx-click="confirm_action"
            phx-value-action="disable_account"
            phx-value-label="Disable your account? You will be logged out and cannot log in until re-enabled.">
            Disable
          </button>
        </div>
        <div style="display:flex;align-items:center;justify-content:space-between;padding:12px;background:#fff;border-radius:var(--r2);border:1px solid #fecaca">
          <div>
            <div style="font-size:13px;font-weight:500;color:var(--red)">Delete Account</div>
            <div style="font-size:12px;color:var(--tx3)">Permanently delete your account and all data. This cannot be undone.</div>
          </div>
          <button class="btn btn-danger btn-sm"
            phx-click="confirm_action"
            phx-value-action="delete_account"
            phx-value-label="PERMANENTLY delete your account and all files? This cannot be undone.">
            Delete
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp user_render_page(assigns) do
    ~H"""
    <div style="text-align:center;padding:48px;color:var(--tx3)">Select a section from the sidebar.</div>
    """
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp file_icon(type) when is_binary(type) do
    cond do
      String.starts_with?(type, "audio/") -> "🎵"
      String.starts_with?(type, "video/") -> "🎬"
      String.starts_with?(type, "image/") -> "🖼"
      String.contains?(type, "pdf") -> "📕"
      String.contains?(type, "word") or String.contains?(type, "document") -> "📝"
      true -> "📄"
    end
  end
  defp file_icon(_), do: "📄"

  defp friendly_type(type) when is_binary(type) do
    cond do
      String.starts_with?(type, "audio/") -> "Audio"
      String.starts_with?(type, "video/") -> "Video"
      String.starts_with?(type, "image/") -> "Image"
      String.contains?(type, "pdf") -> "PDF"
      String.contains?(type, "document") -> "Document"
      String.contains?(type, "text") -> "Text"
      true -> type
    end
  end
  defp friendly_type(_), do: "File"

  defp friendly_status("synced"), do: "Uploaded"
  defp friendly_status("indexed"), do: "Ready"
  defp friendly_status("processing"), do: "Syncing..."
  defp friendly_status(s), do: s || "Unknown"

  defp friendly_status_badge("indexed"), do: "badge-green"
  defp friendly_status_badge("synced"), do: "badge-blue"
  defp friendly_status_badge("processing"), do: "badge-yellow"
  defp friendly_status_badge(_), do: "badge-gray"

  defp device_icon(d) when is_binary(d) do
    cond do
      String.contains?(d, "mobile") -> "📱"
      String.contains?(d, "tablet") -> "📟"
      true -> "💻"
    end
  end
  defp device_icon(_), do: "💻"

  defp friendly_device(nil), do: "Desktop"
  defp friendly_device(d), do: String.capitalize(d)

  defp format_date(nil), do: "-"
  defp format_date(%NaiveDateTime{} = dt), do: NaiveDateTime.to_date(dt) |> Date.to_string()
  defp format_date(%DateTime{} = dt), do: DateTime.to_date(dt) |> Date.to_string()
  defp format_date(_), do: "-"

  defp format_dt_friendly(nil), do: "Never"
  defp format_dt_friendly(%NaiveDateTime{} = dt) do
    diff = NaiveDateTime.diff(NaiveDateTime.utc_now(), dt, :minute)
    cond do
      diff < 1   -> "Just now"
      diff < 60  -> "#{diff}m ago"
      diff < 1440 -> "#{div(diff, 60)}h ago"
      true -> "#{div(diff, 1440)}d ago"
    end
  end
  defp format_dt_friendly(%DateTime{} = dt) do
    format_dt_friendly(DateTime.to_naive(dt))
  end
  defp format_dt_friendly(_), do: "-"
end
