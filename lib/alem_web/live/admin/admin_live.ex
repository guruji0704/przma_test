defmodule AlemWeb.AdminLive do
  use AlemWeb, :live_view
  alias Alem.Admin
  require Logger

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page,             :dashboard)
      |> assign(:theme,            :dark)
      |> assign(:stats,            Admin.dashboard_stats())
      |> assign(:users,            %{users: [], total: 0, page: 1, per: 20, pages: 0})
      |> assign(:user_detail,      nil)
      |> assign(:cas_objects,      %{items: [], total: 0, page: 1, per: 25, pages: 0})
      |> assign(:s3_tree,          [])
      |> assign(:duplicates,       %{duplicates: [], total_wasted: 0})
      |> assign(:monitoring,       nil)
      |> assign(:permissions,      nil)
      |> assign(:search,           "")
      |> assign(:user_filter,      "all")
      |> assign(:user_sort,        "newest")
      |> assign(:cas_filter,       "all")
      |> assign(:cas_search,       "")
      |> assign(:confirm_action,   nil)
      |> assign(:flash_msg,        nil)
      |> assign(:sql_query,        "SELECT id, nickname, email, is_verified, is_active, is_admin, inserted_at\nFROM users ORDER BY inserted_at DESC LIMIT 20;")
      |> assign(:sql_result,       nil)
      |> assign(:sql_error,        nil)
      |> assign(:sql_running,      false)
      |> assign(:s3_prefix,        "")
      |> assign(:s3_result,        nil)
      |> assign(:s3_error,         nil)
      |> assign(:s3_presigned,     nil)
      |> assign(:s3_roots,         [])
      |> assign(:quota_data,       nil)
      |> assign(:audit_log,        [])

    if connected?(socket), do: :timer.send_interval(30_000, self(), :refresh_stats)
    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh_stats, socket) do
    {:noreply, assign(socket, :stats, Admin.dashboard_stats())}
  end

  # ── Theme ────────────────────────────────────────────────────────────────

  def handle_event("toggle_theme", _, socket) do
    theme = if socket.assigns.theme == :dark, do: :light, else: :dark
    {:noreply, assign(socket, :theme, theme)}
  end

  # ── Navigation ───────────────────────────────────────────────────────────

  @impl true
  def handle_event("nav", %{"page" => page}, socket) do
    page_atom = String.to_existing_atom(page)
    socket    = socket |> assign(:page, page_atom) |> assign(:user_detail, nil)
                       |> assign(:permissions, nil) |> assign(:flash_msg, nil)

    socket =
      case page_atom do
        :users      -> assign(socket, :users, Admin.list_users(%{search: socket.assigns.search, filter: socket.assigns.user_filter, sort: socket.assigns.user_sort}))
        :vault      -> socket |> assign(:cas_objects, Admin.list_cas_objects(%{})) |> assign(:s3_tree, Admin.s3_folder_tree())
        :duplicates -> assign(socket, :duplicates, Admin.duplicate_analysis())
        :monitoring -> assign(socket, :monitoring, Admin.monitoring_stats())
        :s3         -> socket |> assign(:s3_roots, Admin.s3_root_folders()) |> assign(:s3_result, nil) |> assign(:s3_prefix, "")
        :dashboard  -> socket |> assign(:stats, Admin.dashboard_stats()) |> assign(:audit_log, Admin.get_audit_log(20))
        _           -> socket
      end

    {:noreply, socket}
  end

  # ── Users ─────────────────────────────────────────────────────────────────

  def handle_event("search_users", %{"search" => q}, socket) do
    users = Admin.list_users(%{search: q, filter: socket.assigns.user_filter, sort: socket.assigns.user_sort})
    {:noreply, socket |> assign(:search, q) |> assign(:users, users)}
  end

  def handle_event("filter_users", %{"filter" => f}, socket) do
    users = Admin.list_users(%{search: socket.assigns.search, filter: f, sort: socket.assigns.user_sort})
    {:noreply, socket |> assign(:user_filter, f) |> assign(:users, users)}
  end

  def handle_event("sort_users", %{"sort" => s}, socket) do
    users = Admin.list_users(%{search: socket.assigns.search, filter: socket.assigns.user_filter, sort: s})
    {:noreply, socket |> assign(:user_sort, s) |> assign(:users, users)}
  end

  def handle_event("user_page", %{"page" => p}, socket) do
    users = Admin.list_users(%{search: socket.assigns.search, filter: socket.assigns.user_filter, sort: socket.assigns.user_sort, page: String.to_integer(p)})
    {:noreply, assign(socket, :users, users)}
  end

  def handle_event("view_user", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:user_detail, Admin.get_user_detail(id)) |> assign(:page, :user_detail)}
  end

  def handle_event("back_to_users", _, socket) do
    {:noreply, socket |> assign(:page, :users) |> assign(:user_detail, nil)}
  end

  # ── Permissions ───────────────────────────────────────────────────────────

  def handle_event("view_permissions", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:permissions, Admin.get_user_permissions(id)) |> assign(:page, :permissions)}
  end

  def handle_event("back_from_permissions", _, socket) do
    {:noreply, socket |> assign(:page, :users) |> assign(:permissions, nil)}
  end

  def handle_event("perm_action", %{"action" => action, "user_id" => uid}, socket) do
    result =
      case action do
        "revoke_tokens"   -> Admin.revoke_all_tokens(uid)   ; {:ok, "All API tokens revoked"}
        "revoke_sessions" -> Admin.revoke_all_sessions(uid) ; {:ok, "All sessions terminated"}
        "make_moderator"  -> Admin.set_moderator(uid, true)  |> ok_msg("Made moderator")
        "remove_moderator"-> Admin.set_moderator(uid, false) |> ok_msg("Moderator role removed")
        "block"           -> Admin.block_user(uid)           |> ok_msg("User blocked")
        "unblock"         -> Admin.unblock_user(uid)         |> ok_msg("User unblocked")
        _                 -> {:error, "Unknown action"}
      end

    {msg_type, msg} = case result do
      {:ok, m}    -> {:success, m}
      :ok         -> {:success, "Done"}
      {:error, e} -> {:error, inspect(e)}
    end

    socket =
      socket
      |> assign(:flash_msg, {msg_type, msg})
      |> assign(:stats, Admin.dashboard_stats())
      |> assign(:permissions, Admin.get_user_permissions(uid))

    {:noreply, socket}
  end

  defp ok_msg({:ok, _}, msg), do: {:ok, msg}
  defp ok_msg({:error, e}, _), do: {:error, e}

  # ── Confirm ───────────────────────────────────────────────────────────────

  def handle_event("confirm_action", %{"action" => action, "user_id" => uid, "label" => label}, socket) do
    {:noreply, assign(socket, :confirm_action, %{action: action, user_id: uid, label: label})}
  end

  def handle_event("cancel_confirm", _, socket) do
    {:noreply, assign(socket, :confirm_action, nil)}
  end

  def handle_event("execute_confirm", _, socket) do
    %{action: action, user_id: uid} = socket.assigns.confirm_action
    {result, msg} =
      case action do
        "block"       -> {Admin.block_user(uid),       "User blocked"}
        "unblock"     -> {Admin.unblock_user(uid),     "User unblocked"}
        "promote"     -> {Admin.promote_admin(uid),    "Promoted to admin"}
        "demote"      -> {Admin.demote_admin(uid),     "Admin role removed"}
        "soft_delete" -> {Admin.soft_delete_user(uid), "User soft deleted"}
        "hard_delete" -> {Admin.hard_delete_user(uid), "User permanently deleted"}
        _             -> {{:error, :unknown}, "Unknown"}
      end

    socket =
      case result do
        {:ok, _} ->
          Admin.log_audit("admin", action, uid)
          socket
          |> assign(:confirm_action, nil)
          |> assign(:flash_msg, {:success, msg})
          |> assign(:stats, Admin.dashboard_stats())
          |> assign(:audit_log, Admin.get_audit_log(20))
          |> then(fn s ->
            case s.assigns.page do
              :users       -> assign(s, :users, Admin.list_users(%{search: s.assigns.search, filter: s.assigns.user_filter, sort: s.assigns.user_sort}))
              :user_detail -> assign(s, :user_detail, Admin.get_user_detail(uid))
              _            -> s
            end
          end)
        {:error, r} ->
          socket |> assign(:confirm_action, nil) |> assign(:flash_msg, {:error, "Failed: #{inspect(r)}"})
      end

    {:noreply, socket}
  end

  # ── CAS Vault ─────────────────────────────────────────────────────────────

  def handle_event("filter_cas", %{"filter" => f}, socket) do
    cas = Admin.list_cas_objects(%{filter: f, search: socket.assigns.cas_search})
    {:noreply, socket |> assign(:cas_filter, f) |> assign(:cas_objects, cas)}
  end

  def handle_event("search_cas", %{"search" => q}, socket) do
    cas = Admin.list_cas_objects(%{filter: socket.assigns.cas_filter, search: q})
    {:noreply, socket |> assign(:cas_search, q) |> assign(:cas_objects, cas)}
  end

  def handle_event("cas_page", %{"page" => p}, socket) do
    cas = Admin.list_cas_objects(%{filter: socket.assigns.cas_filter, search: socket.assigns.cas_search, page: String.to_integer(p)})
    {:noreply, assign(socket, :cas_objects, cas)}
  end

  # ── SQL ───────────────────────────────────────────────────────────────────

  def handle_event("sql_input", %{"sql" => q}, socket) do
    {:noreply, socket |> assign(:sql_query, q) |> assign(:sql_error, nil)}
  end

  def handle_event("sql_input", _params, socket), do: {:noreply, socket}

  def handle_event("sql_run", _, socket) do
    {result, err} =
      case Admin.run_sql(socket.assigns.sql_query) do
        {:ok, data}      -> {data, nil}
        {:error, reason} -> {nil, reason}
      end
    {:noreply, socket |> assign(:sql_result, result) |> assign(:sql_error, err)}
  end

  def handle_event("sql_preset", %{"q" => q}, socket) do
    {:noreply, socket |> assign(:sql_query, q) |> assign(:sql_result, nil) |> assign(:sql_error, nil)}
  end

  def handle_event("sql_clear", _, socket) do
    {:noreply, socket |> assign(:sql_result, nil) |> assign(:sql_error, nil) |> assign(:sql_query, "")}
  end

  # ── S3 ────────────────────────────────────────────────────────────────────

  def handle_event("s3_browse", %{"prefix" => prefix}, socket) do
    {:noreply, load_s3(socket, prefix)}
  end

  def handle_event("s3_back", _, socket) do
    parts  = socket.assigns.s3_prefix |> String.trim_trailing("/") |> String.split("/")
    parent = parts |> Enum.drop(-1) |> Enum.join("/")
    prefix = if parent != "", do: parent <> "/", else: ""
    socket = if prefix == "", do: socket |> assign(:s3_result, nil) |> assign(:s3_prefix, ""), else: load_s3(socket, prefix)
    {:noreply, socket}
  end

  def handle_event("s3_presign", %{"key" => key}, socket) do
    case Admin.s3_presigned_url(key) do
      {:ok, url}  -> {:noreply, assign(socket, :s3_presigned, %{key: key, url: url})}
      {:error, r} -> {:noreply, assign(socket, :flash_msg, {:error, "Presign failed: #{inspect(r)}"})}
    end
  end

  def handle_event("s3_close_presign", _, socket), do: {:noreply, assign(socket, :s3_presigned, nil)}
  def handle_event("dismiss_flash", _, socket),    do: {:noreply, assign(socket, :flash_msg, nil)}

  defp load_s3(socket, prefix) do
    case Admin.list_s3_objects(prefix) do
      {:ok, data} -> socket |> assign(:s3_result, data) |> assign(:s3_prefix, prefix) |> assign(:s3_error, nil)
      {:error, r} -> socket |> assign(:s3_error, r)     |> assign(:s3_prefix, prefix)
    end
  end

  # ── Render ────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div id="adm" class={if @theme == :dark, do: "theme-dark", else: "theme-light"}>
      <%= raw(css()) %>
      <%= if @confirm_action, do: confirm_dialog(assigns) %>
      <%= if @flash_msg,      do: flash_toast(assigns) %>
      <%= if @s3_presigned,   do: presign_modal(assigns) %>

      <div class="al">
        <%= sidebar(assigns) %>
        <div class="am">
          <%= topbar(assigns) %>
          <div class="ac">
            <%= case @page do %>
              <% :dashboard   -> %> <%= dashboard_page(assigns) %>
              <% :users       -> %> <%= users_page(assigns) %>
              <% :user_detail -> %> <%= user_detail_page(assigns) %>
              <% :permissions -> %> <%= permissions_page(assigns) %>
              <% :monitoring  -> %> <%= monitoring_page(assigns) %>
              <% :vault       -> %> <%= vault_page(assigns) %>
              <% :duplicates  -> %> <%= duplicates_page(assigns) %>
              <% :sql         -> %> <%= sql_page(assigns) %>
              <% :s3          -> %> <%= s3_page(assigns) %>
              <% _            -> %> <%= dashboard_page(assigns) %>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Sidebar ───────────────────────────────────────────────────────────────

  defp sidebar(assigns) do
    ~H"""
    <aside class="sb">
      <div class="sb-top">
        <div class="sb-logo">
          <div class="lm">
            <svg width="14" height="14" viewBox="0 0 14 14" fill="none"><path d="M7 1L13 4V10L7 13L1 10V4L7 1Z" stroke="white" stroke-width="1.5" fill="none"/><circle cx="7" cy="7" r="2" fill="white"/></svg>
          </div>
          <span class="lt">PRZMA</span>
        </div>
        <div class="sb-sub">Control Plane</div>
      </div>

      <nav class="sb-nav">
        <div class="nsl">Platform</div>
        <.ni page={:dashboard}  cur={@page} ic="grid" lb="Dashboard" />
        <.ni page={:monitoring} cur={@page} ic="activity" lb="Monitoring" />

        <div class="nsl">Users</div>
        <.ni page={:users}       cur={@page} ic="users" lb="All Users"   bd={@stats.total_users} />
        <.ni page={:permissions} cur={@page} ic="shield" lb="Permissions" />

        <div class="nsl">Storage</div>
        <.ni page={:vault}      cur={@page} ic="database" lb="CAS Vault"  bd={@stats.total_cas} />
        <.ni page={:duplicates} cur={@page} ic="copy"     lb="Duplicates" bd={@stats.duplicate_cas} />
        <.ni page={:s3}         cur={@page} ic="cloud"    lb="S3 Browser" />

        <div class="nsl">Developer</div>
        <.ni page={:sql}        cur={@page} ic="terminal" lb="SQL Console" />
      </nav>

      <div class="sb-ft">
        <div class="ft-stat"><span class="ft-dot"></span><span><%= Admin.format_bytes(@stats.total_bytes) %> stored</span></div>
        <div class="ft-stat accent"><span class="ft-dot green"></span><span><%= Admin.format_bytes(@stats.saved_bytes) %> saved</span></div>
        <div class="ft-stat muted"><span class="ft-dot blue"></span><span><%= @stats.active_sessions %> sessions</span></div>
      </div>
    </aside>
    """
  end

  defp ni(assigns) do
    icons = %{
      "grid"     => ~s(<rect x="3" y="3" width="3.5" height="3.5" rx=".5"/><rect x="7.5" y="3" width="3.5" height="3.5" rx=".5"/><rect x="3" y="7.5" width="3.5" height="3.5" rx=".5"/><rect x="7.5" y="7.5" width="3.5" height="3.5" rx=".5"/>),
      "activity" => ~s(<polyline points="22 12 18 12 15 21 9 3 6 12 2 12"/>),
      "users"    => ~s(<path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/>),
      "shield"   => ~s(<path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/>),
      "database" => ~s(<ellipse cx="12" cy="5" rx="9" ry="3"/><path d="M21 12c0 1.66-4 3-9 3s-9-1.34-9-3"/><path d="M3 5v14c0 1.66 4 3 9 3s9-1.34 9-3V5"/>),
      "copy"     => ~s(<rect x="9" y="9" width="13" height="13" rx="2" ry="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>),
      "cloud"    => ~s(<path d="M18 10h-1.26A8 8 0 1 0 9 20h9a5 5 0 0 0 0-10z"/>),
      "terminal" => ~s(<polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/>),
    }
    svg = Map.get(icons, assigns.ic, "")
    assigns = assign(assigns, :svg, svg)
    ~H"""
    <button class={["ni", @page == @cur && "active"]} phx-click="nav" phx-value-page={@page}>
      <span class="ni-ic">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><%= raw(@svg) %></svg>
      </span>
      <span class="ni-lb"><%= @lb %></span>
      <%= if assigns[:bd] && assigns.bd > 0 do %><span class="ni-bd"><%= @bd %></span><% end %>
    </button>
    """
  end

  defp topbar(assigns) do
    t = %{dashboard: "Dashboard", users: "Users", user_detail: "User Profile",
          permissions: "Permissions", monitoring: "Monitoring",
          vault: "CAS Vault", duplicates: "Duplicates", sql: "SQL Console", s3: "S3 Browser"}
    ~H"""
    <header class="tb">
      <div class="tb-left">
        <div class="tb-t"><%= Map.get(t, @page, "Admin") %></div>
        <div class="tb-bc"><%= breadcrumb(@page) %></div>
      </div>
      <div class="tb-r">
        <div class="tb-chips">
          <span class="chip chip-users"><%= @stats.total_users %> users</span>
          <span class="chip chip-sessions"><%= @stats.active_sessions %> sessions</span>
          <span class="chip chip-brand">PRZMA</span>
        </div>
        <button class="theme-btn" phx-click="toggle_theme" title="Toggle theme">
          <%= if @theme == :dark do %>
            <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="5"/><line x1="12" y1="1" x2="12" y2="3"/><line x1="12" y1="21" x2="12" y2="23"/><line x1="4.22" y1="4.22" x2="5.64" y2="5.64"/><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"/><line x1="1" y1="12" x2="3" y2="12"/><line x1="21" y1="12" x2="23" y2="12"/><line x1="4.22" y1="19.78" x2="5.64" y2="18.36"/><line x1="18.36" y1="5.64" x2="19.78" y2="4.22"/></svg>
          <% else %>
            <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/></svg>
          <% end %>
        </button>
        <a href="/admin/logout" class="logout-btn">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><polyline points="16 17 21 12 16 7"/><line x1="21" y1="12" x2="9" y2="12"/></svg>
          Logout
        </a>
      </div>
    </header>
    """
  end

  defp breadcrumb(:dashboard),   do: "Overview → Dashboard"
  defp breadcrumb(:users),       do: "Users → All Users"
  defp breadcrumb(:user_detail), do: "Users → Profile"
  defp breadcrumb(:permissions), do: "Users → Permissions"
  defp breadcrumb(:monitoring),  do: "Platform → Monitoring"
  defp breadcrumb(:vault),       do: "Storage → CAS Vault"
  defp breadcrumb(:duplicates),  do: "Storage → Duplicates"
  defp breadcrumb(:s3),          do: "Storage → S3 Browser"
  defp breadcrumb(:sql),         do: "Developer → SQL Console"
  defp breadcrumb(_),            do: ""

  # ── Dashboard ─────────────────────────────────────────────────────────────

  defp dashboard_page(assigns) do
    ~H"""
    <div class="dash">
      <!-- Stat Cards -->
      <div class="sg">
        <.sc lb="Total Users"   v={@stats.total_users}     ic="users"    cl="blue" />
        <.sc lb="Verified"      v={@stats.verified_users}  ic="check"    cl="green" />
        <.sc lb="Blocked"       v={@stats.blocked_users}   ic="ban"      cl="red" />
        <.sc lb="Admins"        v={@stats.admin_users}     ic="star"     cl="amber" />
        <.sc lb="Total Files"   v={@stats.total_files}     ic="file"     cl="purple" />
        <.sc lb="CAS Objects"   v={@stats.total_cas}       ic="db"       cl="blue" />
        <.sc lb="Sessions"      v={@stats.active_sessions} ic="zap"      cl="green" />
        <.sc lb="New This Week" v={@stats.new_this_week}   ic="trending" cl="amber" />
      </div>

      <div class="dash-grid">
        <!-- Storage Health -->
        <div class="card">
          <div class="card-head"><span class="card-title">Storage Health</span></div>
          <div class="card-body">
            <.storage_bar label="Total Stored"    value={@stats.total_bytes}  max={@stats.total_bytes}  color="blue"  fmt={Admin.format_bytes(@stats.total_bytes)} />
            <.storage_bar label="Dedup Savings"   value={@stats.saved_bytes}  max={@stats.total_bytes}  color="green" fmt={Admin.format_bytes(@stats.saved_bytes)} />
            <.storage_bar label="Duplicate Files" value={@stats.duplicate_cas} max={@stats.total_cas}   color="red"   fmt={"#{@stats.duplicate_cas} objects"} />

            <div class="divider"></div>
            <div class="data-plane-title">Data Plane</div>
            <div class="kv-row"><span>Documents</span><strong><%= @stats.total_files %></strong></div>
            <div class="kv-row"><span>CAS Objects</span><strong><%= @stats.total_cas %></strong></div>
            <div class="kv-row"><span>Active Sessions</span><strong><%= @stats.active_sessions %></strong></div>
            <div class="kv-row"><span>OAuth Tokens</span><strong><%= @stats.active_tokens %></strong></div>
          </div>
        </div>

        <!-- Services -->
        <div class="card">
          <div class="card-head"><span class="card-title">Services</span></div>
          <div class="card-body">
            <.svc_row name="PostgreSQL"          status="online" />
            <.svc_row name="Linode S3 (in-maa-1)" status="online" />
            <.svc_row name="Horde Registry"     status="online" />
            <.svc_row name="CAS Engine"         status="online" />
            <div class="svc-tokens">
              <div class="svc-dot blue"></div>
              <span>OAuth Tokens</span>
              <span class="token-badge"><%= @stats.active_tokens %> active</span>
            </div>

            <div class="divider"></div>
            <div class="card-title" style="margin-bottom:10px">Quick Actions</div>
            <div class="quick-grid">
              <button class="quick-btn" phx-click="nav" phx-value-page="users">
                <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/></svg>
                Users
              </button>
              <button class="quick-btn" phx-click="nav" phx-value-page="monitoring">
                <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="22 12 18 12 15 21 9 3 6 12 2 12"/></svg>
                Monitor
              </button>
              <button class="quick-btn" phx-click="nav" phx-value-page="vault">
                <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><ellipse cx="12" cy="5" rx="9" ry="3"/><path d="M21 12c0 1.66-4 3-9 3s-9-1.34-9-3"/><path d="M3 5v14c0 1.66 4 3 9 3s9-1.34 9-3V5"/></svg>
                CAS Vault
              </button>
              <button class="quick-btn" phx-click="nav" phx-value-page="sql">
                <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>
                SQL
              </button>
            </div>
          </div>
        </div>

        <!-- Audit Log -->
        <div class="card">
          <div class="card-head"><span class="card-title">Audit Log</span><span class="card-meta">Recent actions</span></div>
          <div class="card-body" style="padding:0">
            <%= if @audit_log == [] do %>
              <div class="empty-state" style="padding:28px">No admin actions yet</div>
            <% end %>
            <%= for entry <- Enum.take(@audit_log, 10) do %>
              <div class="audit-row">
                <div class="audit-dot"></div>
                <div class="audit-info">
                  <span class="audit-action"><%= entry.action %></span>
                  <%= if entry.target do %><span class="audit-target"><%= String.slice(entry.target, 0, 10) %>…</span><% end %>
                </div>
                <span class="audit-time"><%= Calendar.strftime(entry.at, "%H:%M:%S") %></span>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp storage_bar(assigns) do
    b = to_int_safe(assigns.value)
    m = max(to_int_safe(assigns.max), 1)
    pct = if m > 0, do: min(100, round(b/m*100)), else: 0
    assigns = assign(assigns, :pct, pct)
    ~H"""
    <div class="storage-row">
      <span class="storage-label"><%= @label %></span>
      <div class="storage-bar-wrap">
        <div class="storage-bar-track">
          <div class={"storage-bar-fill #{@color}"} style={"width:#{@pct}%"}></div>
        </div>
      </div>
      <span class="storage-val"><%= @fmt %></span>
    </div>
    """
  end

  defp svc_row(assigns) do
    ~H"""
    <div class="svc-row">
      <div class="svc-dot green"></div>
      <span><%= @name %></span>
      <span class="svc-badge online">Online</span>
    </div>
    """
  end

  defp compute_pct(val, max) do
    b = to_int_safe(val)
    m = max(to_int_safe(max), 1)
    if m > 0, do: min(100, round(b/m*100)), else: 0
  end

  defp to_int_safe(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_int_safe(i) when is_integer(i), do: i
  defp to_int_safe(_), do: 0

  defp sc(assigns) do
    icon_svg = case assigns.ic do
      "users"    -> ~s(<path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/>)
      "check"    -> ~s(<polyline points="20 6 9 17 4 12"/>)
      "ban"      -> ~s(<circle cx="12" cy="12" r="10"/><line x1="4.93" y1="4.93" x2="19.07" y2="19.07"/>)
      "star"     -> ~s(<polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2"/>)
      "file"     -> ~s(<path d="M13 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"/><polyline points="13 2 13 9 20 9"/>)
      "db"       -> ~s(<ellipse cx="12" cy="5" rx="9" ry="3"/><path d="M21 12c0 1.66-4 3-9 3s-9-1.34-9-3"/><path d="M3 5v14c0 1.66 4 3 9 3s9-1.34 9-3V5"/>)
      "zap"      -> ~s(<polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"/>)
      "trending" -> ~s(<polyline points="23 6 13.5 15.5 8.5 10.5 1 18"/><polyline points="17 6 23 6 23 12"/>)
      _          -> ~s(<circle cx="12" cy="12" r="4"/>)
    end
    assigns = assign(assigns, :icon_svg, icon_svg)
    ~H"""
    <div class={"sc sc-#{@cl}"}>
      <div class="sc-ic">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><%= raw(@icon_svg) %></svg>
      </div>
      <div class="sc-body">
        <div class="sc-v"><%= @v %></div>
        <div class="sc-l"><%= @lb %></div>
      </div>
    </div>
    """
  end

  # ── Users Page ────────────────────────────────────────────────────────────

  defp users_page(assigns) do
    ~H"""
    <div>
      <div class="toolbar">
        <div class="search-box">
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/></svg>
          <input class="search-input" placeholder="Search users…" value={@search} phx-keyup="search_users" phx-debounce="300" name="search" phx-value-search={@search}/>
        </div>
        <div class="filter-pills">
          <%= for {v,l} <- [{"all","All"},{"active","Active"},{"blocked","Blocked"},{"verified","Verified"},{"unverified","Unverified"},{"admin","Admins"},{"moderator","Mods"}] do %>
            <button class={["pill", @user_filter == v && "active"]} phx-click="filter_users" phx-value-filter={v}><%= l %></button>
          <% end %>
        </div>
        <select class="select-box" phx-change="sort_users" name="sort">
          <%= for {v,l} <- [{"newest","Newest"},{"oldest","Oldest"},{"files_desc","Most Files"},{"name_asc","Name A→Z"}] do %>
            <option value={v} selected={@user_sort == v}><%= l %></option>
          <% end %>
        </select>
      </div>

      <div class="table-wrap">
        <table class="data-table">
          <thead>
            <tr>
              <th>User</th><th>Email</th><th>Status</th><th>Files</th><th>Joined</th><th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <%= for u <- @users.users do %>
              <tr class="data-row" phx-click="view_user" phx-value-id={u.id} style="cursor:pointer">
                <td>
                  <div class="user-cell">
                    <div class="user-avatar"><%= String.first(u.nickname || "?") |> String.upcase() %></div>
                    <div>
                      <div class="user-name"><%= u.nickname %></div>
                      <div class="user-id mono"><%= String.slice(u.id, 0, 10) %>…</div>
                    </div>
                  </div>
                </td>
                <td class="cell-sm mono"><%= u.email %></td>
                <td><div class="badge-row"><.user_badges u={u}/></div></td>
                <td class="cell-num"><%= u.file_count %></td>
                <td class="cell-sm"><%= fd(u.inserted_at) %></td>
                <td>
                  <div class="action-btns" phx-click="" style="pointer-events:all">
                    <button class="btn-sm" phx-click="view_user" phx-value-id={u.id}>Profile</button>
                    <button class="btn-sm accent" phx-click="view_permissions" phx-value-id={u.id}>Perms</button>
                  </div>
                </td>
              </tr>
            <% end %>
            <%= if @users.users == [] do %>
              <tr><td colspan="6" class="empty-row">No users found</td></tr>
            <% end %>
          </tbody>
        </table>
      </div>
      <.pagination d={@users} e="user_page"/>
    </div>
    """
  end

  defp user_badges(assigns) do
    ~H"""
    <%= if !@u.is_active do %><span class="badge red">Blocked</span><% else %><span class="badge green">Active</span><% end %>
    <%= if @u.is_verified do %><span class="badge blue">Verified</span><% else %><span class="badge gray">Unverified</span><% end %>
    <%= if @u.is_admin do %><span class="badge amber">Admin</span><% end %>
    <%= if Map.get(@u, :is_moderator) do %><span class="badge purple">Mod</span><% end %>
    """
  end

  # ── User Detail ───────────────────────────────────────────────────────────

  defp user_detail_page(%{user_detail: nil} = assigns), do: ~H"<div class='empty-state'>User not found</div>"
  defp user_detail_page(assigns) do
    ~H"""
    <div>
      <button class="back-btn" phx-click="back_to_users">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="19" y1="12" x2="5" y2="12"/><polyline points="12 19 5 12 12 5"/></svg>
        Back to Users
      </button>

      <div class="profile-card">
        <div class="profile-avatar-lg"><%= String.first(@user_detail.user.nickname || "?") |> String.upcase() %></div>
        <div class="profile-info">
          <div class="profile-name"><%= @user_detail.user.nickname %></div>
          <div class="profile-email"><%= @user_detail.user.email %></div>
          <div class="profile-id mono"><%= @user_detail.user.id %></div>
          <div class="badge-row"><.user_badges u={@user_detail.user}/></div>
        </div>
        <div class="profile-actions">
          <button class="action-btn purple" phx-click="view_permissions" phx-value-id={@user_detail.user.id}>🔐 Permissions</button>
          <%= if @user_detail.user.is_active do %>
            <button class="action-btn red" phx-click="confirm_action" phx-value-action="block" phx-value-user_id={@user_detail.user.id} phx-value-label={"Block #{@user_detail.user.nickname}?"}>Block</button>
          <% else %>
            <button class="action-btn green" phx-click="confirm_action" phx-value-action="unblock" phx-value-user_id={@user_detail.user.id} phx-value-label={"Unblock #{@user_detail.user.nickname}?"}>Unblock</button>
          <% end %>
          <%= if @user_detail.user.is_admin do %>
            <button class="action-btn gray" phx-click="confirm_action" phx-value-action="demote" phx-value-user_id={@user_detail.user.id} phx-value-label={"Remove admin from #{@user_detail.user.nickname}?"}>Remove Admin</button>
          <% else %>
            <button class="action-btn amber" phx-click="confirm_action" phx-value-action="promote" phx-value-user_id={@user_detail.user.id} phx-value-label={"Make #{@user_detail.user.nickname} admin?"}>Make Admin</button>
          <% end %>
          <button class="action-btn orange" phx-click="confirm_action" phx-value-action="soft_delete" phx-value-user_id={@user_detail.user.id} phx-value-label={"Soft delete #{@user_detail.user.nickname}?"}>Soft Delete</button>
          <button class="action-btn red" phx-click="confirm_action" phx-value-action="hard_delete" phx-value-user_id={@user_detail.user.id} phx-value-label={"PERMANENTLY delete #{@user_detail.user.nickname}?"}>Hard Delete ⚠</button>
        </div>
      </div>

      <div class="stat-strip">
        <div class="strip-stat"><div class="strip-val"><%= @user_detail.file_count %></div><div class="strip-lbl">Files</div></div>
        <div class="strip-stat"><div class="strip-val"><%= Admin.format_bytes(@user_detail.storage_bytes) %></div><div class="strip-lbl">Storage</div></div>
        <div class="strip-stat"><div class="strip-val"><%= length(@user_detail.duplicates) %></div><div class="strip-lbl">Duplicates</div></div>
        <div class="strip-stat"><div class="strip-val"><%= length(@user_detail.sessions) %></div><div class="strip-lbl">Sessions</div></div>
        <div class="strip-stat"><div class="strip-val"><%= length(@user_detail.tokens) %></div><div class="strip-lbl">API Tokens</div></div>
        <div class="strip-stat"><div class="strip-val"><%= fd(@user_detail.user.inserted_at) %></div><div class="strip-lbl">Joined</div></div>
      </div>

      <div class="three-col">
        <div class="card">
          <div class="card-head"><span class="card-title">Files (<%= @user_detail.file_count %>)</span></div>
          <div class="scroll-list">
            <%= for f <- Enum.take(@user_detail.files, 50) do %>
              <div class="list-row">
                <span class="file-icon"><%= ctic(f.content_type) %></span>
                <div>
                  <div class="row-name"><%= f.filename %></div>
                  <div class="row-meta"><%= f.status %> · <%= fd(f.inserted_at) %></div>
                </div>
              </div>
            <% end %>
            <%= if @user_detail.file_count == 0 do %><div class="empty-state">No files</div><% end %>
          </div>
        </div>

        <div class="card">
          <div class="card-head"><span class="card-title">Sessions</span></div>
          <div class="scroll-list">
            <%= for s <- @user_detail.sessions do %>
              <div class="list-row" style="flex-direction:column;align-items:flex-start;gap:2px">
                <div class="row-name mono" style="font-size:10px"><%= s.ip_address %> · <%= s.device %></div>
                <div class="row-meta">Last: <%= fd(s.last_active_at) %><%= if s.revoked_at, do: " · REVOKED", else: "" %></div>
              </div>
            <% end %>
            <%= if @user_detail.sessions == [] do %><div class="empty-state">No sessions</div><% end %>
          </div>
        </div>

        <div>
          <div class="card" style="margin-bottom:12px">
            <div class="card-head"><span class="card-title">Identity</span></div>
            <div class="card-body" style="padding:0">
              <%= if @user_detail.user.did_id do %>
                <div class="did-block mono"><%= @user_detail.user.did_id %></div>
                <%= if @user_detail.namespace do %>
                  <div class="kv-row"><span>Namespace</span><span class="mono"><%= @user_detail.namespace.id %></span></div>
                  <div class="kv-row"><span>Status</span><span><%= @user_detail.namespace.status %></span></div>
                <% end %>
              <% else %>
                <div class="empty-state">No DID</div>
              <% end %>
            </div>
          </div>
          <div class="card">
            <div class="card-head"><span class="card-title">File Types</span></div>
            <div class="card-body" style="padding:0">
              <%= for {ct, cnt} <- @user_detail.type_breakdown do %>
                <div class="kv-row"><span><%= ctic(ct) %> <%= sct(ct) %></span><span class="cell-num"><%= cnt %></span></div>
              <% end %>
              <%= if @user_detail.type_breakdown == %{} do %><div class="empty-state">No files</div><% end %>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Permissions ───────────────────────────────────────────────────────────

  defp permissions_page(%{permissions: nil} = assigns) do
    ~H"""
    <div>
      <button class="back-btn" phx-click="back_from_permissions">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="19" y1="12" x2="5" y2="12"/><polyline points="12 19 5 12 12 5"/></svg>
        Back to Users
      </button>
      <div class="empty-state" style="margin-bottom:20px">Select a user to manage permissions</div>
      <div class="table-wrap">
        <table class="data-table">
          <thead><tr><th>User</th><th>Email</th><th>Status</th><th>Actions</th></tr></thead>
          <tbody>
            <%= for u <- @users.users do %>
              <tr class="data-row">
                <td><div class="user-cell"><div class="user-avatar"><%= String.first(u.nickname || "?") |> String.upcase() %></div><div class="user-name"><%= u.nickname %></div></div></td>
                <td class="cell-sm mono"><%= u.email %></td>
                <td><div class="badge-row"><.user_badges u={u}/></div></td>
                <td><button class="btn-sm accent" phx-click="view_permissions" phx-value-id={u.id}>Manage</button></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp permissions_page(assigns) do
    p = assigns.permissions
    u = p.user
    assigns = assign(assigns, :p, p) |> assign(:u, u)
    ~H"""
    <div>
      <button class="back-btn" phx-click="back_from_permissions">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="19" y1="12" x2="5" y2="12"/><polyline points="12 19 5 12 12 5"/></svg>
        Back
      </button>

      <div class="profile-card" style="margin-bottom:16px">
        <div class="profile-avatar-lg"><%= String.first(@u.nickname || "?") |> String.upcase() %></div>
        <div class="profile-info">
          <div class="profile-name"><%= @u.nickname %></div>
          <div class="profile-email"><%= @u.email %></div>
          <div class="profile-id mono"><%= @u.id %></div>
          <div class="badge-row"><.user_badges u={@u}/></div>
        </div>
      </div>

      <div class="perm-grid">
        <div class="card">
          <div class="card-head"><span class="card-title">🔐 Access Control</span></div>
          <div class="card-body" style="padding:0">
            <div class="perm-row">
              <div><div class="perm-name">Account Active</div><div class="perm-desc">User can log in and use the platform</div></div>
              <div class="perm-ctrl">
                <span class={"perm-badge #{if @p.can_login, do: "on", else: "off"}"}><%= if @p.can_login, do: "ENABLED", else: "DISABLED" %></span>
                <%= if @p.can_login do %><button class="perm-btn red" phx-click="perm_action" phx-value-action="block" phx-value-user_id={@u.id}>Block</button>
                <% else %><button class="perm-btn green" phx-click="perm_action" phx-value-action="unblock" phx-value-user_id={@u.id}>Unblock</button><% end %>
              </div>
            </div>
            <div class="perm-row">
              <div><div class="perm-name">Email Verified</div><div class="perm-desc">Email address has been confirmed</div></div>
              <span class={"perm-badge #{if @p.is_verified, do: "on", else: "off"}"}><%= if @p.is_verified, do: "VERIFIED", else: "UNVERIFIED" %></span>
            </div>
            <div class="perm-row">
              <div><div class="perm-name">Admin Role</div><div class="perm-desc">Full platform administration access</div></div>
              <div class="perm-ctrl">
                <span class={"perm-badge #{if @p.is_admin, do: "on", else: "off"}"}><%= if @p.is_admin, do: "ADMIN", else: "USER" %></span>
                <%= if @p.is_admin do %><button class="perm-btn gray" phx-click="confirm_action" phx-value-action="demote" phx-value-user_id={@u.id} phx-value-label={"Remove admin from #{@u.nickname}?"}>Remove</button>
                <% else %><button class="perm-btn amber" phx-click="confirm_action" phx-value-action="promote" phx-value-user_id={@u.id} phx-value-label={"Make #{@u.nickname} an admin?"}>Grant</button><% end %>
              </div>
            </div>
            <div class="perm-row">
              <div><div class="perm-name">Moderator Role</div><div class="perm-desc">Content moderation privileges</div></div>
              <div class="perm-ctrl">
                <span class={"perm-badge #{if @p.is_admin || @u.is_moderator, do: "on", else: "off"}"}><%= if @p.is_admin || @u.is_moderator, do: "ENABLED", else: "NONE" %></span>
                <%= if @u.is_moderator do %><button class="perm-btn gray" phx-click="perm_action" phx-value-action="remove_moderator" phx-value-user_id={@u.id}>Revoke</button>
                <% else %><button class="perm-btn purple" phx-click="perm_action" phx-value-action="make_moderator" phx-value-user_id={@u.id}>Grant</button><% end %>
              </div>
            </div>
          </div>
        </div>

        <div class="card">
          <div class="card-head"><span class="card-title">🔑 API & Sessions</span></div>
          <div class="card-body" style="padding:0">
            <div class="perm-row">
              <div><div class="perm-name">Active API Tokens</div><div class="perm-desc">OAuth tokens granting API access</div></div>
              <div class="perm-ctrl">
                <span class={"perm-badge #{if @p.active_tokens > 0, do: "on", else: "off"}"}><%= @p.active_tokens %> active</span>
                <%= if @p.active_tokens > 0 do %><button class="perm-btn red" phx-click="perm_action" phx-value-action="revoke_tokens" phx-value-user_id={@u.id}>Revoke All</button><% end %>
              </div>
            </div>
            <div class="perm-row">
              <div><div class="perm-name">Active Sessions</div><div class="perm-desc">Browser/device sessions currently active</div></div>
              <div class="perm-ctrl">
                <span class={"perm-badge #{if @p.active_sessions > 0, do: "on", else: "off"}"}><%= @p.active_sessions %> active</span>
                <%= if @p.active_sessions > 0 do %><button class="perm-btn red" phx-click="perm_action" phx-value-action="revoke_sessions" phx-value-user_id={@u.id}>Kill All</button><% end %>
              </div>
            </div>
          </div>
        </div>

        <div class="card">
          <div class="card-head"><span class="card-title">🌐 Identity</span></div>
          <div class="card-body" style="padding:0">
            <div class="perm-row">
              <div><div class="perm-name">Decentralized ID</div><div class="perm-desc mono" style="font-size:10px"><%= @u.did_id || "Not assigned" %></div></div>
              <span class={"perm-badge #{if @u.did_id, do: "on", else: "off"}"}><%= if @u.did_id, do: "ASSIGNED", else: "NONE" %></span>
            </div>
            <div class="perm-row">
              <div><div class="perm-name">API Access</div><div class="perm-desc">Can authenticate via OAuth2</div></div>
              <span class={"perm-badge #{if @p.api_access, do: "on", else: "off"}"}><%= if @p.api_access, do: "GRANTED", else: "NO TOKENS" %></span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Monitoring Page ───────────────────────────────────────────────────────

  defp monitoring_page(%{monitoring: nil} = assigns), do: ~H"<div class='empty-state'>Loading monitoring data…</div>"
  defp monitoring_page(assigns) do
    ~H"""
    <div>
      <div class="card" style="margin-bottom:16px">
        <div class="card-head"><span class="card-title">Storage by File Type</span></div>
        <div class="card-body">
          <%= for t <- Enum.take(@monitoring.storage_by_type, 8) do %>
            <.storage_bar label={"#{ctic(t.type)} #{sct(t.type)}"} value={t.bytes} max={@stats.total_bytes} color="blue" fmt={Admin.format_bytes(t.bytes)} />
          <% end %>
          <%= if @monitoring.storage_by_type == [] do %><div class="empty-state">No data yet</div><% end %>
        </div>
      </div>

      <div class="table-wrap">
        <table class="data-table">
          <thead><tr><th>User</th><th>Status</th><th>Files</th><th>Storage</th><th>Sessions</th><th>Last Active</th><th>Joined</th><th></th></tr></thead>
          <tbody>
            <%= for u <- @monitoring.users do %>
              <tr class="data-row">
                <td>
                  <div class="user-cell">
                    <div class="user-avatar"><%= String.first(u.nickname || "?") |> String.upcase() %></div>
                    <div><div class="user-name"><%= u.nickname %></div><div class="user-id mono"><%= String.slice(u.user_id, 0, 8) %>…</div></div>
                  </div>
                </td>
                <td>
                  <div class="badge-row">
                    <%= if u.is_active do %><span class="badge green">Active</span><% else %><span class="badge red">Blocked</span><% end %>
                    <%= if u.is_verified do %><span class="badge blue">Verified</span><% end %>
                  </div>
                </td>
                <td class="cell-num"><%= u.file_count %></td>
                <td class="cell-num"><%= Admin.format_bytes(u.storage_bytes) %></td>
                <td class="cell-num"><%= Map.get(u, :sessions, 0) %></td>
                <td class="cell-sm"><%= fd(Map.get(u, :last_active)) %></td>
                <td class="cell-sm"><%= fd(u.joined) %></td>
                <td>
                  <div class="action-btns">
                    <button class="btn-sm" phx-click="view_user" phx-value-id={u.user_id}>Profile</button>
                    <button class="btn-sm accent" phx-click="view_permissions" phx-value-id={u.user_id}>Perms</button>
                  </div>
                </td>
              </tr>
            <% end %>
            <%= if @monitoring.users == [] do %><tr><td colspan="8" class="empty-row">No users yet</td></tr><% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  # ── Vault Page ────────────────────────────────────────────────────────────

  defp vault_page(assigns) do
    ~H"""
    <div class="vault-layout">
      <div class="vault-sidebar">
        <div class="card-head"><span class="card-title">Namespaces</span></div>
        <button class="vault-all-btn" phx-click="filter_cas" phx-value-filter="all">◈ All Objects</button>
        <%= for ns <- @s3_tree do %>
          <div class="vault-ns">
            <div class="mono cell-sm"><%= String.slice(ns.namespace_key || "—", 0, 14) %></div>
            <div class="row-meta"><%= ns.file_count %> · <%= Admin.format_bytes(ns.total_bytes) %></div>
          </div>
        <% end %>
      </div>
      <div>
        <div class="toolbar" style="margin-bottom:12px">
          <div class="search-box">
            <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/></svg>
            <input class="search-input" placeholder="Hash, path, type…" phx-keyup="search_cas" phx-debounce="300" name="search" phx-value-search={@cas_search} value={@cas_search}/>
          </div>
          <div class="filter-pills">
            <%= for {v,l} <- [{"all","All"},{"duplicates","Dupes"},{"large",">10MB"},{"images","Images"},{"docs","Docs"}] do %>
              <button class={["pill", @cas_filter == v && "active"]} phx-click="filter_cas" phx-value-filter={v}><%= l %></button>
            <% end %>
          </div>
        </div>
        <div class="table-wrap">
          <table class="data-table">
            <thead><tr><th>Hash</th><th>Type</th><th>Size</th><th>Refs</th><th>Namespace</th><th>Stored</th></tr></thead>
            <tbody>
              <%= for obj <- @cas_objects.items do %>
                <tr class="data-row">
                  <td class="mono cell-sm"><%= String.slice(obj.content_hash, 0, 16) %>…</td>
                  <td><%= ctic(obj.media_type) %> <%= sct(obj.media_type) %></td>
                  <td class="cell-num"><%= Admin.format_bytes(obj.file_size) %></td>
                  <td><span class={"ref-badge #{if obj.ref_count > 1, do: "dup", else: ""}"}><%= obj.ref_count %></span></td>
                  <td class="mono cell-sm"><%= String.slice(obj.namespace_key || "—", 0, 12) %></td>
                  <td class="cell-sm"><%= fd(obj.inserted_at) %></td>
                </tr>
              <% end %>
              <%= if @cas_objects.items == [] do %><tr><td colspan="6" class="empty-row">No objects</td></tr><% end %>
            </tbody>
          </table>
        </div>
        <.pagination d={@cas_objects} e="cas_page"/>
      </div>
    </div>
    """
  end

  # ── Duplicates Page ───────────────────────────────────────────────────────

  defp duplicates_page(assigns) do
    ~H"""
    <div>
      <div class="stat-strip" style="margin-bottom:16px">
        <div class="strip-stat"><div class="strip-val"><%= length(@duplicates.duplicates) %></div><div class="strip-lbl">Duplicate Objects</div></div>
        <div class="strip-stat green"><div class="strip-val"><%= Admin.format_bytes(@duplicates.total_wasted) %></div><div class="strip-lbl">Saved by Dedup</div></div>
      </div>
      <div class="table-wrap">
        <table class="data-table">
          <thead><tr><th>Hash</th><th>Type</th><th>Size</th><th>Refs</th><th>Saved</th><th>Namespace</th></tr></thead>
          <tbody>
            <%= for obj <- @duplicates.duplicates do %>
              <tr class="data-row">
                <td class="mono cell-sm"><%= String.slice(obj.content_hash, 0, 20) %>…</td>
                <td><%= ctic(obj.media_type) %> <%= sct(obj.media_type) %></td>
                <td class="cell-num"><%= Admin.format_bytes(obj.file_size) %></td>
                <td><span class="ref-badge dup"><%= obj.ref_count %>×</span></td>
                <td class="cell-num" style="color:var(--clr-green)"><%= Admin.format_bytes(obj.file_size * (obj.ref_count - 1)) %></td>
                <td class="mono cell-sm"><%= String.slice(obj.namespace_key || "—", 0, 12) %></td>
              </tr>
            <% end %>
            <%= if @duplicates.duplicates == [] do %><tr><td colspan="6" class="empty-row">No duplicates — CAS is clean! ✓</td></tr><% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  # ── SQL Console ───────────────────────────────────────────────────────────

  @presets [
    {"All users",           "SELECT id, nickname, email, is_verified, is_active, is_admin, inserted_at\nFROM users ORDER BY inserted_at DESC LIMIT 20;"},
    {"Files per user",      "SELECT u.nickname, COUNT(d.id) AS files, MAX(d.inserted_at) AS last_upload\nFROM users u LEFT JOIN documents d ON d.user_id = u.id\nGROUP BY u.id, u.nickname ORDER BY files DESC;"},
    {"Storage by type",     "SELECT media_type, COUNT(*) AS count, SUM(file_size) AS bytes\nFROM cas_objects GROUP BY media_type ORDER BY bytes DESC;"},
    {"Duplicates",          "SELECT content_hash, media_type, file_size, ref_count,\n       file_size*(ref_count-1) AS saved\nFROM cas_objects WHERE ref_count>1 ORDER BY ref_count DESC LIMIT 50;"},
    {"Active sessions",     "SELECT s.id, u.nickname, s.ip_address, s.device, s.last_active_at\nFROM sessions s JOIN users u ON u.id=s.user_id\nWHERE s.revoked_at IS NULL ORDER BY s.last_active_at DESC LIMIT 30;"},
    {"Active tokens",       "SELECT t.id, u.nickname, t.scopes, t.valid_until\nFROM oauth_tokens t JOIN users u ON u.id=t.user_id\nWHERE t.revoked_at IS NULL AND t.valid_until>NOW()\nORDER BY t.valid_until DESC LIMIT 20;"},
    {"Namespace stats",     "SELECT id, status, document_count, storage_bytes, last_activity_at\nFROM namespaces ORDER BY storage_bytes DESC;"},
    {"Unverified users",    "SELECT id, nickname, email, inserted_at\nFROM users WHERE is_verified=false ORDER BY inserted_at DESC;"},
    {"Blocked users",       "SELECT id, nickname, email, inserted_at FROM users WHERE is_active=false;"},
    {"CAS today",           "SELECT content_hash, media_type, file_size, ref_count, inserted_at\nFROM cas_objects WHERE inserted_at::date=CURRENT_DATE ORDER BY inserted_at DESC;"},
    {"Large files",         "SELECT storage_key, media_type, file_size, ref_count\nFROM cas_objects ORDER BY file_size DESC LIMIT 25;"},
    {"User storage totals", "SELECT u.nickname, u.email, COUNT(d.id) AS files, COALESCE(SUM(c.file_size),0) AS bytes\nFROM users u\nLEFT JOIN documents d ON d.user_id=u.id\nLEFT JOIN cas_objects c ON c.content_hash=d.content_hash\nGROUP BY u.id, u.nickname, u.email\nORDER BY bytes DESC;"},
  ]

  defp sql_page(assigns) do
    assigns = assign(assigns, :presets, @presets)
    ~H"""
    <div class="sql-layout">
      <div class="sql-left">
        <div class="card" style="margin-bottom:12px">
          <div class="card-head"><span class="card-title">Quick Queries</span></div>
          <div style="padding:0">
            <%= for {label, q} <- @presets do %>
              <button class="preset-btn" phx-click="sql_preset" phx-value-q={q}><%= label %></button>
            <% end %>
          </div>
        </div>
        <div class="card">
          <div class="card-head">
            <span class="card-title">SQL Editor</span>
            <span class="card-meta">SELECT only</span>
          </div>
          <textarea class="sql-editor" phx-change="sql_input" phx-debounce="80" name="sql" rows="9" placeholder="SELECT ..."><%= @sql_query %></textarea>
          <div class="sql-toolbar">
            <button class="btn-run" phx-click="sql_run">▶ Run Query</button>
            <button class="btn-clear" phx-click="sql_clear">✕ Clear</button>
            <span class="sql-hint">SELECT only · 10s timeout</span>
          </div>
        </div>
      </div>
      <div class="sql-right">
        <%= if @sql_error do %>
          <div class="error-block">
            <div class="error-title">⚠ Error</div>
            <pre class="error-body"><%= @sql_error %></pre>
          </div>
        <% end %>
        <%= if @sql_result do %>
          <div class="card">
            <div class="card-head">
              <span class="card-title">Result</span>
              <span class="card-meta"><strong><%= @sql_result.count %></strong> rows</span>
            </div>
            <div class="sql-scroll">
              <table class="data-table">
                <thead><tr><%= for col <- @sql_result.columns do %><th><%= col %></th><% end %></tr></thead>
                <tbody>
                  <%= for row <- @sql_result.rows do %>
                    <tr class="data-row"><%= for cell <- row do %><td class="sql-cell"><%= fmt_cell(cell) %></td><% end %></tr>
                  <% end %>
                  <%= if @sql_result.rows == [] do %><tr><td colspan={length(@sql_result.columns)} class="empty-row">0 rows returned</td></tr><% end %>
                </tbody>
              </table>
            </div>
          </div>
        <% end %>
        <%= if !@sql_result && !@sql_error do %>
          <div class="sql-placeholder">
            <svg width="40" height="40" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1" opacity=".3"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>
            <div style="margin-top:12px">Pick a preset or write a query</div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # ── S3 Browser ────────────────────────────────────────────────────────────

  defp s3_page(assigns) do
    ~H"""
    <div>
      <%= if @s3_prefix == "" do %>
        <div class="section-label" style="margin-bottom:16px">Scoped to platform storage paths</div>
        <div class="s3-root-grid">
          <%= for root <- @s3_roots do %>
            <button class="s3-card" phx-click="s3_browse" phx-value-prefix={root.prefix}>
              <div class="s3-card-icon"><%= if String.starts_with?(root.prefix, "user/"), do: "◎", else: "◈" %></div>
              <div class="s3-card-name mono"><%= root.prefix %></div>
              <div class="s3-card-meta"><%= root.object_count %> files · <%= root.subfolder_count %> subfolders</div>
              <div class="s3-card-cta">Browse →</div>
            </button>
          <% end %>
        </div>
      <% else %>
        <div class="s3-breadcrumb">
          <button class="btn-sm" phx-click="s3_back">← Back</button>
          <span class="breadcrumb-sep">Browsing:</span>
          <span class="breadcrumb-path mono"><%= @s3_prefix %></span>
          <button class="btn-sm" phx-click="s3_browse" phx-value-prefix={@s3_prefix}>⟳ Refresh</button>
        </div>

        <%= if @s3_error do %>
          <div class="error-block"><div class="error-title">S3 Error</div><pre class="error-body"><%= @s3_error %></pre></div>
        <% end %>

        <%= if @s3_result do %>
          <%= if @s3_result.prefixes != [] do %>
            <div class="section-label">Subfolders (<%= length(@s3_result.prefixes) %>)</div>
            <div class="s3-folder-grid">
              <%= for pfx <- @s3_result.prefixes, is_map(pfx), Map.has_key?(pfx, :prefix) do %>
                <button class="s3-folder" phx-click="s3_browse" phx-value-prefix={pfx.prefix}>
                  <span style="color:var(--clr-blue)">▸</span>
                  <span class="mono" style="font-size:12px"><%= pfx.prefix |> String.replace_prefix(@s3_prefix, "") |> String.trim_trailing("/") %></span>
                </button>
              <% end %>
            </div>
          <% end %>
          <%= if @s3_result.objects != [] do %>
            <div class="section-label" style="margin-top:20px">Files (<%= length(@s3_result.objects) %>)</div>
            <div class="table-wrap">
              <table class="data-table">
                <thead><tr><th>Key</th><th>Size</th><th>Modified</th><th></th></tr></thead>
                <tbody>
                  <%= for obj <- @s3_result.objects, is_map(obj) do %>
                    <% key = Map.get(obj, :key, "") %>
                    <tr class="data-row">
                      <td class="mono cell-sm" style="max-width:400px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title={key}><%= key %></td>
                      <td class="cell-num cell-sm"><%= Admin.format_bytes(parse_size(Map.get(obj, :size, 0))) %></td>
                      <td class="cell-sm"><%= Map.get(obj, :last_modified, "") %></td>
                      <td><button class="btn-sm" phx-click="s3_presign" phx-value-key={key}>⬇ Link</button></td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>
          <%= if @s3_result.objects == [] && @s3_result.prefixes == [] do %>
            <div class="empty-state">Folder is empty</div>
          <% end %>
        <% end %>
      <% end %>
    </div>
    """
  end

  # ── Shared Components ──────────────────────────────────────────────────────

  defp confirm_dialog(assigns) do
    ~H"""
    <div class="overlay">
      <div class="modal">
        <div class="modal-icon">⚠</div>
        <div class="modal-title">Confirm Action</div>
        <div class="modal-body"><%= @confirm_action.label %></div>
        <div class="modal-btns">
          <button class="btn-cancel" phx-click="cancel_confirm">Cancel</button>
          <button class="btn-danger" phx-click="execute_confirm">Confirm</button>
        </div>
      </div>
    </div>
    """
  end

  defp flash_toast(assigns) do
    {type, msg} = assigns.flash_msg
    ~H"""
    <div class={"toast toast-#{type}"}>
      <span><%= msg %></span>
      <button phx-click="dismiss_flash" style="background:none;border:none;cursor:pointer;color:inherit;opacity:.6;font-size:14px;padding:0;margin-left:8px">✕</button>
    </div>
    """
  end

  defp presign_modal(assigns) do
    ~H"""
    <div class="overlay" phx-click="s3_close_presign">
      <div class="modal" style="width:500px">
        <div style="font-size:13px;font-weight:700;color:var(--clr-green);margin-bottom:10px">⬇ Download Link (15 min)</div>
        <div class="mono cell-sm" style="word-break:break-all;color:var(--clr-blue);margin-bottom:14px"><%= @s3_presigned.key %></div>
        <a href={@s3_presigned.url} target="_blank" class="btn-run" style="display:inline-block;text-decoration:none;margin-bottom:12px">Open / Download</a>
        <br/><button class="btn-clear" phx-click="s3_close_presign">Close</button>
      </div>
    </div>
    """
  end

  defp pagination(%{d: %{pages: p}} = assigns) when p > 1 do
    ~H"""
    <div class="pagination">
      <%= if @d.page > 1 do %><button class="page-btn" phx-click={@e} phx-value-page={@d.page - 1}>‹ Prev</button><% end %>
      <span class="page-info">Page <%= @d.page %> of <%= @d.pages %> · <%= @d.total %> total</span>
      <%= if @d.page < @d.pages do %><button class="page-btn" phx-click={@e} phx-value-page={@d.page + 1}>Next ›</button><% end %>
    </div>
    """
  end
  defp pagination(assigns), do: ~H""

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp fd(nil), do: "—"
  defp fd(%NaiveDateTime{} = d), do: NaiveDateTime.to_date(d) |> Date.to_string()
  defp fd(%DateTime{} = d),      do: DateTime.to_date(d) |> Date.to_string()
  defp fd(_), do: "—"

  defp ctic(nil), do: "◈"
  defp ctic(ct) do
    cond do
      String.starts_with?(ct, "image/")  -> "🖼"
      ct == "application/pdf"            -> "📄"
      String.contains?(ct, "word")       -> "📝"
      String.contains?(ct, "sheet")      -> "📊"
      String.starts_with?(ct, "video/") -> "🎬"
      String.starts_with?(ct, "audio/") -> "🎵"
      String.starts_with?(ct, "text/")  -> "📃"
      String.contains?(ct, "zip")        -> "🗜"
      true                               -> "◈"
    end
  end

  defp sct(nil), do: "unknown"
  defp sct(ct),  do: ct |> String.split("/") |> List.last() |> String.split(".") |> List.last() |> String.slice(0, 12)

  defp fmt_cell(nil),  do: "NULL"
  defp fmt_cell(v) when is_binary(v),  do: v
  defp fmt_cell(v) when is_boolean(v), do: to_string(v)
  defp fmt_cell(v) when is_integer(v), do: Integer.to_string(v)
  defp fmt_cell(v) when is_float(v),   do: Float.to_string(Float.round(v, 4))
  defp fmt_cell(%Decimal{} = v),       do: Decimal.to_string(v)
  defp fmt_cell(%NaiveDateTime{} = v), do: NaiveDateTime.to_string(v)
  defp fmt_cell(%DateTime{} = v),      do: DateTime.to_string(v)
  defp fmt_cell(v),                    do: inspect(v)

  defp parse_size(s) when is_binary(s), do: String.to_integer(s)
  defp parse_size(i) when is_integer(i), do: i
  defp parse_size(%Decimal{} = d), do: Decimal.to_integer(d)
  defp parse_size(_), do: 0

  # ── CSS ────────────────────────────────────────────────────────────────────

  defp css do
    """
    <style>
    @import url('https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600&family=Syne:wght@400;600;700;800&display=swap');

    *, *::before, *::after { margin:0; padding:0; box-sizing:border-box }

    /* ── DARK THEME ─────────────────────────────────────────── */
    .theme-dark {
      --bg:       #0c0c10;
      --bg2:      #13131a;
      --bg3:      #1a1a24;
      --bg4:      #21212e;
      --bg5:      #282836;
      --border:   rgba(255,255,255,.06);
      --border2:  rgba(255,255,255,.11);
      --tx:       #e2e2ee;
      --tx2:      #8888a8;
      --tx3:      #4a4a68;
      --clr-blue:   #5b9eff;
      --clr-green:  #00dda0;
      --clr-red:    #ff5566;
      --clr-amber:  #ffbb00;
      --clr-purple: #a78bfa;
      --clr-orange: #ff8c42;
      --shadow:   0 4px 24px rgba(0,0,0,.5);
      --shadow-lg:0 12px 48px rgba(0,0,0,.7);
    }

    /* ── LIGHT THEME ─────────────────────────────────────────── */
    .theme-light {
      --bg:       #f0f0f7;
      --bg2:      #ffffff;
      --bg3:      #f7f7fc;
      --bg4:      #ebebf5;
      --bg5:      #e2e2ef;
      --border:   rgba(0,0,0,.07);
      --border2:  rgba(0,0,0,.13);
      --tx:       #16161e;
      --tx2:      #5a5a7a;
      --tx3:      #9898b8;
      --clr-blue:   #2563eb;
      --clr-green:  #059669;
      --clr-red:    #dc2626;
      --clr-amber:  #d97706;
      --clr-purple: #7c3aed;
      --clr-orange: #ea580c;
      --shadow:   0 2px 12px rgba(0,0,0,.08);
      --shadow-lg:0 8px 32px rgba(0,0,0,.14);
    }

    /* ── BASE ──────────────────────────────────────────────────── */
    #adm {
      height: 100vh;
      background: var(--bg);
      color: var(--tx);
      font-family: 'Syne', -apple-system, sans-serif;
      overflow: hidden;
      transition: background .2s, color .2s;
    }
    .al { display: grid; grid-template-columns: 220px 1fr; height: 100vh }
    .mono { font-family: 'IBM Plex Mono', 'SF Mono', monospace }

    /* ── SIDEBAR ────────────────────────────────────────────────── */
    .sb {
      background: var(--bg2);
      border-right: 1px solid var(--border);
      display: flex;
      flex-direction: column;
      overflow: hidden;
    }
    .sb-top {
      padding: 16px 14px 10px;
      border-bottom: 1px solid var(--border);
    }
    .sb-logo { display: flex; align-items: center; gap: 10px; margin-bottom: 3px }
    .lm {
      width: 30px; height: 30px;
      background: linear-gradient(135deg, var(--clr-blue), var(--clr-purple));
      border-radius: 8px;
      display: flex; align-items: center; justify-content: center;
      flex-shrink: 0;
    }
    .lt {
      font-size: 15px; font-weight: 800; letter-spacing: 3px;
      background: linear-gradient(135deg, var(--clr-blue), var(--clr-purple));
      -webkit-background-clip: text; -webkit-text-fill-color: transparent;
      background-clip: text;
    }
    .sb-sub { font-size: 9px; color: var(--tx3); letter-spacing: 1.8px; text-transform: uppercase; padding-left: 40px }
    .sb-nav { flex: 1; padding: 8px; overflow-y: auto }
    .nsl {
      font-size: 9px; font-weight: 700; color: var(--tx3);
      letter-spacing: 1.5px; text-transform: uppercase;
      padding: 12px 8px 4px;
    }
    .ni {
      display: flex; align-items: center; gap: 9px;
      padding: 7px 9px; border-radius: 7px;
      border: none; background: none;
      color: var(--tx2); cursor: pointer;
      width: 100%; text-align: left;
      font-size: 12px; font-weight: 600;
      font-family: 'Syne', sans-serif;
      transition: all .15s;
    }
    .ni:hover { background: var(--bg3); color: var(--tx) }
    .ni.active { background: rgba(91,158,255,.1); color: var(--clr-blue) }
    .theme-light .ni.active { background: rgba(37,99,235,.08) }
    .ni-ic { width: 16px; text-align: center; flex-shrink: 0; display: flex; align-items: center; justify-content: center }
    .ni-lb { flex: 1 }
    .ni-bd {
      background: var(--bg4); color: var(--tx3);
      font-size: 10px; padding: 1px 6px; border-radius: 8px;
      font-family: 'IBM Plex Mono', monospace;
    }
    .ni.active .ni-bd { background: rgba(91,158,255,.15); color: var(--clr-blue) }
    .sb-ft { padding: 12px; border-top: 1px solid var(--border); font-size: 11px }
    .ft-stat { display: flex; align-items: center; gap: 7px; margin-bottom: 5px; color: var(--tx2) }
    .ft-stat.accent { color: var(--clr-green) }
    .ft-stat.muted { color: var(--tx3) }
    .ft-dot { width: 6px; height: 6px; border-radius: 50%; background: var(--clr-green); flex-shrink: 0; box-shadow: 0 0 6px rgba(0,221,160,.4) }
    .ft-dot.green { background: var(--clr-green); box-shadow: 0 0 6px rgba(0,221,160,.4) }
    .ft-dot.blue  { background: var(--clr-blue);  box-shadow: 0 0 6px rgba(91,158,255,.4) }

    /* ── TOPBAR ─────────────────────────────────────────────────── */
    .am { display: flex; flex-direction: column; overflow: hidden }
    .tb {
      height: 52px; background: var(--bg2);
      border-bottom: 1px solid var(--border);
      display: flex; align-items: center;
      justify-content: space-between;
      padding: 0 20px; flex-shrink: 0;
    }
    .tb-left { display: flex; flex-direction: column; gap: 1px }
    .tb-t { font-size: 14px; font-weight: 700 }
    .tb-bc { font-size: 10px; color: var(--tx3); font-family: 'IBM Plex Mono', monospace }
    .tb-r { display: flex; align-items: center; gap: 10px }
    .tb-chips { display: flex; gap: 6px }
    .chip {
      font-size: 10px; padding: 3px 9px; border-radius: 20px;
      font-weight: 600; font-family: 'IBM Plex Mono', monospace;
    }
    .chip-users    { background: rgba(91,158,255,.1);  color: var(--clr-blue);   border: 1px solid rgba(91,158,255,.2) }
    .chip-sessions { background: rgba(0,221,160,.1);   color: var(--clr-green);  border: 1px solid rgba(0,221,160,.2) }
    .chip-brand    { background: var(--bg4);            color: var(--tx3);         border: 1px solid var(--border) }
    .theme-btn {
      width: 32px; height: 32px; border-radius: 8px;
      border: 1px solid var(--border2);
      background: var(--bg3);
      color: var(--tx2); cursor: pointer;
      display: flex; align-items: center; justify-content: center;
      transition: all .15s;
    }
    .theme-btn:hover { background: var(--bg4); color: var(--tx) }
    .logout-btn {
      display: flex; align-items: center; gap: 6px;
      font-size: 11px; font-weight: 600;
      color: var(--tx3); text-decoration: none;
      padding: 6px 10px; border-radius: 7px;
      border: 1px solid var(--border);
      background: var(--bg3);
      transition: all .15s;
      font-family: 'Syne', sans-serif;
    }
    .logout-btn:hover { color: var(--clr-red); border-color: rgba(255,85,102,.3) }
    .ac { flex: 1; overflow-y: auto; padding: 20px }

    /* ── CARDS ──────────────────────────────────────────────────── */
    .card {
      background: var(--bg2);
      border: 1px solid var(--border);
      border-radius: 12px;
      overflow: hidden;
    }
    .card-head {
      display: flex; align-items: center; justify-content: space-between;
      padding: 11px 14px;
      border-bottom: 1px solid var(--border);
      background: var(--bg3);
    }
    .card-title { font-size: 11px; font-weight: 700; text-transform: uppercase; letter-spacing: .8px; color: var(--tx2) }
    .card-meta  { font-size: 10px; color: var(--tx3); font-family: 'IBM Plex Mono', monospace }
    .card-body  { padding: 14px }

    /* ── STAT CARDS ─────────────────────────────────────────────── */
    .sg { display: grid; grid-template-columns: repeat(4, 1fr); gap: 10px; margin-bottom: 16px }
    .sc {
      background: var(--bg2); border: 1px solid var(--border);
      border-radius: 12px; padding: 14px 16px;
      display: flex; align-items: center; gap: 12px;
      transition: all .15s; cursor: default;
    }
    .sc:hover { border-color: var(--border2); transform: translateY(-1px); box-shadow: var(--shadow) }
    .sc-ic {
      width: 36px; height: 36px; border-radius: 9px;
      display: flex; align-items: center; justify-content: center;
      flex-shrink: 0;
    }
    .sc-blue   .sc-ic { background: rgba(91,158,255,.12); color: var(--clr-blue) }
    .sc-green  .sc-ic { background: rgba(0,221,160,.12);  color: var(--clr-green) }
    .sc-red    .sc-ic { background: rgba(255,85,102,.12); color: var(--clr-red) }
    .sc-amber  .sc-ic { background: rgba(255,187,0,.12);  color: var(--clr-amber) }
    .sc-purple .sc-ic { background: rgba(167,139,250,.12);color: var(--clr-purple) }
    .sc-v { font-size: 22px; font-weight: 800; line-height: 1; font-family: 'IBM Plex Mono', monospace }
    .sc-l { font-size: 10px; color: var(--tx3); margin-top: 3px; font-weight: 600; text-transform: uppercase; letter-spacing: .5px }

    /* ── DASHBOARD GRID ─────────────────────────────────────────── */
    .dash-grid { display: grid; grid-template-columns: 1.2fr 1fr 1fr; gap: 12px }
    .storage-row {
      display: grid; grid-template-columns: 100px 1fr 80px;
      gap: 10px; align-items: center; margin-bottom: 12px;
      font-size: 11px;
    }
    .storage-label { color: var(--tx2) }
    .storage-bar-wrap { }
    .storage-bar-track { height: 4px; background: var(--bg4); border-radius: 2px; overflow: hidden }
    .storage-bar-fill {
      height: 100%; border-radius: 2px;
      transition: width .6s cubic-bezier(.4,0,.2,1);
    }
    .storage-bar-fill.blue   { background: var(--clr-blue) }
    .storage-bar-fill.green  { background: var(--clr-green) }
    .storage-bar-fill.red    { background: var(--clr-red) }
    .storage-val { text-align: right; font-weight: 600; font-size: 11px; font-family: 'IBM Plex Mono', monospace }
    .divider { border: none; border-top: 1px solid var(--border); margin: 12px 0 }
    .data-plane-title { font-size: 9px; font-weight: 700; color: var(--tx3); text-transform: uppercase; letter-spacing: 1px; margin-bottom: 8px }
    .kv-row {
      display: flex; justify-content: space-between; align-items: center;
      padding: 6px 14px; font-size: 12px;
      border-bottom: 1px solid var(--border);
    }
    .kv-row:last-child { border-bottom: none }
    .kv-row span { color: var(--tx2) }
    .kv-row strong { font-family: 'IBM Plex Mono', monospace; font-size: 11px }
    .svc-row {
      display: flex; align-items: center; gap: 8px;
      padding: 7px 0; font-size: 12px;
      border-bottom: 1px solid var(--border);
    }
    .svc-row:last-child { border-bottom: none }
    .svc-row > span:nth-child(2) { flex: 1; color: var(--tx2) }
    .svc-dot { width: 7px; height: 7px; border-radius: 50%; flex-shrink: 0 }
    .svc-dot.green { background: var(--clr-green); box-shadow: 0 0 6px rgba(0,221,160,.5) }
    .svc-dot.blue  { background: var(--clr-blue);  box-shadow: 0 0 6px rgba(91,158,255,.4) }
    .svc-badge { font-size: 10px; padding: 2px 8px; border-radius: 10px; font-weight: 700 }
    .svc-badge.online { background: rgba(0,221,160,.1); color: var(--clr-green) }
    .svc-tokens { display: flex; align-items: center; gap: 8px; padding: 7px 0; font-size: 12px; color: var(--tx2) }
    .svc-tokens > span:nth-child(2) { flex: 1 }
    .token-badge { background: rgba(91,158,255,.1); color: var(--clr-blue); font-size: 10px; padding: 2px 8px; border-radius: 10px; font-weight: 700 }
    .quick-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 7px }
    .quick-btn {
      display: flex; align-items: center; gap: 7px;
      background: var(--bg3); border: 1px solid var(--border);
      border-radius: 8px; padding: 8px 10px;
      color: var(--tx2); cursor: pointer;
      font-size: 11px; font-weight: 600;
      font-family: 'Syne', sans-serif;
      transition: all .15s;
    }
    .quick-btn:hover { background: var(--bg4); color: var(--tx); border-color: var(--border2) }
    .audit-row {
      display: flex; align-items: center; gap: 10px;
      padding: 9px 14px; font-size: 11px;
      border-bottom: 1px solid var(--border);
      transition: background .1s;
    }
    .audit-row:last-child { border-bottom: none }
    .audit-row:hover { background: var(--bg3) }
    .audit-dot { width: 6px; height: 6px; border-radius: 50%; background: var(--clr-blue); flex-shrink: 0 }
    .audit-info { flex: 1; display: flex; gap: 6px; align-items: center }
    .audit-action { font-weight: 600; color: var(--tx) }
    .audit-target { color: var(--tx3); font-family: 'IBM Plex Mono', monospace; font-size: 10px }
    .audit-time { color: var(--tx3); font-size: 10px; font-family: 'IBM Plex Mono', monospace; white-space: nowrap }

    /* ── TOOLBAR ────────────────────────────────────────────────── */
    .toolbar { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; margin-bottom: 12px }
    .search-box {
      display: flex; align-items: center; gap: 8px;
      background: var(--bg2); border: 1px solid var(--border);
      border-radius: 8px; padding: 7px 11px;
      flex: 1; min-width: 160px; color: var(--tx2);
      transition: border-color .15s;
    }
    .search-box:focus-within { border-color: var(--clr-blue) }
    .search-input {
      background: none; border: none; outline: none;
      color: var(--tx); font-size: 12px; width: 100%;
      font-family: 'Syne', sans-serif;
    }
    .search-input::placeholder { color: var(--tx3) }
    .filter-pills { display: flex; gap: 5px; flex-wrap: wrap }
    .pill {
      background: var(--bg3); border: 1px solid var(--border);
      border-radius: 20px; padding: 4px 11px;
      color: var(--tx2); cursor: pointer;
      font-size: 11px; font-weight: 600;
      font-family: 'Syne', sans-serif;
      transition: all .15s;
    }
    .pill:hover { border-color: var(--border2); color: var(--tx) }
    .pill.active { background: rgba(91,158,255,.1); border-color: rgba(91,158,255,.3); color: var(--clr-blue) }
    .theme-light .pill.active { background: rgba(37,99,235,.08); border-color: rgba(37,99,235,.25) }
    .select-box {
      background: var(--bg2); border: 1px solid var(--border);
      border-radius: 8px; padding: 7px 10px;
      color: var(--tx); font-size: 12px;
      font-family: 'Syne', sans-serif;
      cursor: pointer; outline: none;
    }

    /* ── TABLE ──────────────────────────────────────────────────── */
    .table-wrap { background: var(--bg2); border: 1px solid var(--border); border-radius: 12px; overflow: hidden }
    .data-table { width: 100%; border-collapse: collapse }
    .data-table thead th {
      background: var(--bg3); padding: 9px 13px;
      font-size: 10px; font-weight: 700; color: var(--tx2);
      text-align: left; letter-spacing: .7px; text-transform: uppercase;
      border-bottom: 1px solid var(--border);
    }
    .data-table tbody tr { border-bottom: 1px solid var(--border); transition: background .1s }
    .data-table tbody tr:last-child { border-bottom: none }
    .data-row:hover { background: var(--bg3) }
    .data-table td { padding: 9px 13px; font-size: 12px; color: var(--tx) }
    .empty-row { text-align: center; color: var(--tx3); padding: 36px; font-size: 13px }
    .cell-num { text-align: right; font-weight: 700; font-family: 'IBM Plex Mono', monospace; font-size: 12px }
    .cell-sm  { font-size: 11px; color: var(--tx2) }
    .action-btns { display: flex; gap: 5px }

    /* ── BUTTONS ────────────────────────────────────────────────── */
    .btn-sm {
      background: var(--bg4); border: 1px solid var(--border);
      border-radius: 6px; padding: 4px 10px;
      color: var(--tx2); cursor: pointer;
      font-size: 10px; font-weight: 700;
      font-family: 'Syne', sans-serif;
      transition: all .15s;
    }
    .btn-sm:hover { background: var(--bg5); color: var(--tx) }
    .btn-sm.accent { color: var(--clr-purple); border-color: rgba(167,139,250,.3); background: rgba(167,139,250,.08) }
    .btn-sm.accent:hover { background: rgba(167,139,250,.14) }

    /* ── BADGES ─────────────────────────────────────────────────── */
    .badge-row { display: flex; gap: 4px; flex-wrap: wrap }
    .badge { font-size: 9px; padding: 2px 7px; border-radius: 20px; font-weight: 700; letter-spacing: .3px }
    .badge.green  { background: rgba(0,221,160,.1);  color: var(--clr-green);  border: 1px solid rgba(0,221,160,.2) }
    .badge.red    { background: rgba(255,85,102,.1); color: var(--clr-red);    border: 1px solid rgba(255,85,102,.2) }
    .badge.blue   { background: rgba(91,158,255,.1); color: var(--clr-blue);   border: 1px solid rgba(91,158,255,.2) }
    .badge.gray   { background: var(--bg4);           color: var(--tx3);         border: 1px solid var(--border) }
    .badge.amber  { background: rgba(255,187,0,.1);  color: var(--clr-amber);  border: 1px solid rgba(255,187,0,.2) }
    .badge.purple { background: rgba(167,139,250,.1);color: var(--clr-purple); border: 1px solid rgba(167,139,250,.2) }
    .ref-badge { background: var(--bg4); color: var(--tx2); font-size: 10px; padding: 2px 7px; border-radius: 8px; font-family: 'IBM Plex Mono', monospace; font-weight: 600 }
    .ref-badge.dup { background: rgba(255,187,0,.1); color: var(--clr-amber); border: 1px solid rgba(255,187,0,.2) }

    /* ── PAGINATION ─────────────────────────────────────────────── */
    .pagination { display: flex; align-items: center; gap: 10px; padding: 12px; justify-content: center }
    .page-btn {
      background: var(--bg3); border: 1px solid var(--border);
      border-radius: 7px; padding: 5px 14px;
      color: var(--tx2); cursor: pointer;
      font-size: 12px; font-weight: 600;
      font-family: 'Syne', sans-serif;
      transition: all .15s;
    }
    .page-btn:hover { background: var(--bg4); color: var(--tx) }
    .page-info { font-size: 11px; color: var(--tx3); font-family: 'IBM Plex Mono', monospace }

    /* ── USER DETAIL ────────────────────────────────────────────── */
    .back-btn {
      display: flex; align-items: center; gap: 6px;
      background: none; border: none; color: var(--tx2);
      cursor: pointer; font-size: 12px; font-weight: 600;
      font-family: 'Syne', sans-serif;
      margin-bottom: 16px; padding: 0;
      transition: color .15s;
    }
    .back-btn:hover { color: var(--tx) }
    .profile-card {
      background: var(--bg2); border: 1px solid var(--border);
      border-radius: 14px; padding: 22px;
      display: flex; align-items: flex-start; gap: 18px;
      margin-bottom: 14px;
    }
    .profile-avatar-lg {
      width: 56px; height: 56px; border-radius: 14px;
      background: linear-gradient(135deg, var(--clr-blue), var(--clr-purple));
      display: flex; align-items: center; justify-content: center;
      font-size: 22px; font-weight: 800; color: #fff; flex-shrink: 0;
    }
    .profile-info { flex: 1 }
    .profile-name  { font-size: 18px; font-weight: 800; margin-bottom: 3px }
    .profile-email { font-size: 12px; color: var(--tx2); margin-bottom: 2px }
    .profile-id    { font-size: 10px; color: var(--tx3); margin-bottom: 8px; font-family: 'IBM Plex Mono', monospace }
    .profile-actions { display: flex; flex-direction: column; gap: 6px; flex-shrink: 0 }
    .action-btn {
      padding: 6px 14px; border-radius: 7px; border: 1px solid transparent;
      cursor: pointer; font-size: 11px; font-weight: 700;
      font-family: 'Syne', sans-serif;
      transition: all .15s;
    }
    .action-btn:hover { transform: translateY(-1px); opacity: .85 }
    .action-btn.purple { background: rgba(167,139,250,.12); color: var(--clr-purple); border-color: rgba(167,139,250,.25) }
    .action-btn.green  { background: rgba(0,221,160,.12);  color: var(--clr-green);  border-color: rgba(0,221,160,.25) }
    .action-btn.red    { background: rgba(255,85,102,.12); color: var(--clr-red);    border-color: rgba(255,85,102,.25) }
    .action-btn.amber  { background: rgba(255,187,0,.12);  color: var(--clr-amber);  border-color: rgba(255,187,0,.25) }
    .action-btn.gray   { background: var(--bg4);            color: var(--tx2);         border-color: var(--border) }
    .action-btn.orange { background: rgba(255,140,66,.12); color: var(--clr-orange); border-color: rgba(255,140,66,.25) }
    .stat-strip { display: grid; grid-template-columns: repeat(6, 1fr); gap: 10px; margin-bottom: 14px }
    .strip-stat { background: var(--bg2); border: 1px solid var(--border); border-radius: 10px; padding: 12px; text-align: center }
    .strip-stat.green .strip-val { color: var(--clr-green) }
    .strip-val { font-size: 15px; font-weight: 800; margin-bottom: 3px; font-family: 'IBM Plex Mono', monospace }
    .strip-lbl { font-size: 10px; color: var(--tx3); font-weight: 600; text-transform: uppercase; letter-spacing: .4px }
    .three-col { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 12px }
    .scroll-list { max-height: 300px; overflow-y: auto }
    .list-row {
      display: flex; align-items: center; gap: 9px;
      padding: 9px 13px; border-bottom: 1px solid var(--border);
      font-size: 12px; transition: background .1s;
    }
    .list-row:last-child { border-bottom: none }
    .list-row:hover { background: var(--bg3) }
    .file-icon { font-size: 16px; flex-shrink: 0 }
    .row-name { font-size: 12px; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis }
    .row-meta { font-size: 10px; color: var(--tx3) }
    .empty-state { text-align: center; color: var(--tx3); padding: 40px; font-size: 13px }
    .did-block {
      background: var(--bg3); padding: 10px 14px;
      font-size: 10px; color: var(--clr-blue);
      word-break: break-all; border-bottom: 1px solid var(--border);
    }
    .section-label { font-size: 10px; font-weight: 700; color: var(--tx3); text-transform: uppercase; letter-spacing: .8px; margin-bottom: 8px }

    /* ── PERMISSIONS ────────────────────────────────────────────── */
    .perm-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px }
    .perm-row {
      display: flex; justify-content: space-between; align-items: center;
      padding: 12px 14px; border-bottom: 1px solid var(--border);
    }
    .perm-row:last-child { border-bottom: none }
    .perm-name { font-size: 13px; font-weight: 700; margin-bottom: 2px }
    .perm-desc { font-size: 10px; color: var(--tx3) }
    .perm-ctrl { display: flex; align-items: center; gap: 7px }
    .perm-badge {
      font-size: 9px; padding: 3px 9px; border-radius: 20px;
      font-weight: 700; letter-spacing: .3px; white-space: nowrap;
    }
    .perm-badge.on  { background: rgba(0,221,160,.1);  color: var(--clr-green); border: 1px solid rgba(0,221,160,.2) }
    .perm-badge.off { background: var(--bg4);            color: var(--tx3);        border: 1px solid var(--border) }
    .perm-btn {
      font-size: 10px; padding: 4px 10px; border-radius: 6px;
      border: 1px solid transparent; cursor: pointer;
      font-weight: 700; font-family: 'Syne', sans-serif;
      transition: all .15s; white-space: nowrap;
    }
    .perm-btn:hover { opacity: .8; transform: translateY(-1px) }
    .perm-btn.red    { background: rgba(255,85,102,.1);  color: var(--clr-red);    border-color: rgba(255,85,102,.25) }
    .perm-btn.green  { background: rgba(0,221,160,.1);   color: var(--clr-green);  border-color: rgba(0,221,160,.25) }
    .perm-btn.amber  { background: rgba(255,187,0,.1);   color: var(--clr-amber);  border-color: rgba(255,187,0,.25) }
    .perm-btn.purple { background: rgba(167,139,250,.1); color: var(--clr-purple); border-color: rgba(167,139,250,.25) }
    .perm-btn.gray   { background: var(--bg4);            color: var(--tx2);         border-color: var(--border) }

    /* ── VAULT ──────────────────────────────────────────────────── */
    .vault-layout { display: grid; grid-template-columns: 190px 1fr; gap: 12px }
    .vault-sidebar { background: var(--bg2); border: 1px solid var(--border); border-radius: 12px; overflow: hidden }
    .vault-all-btn {
      display: block; width: 100%; text-align: left;
      padding: 9px 13px; cursor: pointer;
      background: none; border: none; border-bottom: 1px solid var(--border);
      font-size: 12px; color: var(--clr-blue); font-weight: 700;
      font-family: 'Syne', sans-serif;
      transition: background .1s;
    }
    .vault-all-btn:hover { background: var(--bg3) }
    .vault-ns { padding: 8px 13px; border-bottom: 1px solid var(--border); cursor: pointer }
    .vault-ns:hover { background: var(--bg3) }

    /* ── SQL ────────────────────────────────────────────────────── */
    .sql-layout { display: grid; grid-template-columns: 250px 1fr; gap: 12px; height: calc(100vh - 92px) }
    .sql-left { display: flex; flex-direction: column; gap: 12px; overflow-y: auto }
    .sql-right { overflow-y: auto }
    .preset-btn {
      display: block; width: 100%; text-align: left;
      background: none; border: none; border-bottom: 1px solid var(--border);
      padding: 9px 14px; color: var(--tx2); cursor: pointer;
      font-size: 12px; font-weight: 600; font-family: 'Syne', sans-serif;
      transition: all .15s;
    }
    .preset-btn:last-child { border-bottom: none }
    .preset-btn:hover { background: var(--bg3); color: var(--tx) }
    .sql-editor {
      width: 100%; background: var(--bg3);
      border: none; border-top: 1px solid var(--border);
      padding: 12px 14px; color: var(--tx);
      font-family: 'IBM Plex Mono', monospace;
      font-size: 12px; line-height: 1.7;
      resize: vertical; outline: none; min-height: 140px;
    }
    .sql-editor:focus { border-top-color: var(--clr-blue) }
    .sql-toolbar {
      display: flex; align-items: center; gap: 8px;
      padding: 10px 14px; background: var(--bg3);
      border-top: 1px solid var(--border);
    }
    .btn-run {
      background: var(--clr-blue); color: #fff; border: none;
      border-radius: 7px; padding: 7px 16px;
      font-size: 12px; font-weight: 700; cursor: pointer;
      font-family: 'Syne', sans-serif;
      transition: all .15s;
    }
    .btn-run:hover { opacity: .87 }
    .btn-clear {
      background: var(--bg4); border: 1px solid var(--border);
      border-radius: 7px; padding: 7px 12px;
      color: var(--tx2); cursor: pointer;
      font-size: 12px; font-family: 'Syne', sans-serif;
      transition: all .15s;
    }
    .btn-clear:hover { background: var(--bg5); color: var(--tx) }
    .sql-hint { font-size: 10px; color: var(--tx3); margin-left: auto; font-family: 'IBM Plex Mono', monospace }
    .error-block { background: rgba(255,85,102,.07); border: 1px solid rgba(255,85,102,.2); border-radius: 10px; padding: 14px; margin-bottom: 12px }
    .error-title { font-size: 12px; font-weight: 700; color: var(--clr-red); margin-bottom: 7px }
    .error-body { font-size: 11px; color: var(--clr-red); font-family: 'IBM Plex Mono', monospace; white-space: pre-wrap }
    .sql-scroll { overflow-x: auto; max-height: 60vh }
    .sql-cell { font-size: 11px; font-family: 'IBM Plex Mono', monospace; max-width: 220px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap }
    .sql-placeholder { text-align: center; color: var(--tx3); padding: 60px; font-size: 13px }

    /* ── S3 ─────────────────────────────────────────────────────── */
    .s3-root-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 16px; max-width: 600px }
    .s3-card {
      background: var(--bg2); border: 1px solid var(--border2);
      border-radius: 14px; padding: 24px; cursor: pointer;
      text-align: left; transition: all .2s;
      display: flex; flex-direction: column; gap: 6px;
      position: relative; overflow: hidden;
    }
    .s3-card::before { content:''; position: absolute; top: 0; left: 0; right: 0; height: 2px; background: linear-gradient(90deg, var(--clr-blue), var(--clr-purple)) }
    .s3-card:hover { border-color: rgba(91,158,255,.3); transform: translateY(-2px); box-shadow: var(--shadow-lg) }
    .s3-card-icon { font-size: 28px; color: var(--clr-blue); margin-bottom: 4px }
    .s3-card-name { font-size: 16px; font-weight: 700; color: var(--tx) }
    .s3-card-meta { font-size: 12px; color: var(--tx2) }
    .s3-card-cta  { font-size: 11px; color: var(--clr-blue); font-weight: 700; margin-top: 4px }
    .s3-breadcrumb { display: flex; align-items: center; gap: 8px; margin-bottom: 16px; font-size: 12px; flex-wrap: wrap }
    .breadcrumb-sep  { color: var(--tx3) }
    .breadcrumb-path { color: var(--clr-blue); font-family: 'IBM Plex Mono', monospace }
    .s3-folder-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(170px, 1fr)); gap: 7px }
    .s3-folder {
      background: var(--bg2); border: 1px solid var(--border);
      border-radius: 8px; padding: 10px 12px; cursor: pointer;
      display: flex; align-items: center; gap: 8px;
      font-size: 12px; color: var(--tx);
      font-family: 'Syne', sans-serif;
      transition: all .15s;
    }
    .s3-folder:hover { background: var(--bg3); border-color: var(--border2) }

    /* ── MODALS / OVERLAY ───────────────────────────────────────── */
    .overlay {
      position: fixed; inset: 0;
      background: rgba(0,0,0,.65);
      z-index: 1000;
      display: flex; align-items: center; justify-content: center;
      backdrop-filter: blur(6px);
    }
    .modal {
      background: var(--bg2); border: 1px solid var(--border2);
      border-radius: 16px; padding: 28px; width: 350px;
      text-align: center; box-shadow: var(--shadow-lg);
      animation: modal-in .2s ease;
    }
    @keyframes modal-in { from { transform: scale(.94) translateY(10px); opacity: 0 } to { transform: scale(1) translateY(0); opacity: 1 } }
    .modal-icon  { font-size: 28px; margin-bottom: 12px }
    .modal-title { font-size: 16px; font-weight: 800; margin-bottom: 8px }
    .modal-body  { font-size: 13px; color: var(--tx2); margin-bottom: 22px; line-height: 1.5 }
    .modal-btns  { display: flex; gap: 10px; justify-content: center }
    .btn-cancel {
      background: var(--bg4); border: 1px solid var(--border);
      border-radius: 7px; padding: 8px 18px;
      color: var(--tx2); cursor: pointer;
      font-size: 12px; font-weight: 700;
      font-family: 'Syne', sans-serif;
      transition: all .15s;
    }
    .btn-cancel:hover { background: var(--bg5); color: var(--tx) }
    .btn-danger {
      background: rgba(255,85,102,.15); border: 1px solid rgba(255,85,102,.3);
      border-radius: 7px; padding: 8px 18px;
      color: var(--clr-red); cursor: pointer;
      font-size: 12px; font-weight: 700;
      font-family: 'Syne', sans-serif;
      transition: all .15s;
    }
    .btn-danger:hover { background: rgba(255,85,102,.25) }

    /* ── TOAST ──────────────────────────────────────────────────── */
    .toast {
      position: fixed; top: 16px; right: 16px; z-index: 2000;
      background: var(--bg2); border: 1px solid var(--border2);
      border-radius: 10px; padding: 11px 16px;
      display: flex; align-items: center;
      font-size: 12px; font-weight: 600;
      box-shadow: var(--shadow-lg);
      animation: toast-in .3s cubic-bezier(.16,1,.3,1);
    }
    .toast-success { border-color: rgba(0,221,160,.3); color: var(--clr-green) }
    .toast-error   { border-color: rgba(255,85,102,.3); color: var(--clr-red) }
    @keyframes toast-in { from { transform: translateX(50px); opacity: 0 } to { transform: translateX(0); opacity: 1 } }
    </style>
    """
  end
end
