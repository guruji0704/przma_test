defmodule AlemWeb.AdminLive do
  @moduledoc """
  PRZMA Control Plane — Core LiveView.

  Responsibilities:
    - mount/3: initialise all assigns
    - handle_params/3: URL-based page restoration on reload
    - handle_event/3: ALL user interactions
    - render/1: top-level layout (dispatches to page modules)
    - sidebar/1, topbar/1: navigation chrome

  Page modules live in pages/ — each owns its own template.
  Shared helpers: Admin.Helpers, Admin.Charts, Admin.Styles.

  File structure:
    admin_live.ex           <- This file (core: mount, events, render)
    admin_helpers.ex        <- fd(), ctic(), sct(), short_mime(), etc.
    admin_charts.ex         <- Charts.bar(), Charts.pie(), etc.
    admin_styles.ex         <- All CSS
    pages/
      dashboard.ex          <- Dashboard KPI + service overview
      users.ex              <- Users list (search/filter/sort/paginate)
      user_profile.ex       <- Full activity analytics, 8 charts, security
      permissions.ex        <- Per-user access control
      monitoring.ex         <- Platform resource monitoring
      storage.ex            <- CAS vault + duplicates + S3 (read-only)
      analytics.ex          <- Drill-down analytics (Users/Storage/CAS)
  """
  use AlemWeb, :live_view
  alias Alem.Admin
  alias AlemWeb.Admin.Styles
  import AlemWeb.Admin.Helpers
  import AlemWeb.Admin.Components
  require Logger

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
      |> assign(:analytics_users,    nil)
      |> assign(:analytics_storage,  nil)
      |> assign(:analytics_cas,      nil)
      |> assign(:permissions,      nil)
      |> assign(:search,           "")
      |> assign(:user_filter,      "all")
      |> assign(:user_sort,        "newest")
      |> assign(:cas_filter,       "all")
      |> assign(:cas_search,       "")
      |> assign(:confirm_action,   nil)
      |> assign(:flash_msg,        nil)
      |> assign(:s3_prefix,        "")
      |> assign(:s3_result,        nil)
      |> assign(:s3_error,         nil)
      |> assign(:s3_presigned,     nil)
      |> assign(:s3_roots,         [])
      |> assign(:nav_history,        [])
      |> assign(:quota_data,       nil)
      |> assign(:audit_log,        Admin.get_audit_log(20))

    if connected?(socket), do: :timer.send_interval(30_000, self(), :refresh_stats)
    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh_stats, socket) do
    {:noreply, assign(socket, :stats, Admin.dashboard_stats())}
  end

  @impl true
  def handle_params(%{"p" => page, "theme" => t}, _uri, socket) do
    theme = if t == "light", do: :light, else: :dark
    socket = assign(socket, :theme, theme)
    handle_params(%{"p" => page}, _uri, socket)
  end
  def handle_params(%{"p" => page}, _uri, socket) do
    try do
      atom = String.to_existing_atom(page)
      {:noreply, socket |> assign(:page, atom) |> reload_page_for_params(atom)}
    rescue
      _ -> {:noreply, socket}
    end
  end
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  defp reload_page_for_params(socket, page) do
    case page do
      :users             -> assign(socket, :users, Admin.list_users(%{search: socket.assigns.search, filter: socket.assigns.user_filter, sort: socket.assigns.user_sort}))
      :monitoring        -> assign(socket, :monitoring, Admin.monitoring_stats())
      :vault             -> socket |> assign(:cas_objects, Admin.list_cas_objects(%{})) |> assign(:s3_tree, Admin.s3_folder_tree())
      :duplicates        -> assign(socket, :duplicates, Admin.duplicate_analysis())
      :s3                -> socket |> assign(:s3_roots, Admin.s3_root_folders()) |> assign(:s3_result, nil) |> assign(:s3_prefix, "")
      :dashboard         -> socket |> assign(:stats, Admin.dashboard_stats()) |> assign(:audit_log, Admin.get_audit_log(20))
      :users_analytics   -> assign(socket, :analytics_users,   Admin.users_analytics())
      :storage_analytics -> assign(socket, :analytics_storage, Admin.storage_analytics())
      :cas_analytics     -> assign(socket, :analytics_cas,     Admin.cas_analytics())
      _                  -> socket
    end
  end

  # ── Theme ────────────────────────────────────────────────────────────────

  def handle_event("toggle_theme", _, socket) do
    theme = if socket.assigns.theme == :dark, do: :light, else: :dark
    {:noreply, socket
      |> assign(:theme, theme)
      |> push_event("theme_changed", %{theme: to_string(theme)})}
  end

  def handle_event("restore_theme", %{"theme" => t}, socket) do
    theme = if t == "light", do: :light, else: :dark
    {:noreply, assign(socket, :theme, theme)}
  end

  # ── Navigation ────────────────────────────────────────────────────────────

  # Back button - pops navigation history
  def handle_event("nav_back", _, socket) do
    case socket.assigns.nav_history do
      [{prev, filter} | rest] ->
        socket =
          socket
          |> assign(:page, prev)
          |> assign(:nav_history, rest)
          |> assign(:user_detail, nil)
          |> assign(:permissions, nil)
          |> assign(:flash_msg, nil)
          |> then(fn s ->
            if filter != nil, do: assign(s, :user_filter, filter), else: s
          end)
          |> reload_page(prev)
        {:noreply, socket}

      [prev | rest] ->
        socket =
          socket
          |> assign(:page, prev)
          |> assign(:nav_history, rest)
          |> assign(:user_detail, nil)
          |> assign(:permissions, nil)
          |> assign(:flash_msg, nil)
          |> reload_page(prev)
        {:noreply, socket}

      [] ->
        {:noreply, assign(socket, :page, :dashboard)}
    end
  end

  @impl true
  def handle_event("nav", %{"page" => page}, socket) do
    page_atom = String.to_existing_atom(page)
    history   = [{socket.assigns.page, nil} | socket.assigns.nav_history] |> Enum.take(10)

    socket =
      socket
      |> assign(:page, page_atom)
      |> assign(:nav_history, history)
      |> assign(:user_detail, nil)
      |> assign(:permissions, nil)
      |> assign(:flash_msg, nil)
      |> load_page_data(page_atom)

    {:noreply, socket}
  end

  # Navigate to a page AND apply a filter at the same time (e.g. dashboard → users/blocked)
  def handle_event("nav_filtered", %{"page" => page, "filter" => filter}, socket) do
    page_atom = String.to_existing_atom(page)
    history   = [{socket.assigns.page, socket.assigns.user_filter} | socket.assigns.nav_history] |> Enum.take(10)

    socket =
      socket
      |> assign(:page, page_atom)
      |> assign(:nav_history, history)
      |> assign(:user_filter, filter)
      |> assign(:user_detail, nil)
      |> assign(:permissions, nil)
      |> assign(:flash_msg, nil)
      |> load_page_data(page_atom)

    theme_str = to_string(socket.assigns.theme)
    {:noreply, push_patch(socket, to: "/admin?p=#{page_atom}&theme=#{theme_str}")}
  end

  defp load_page_data(socket, page_atom) do
    case page_atom do
      :users ->
        users = Admin.list_users(%{
          search: socket.assigns.search,
          filter: socket.assigns.user_filter,
          sort:   socket.assigns.user_sort
        })
        assign(socket, :users, users)

      :vault ->
        socket
        |> assign(:cas_objects, Admin.list_cas_objects(%{}))
        |> assign(:s3_tree, Admin.s3_folder_tree())

      :duplicates -> assign(socket, :duplicates, Admin.duplicate_analysis())
      :monitoring -> assign(socket, :monitoring, Admin.monitoring_stats())

      :s3 ->
        socket
        |> assign(:s3_roots, Admin.s3_root_folders())
        |> assign(:s3_result, nil)
        |> assign(:s3_prefix, "")

      :dashboard ->
        socket
        |> assign(:stats, Admin.dashboard_stats())
        |> assign(:audit_log, Admin.get_audit_log(20))

      :users_analytics    -> assign(socket, :analytics_users,   Admin.users_analytics())
      :storage_analytics  -> assign(socket, :analytics_storage, Admin.storage_analytics())
      :cas_analytics      -> assign(socket, :analytics_cas,     Admin.cas_analytics())
      _                   -> socket
    end
  end

  defp reload_page(socket, page), do: load_page_data(socket, page)

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
    users = Admin.list_users(%{
      search: socket.assigns.search,
      filter: socket.assigns.user_filter,
      sort:   socket.assigns.user_sort,
      page:   String.to_integer(p)
    })
    {:noreply, assign(socket, :users, users)}
  end

  def handle_event("view_user", %{"id" => id}, socket) do
    history = [{socket.assigns.page, socket.assigns.user_filter} | socket.assigns.nav_history] |> Enum.take(10)
    {:noreply,
      socket
      |> assign(:user_detail, Admin.get_user_detail(id))
      |> assign(:page, :user_detail)
      |> assign(:nav_history, history)
      |> assign(:flash_msg, nil)}
  end

  # ── Permissions ───────────────────────────────────────────────────────────

  def handle_event("view_permissions", %{"id" => id}, socket) do
    history = [{socket.assigns.page, socket.assigns.user_filter} | socket.assigns.nav_history] |> Enum.take(10)
    {:noreply,
      socket
      |> assign(:permissions, Admin.get_user_permissions(id))
      |> assign(:page, :permissions)
      |> assign(:nav_history, history)
      |> assign(:flash_msg, nil)}
  end

  def handle_event("perm_action", %{"action" => action, "user_id" => uid}, socket) do
    result =
      case action do
        "revoke_tokens"    -> Admin.revoke_all_tokens(uid);   {:ok, "All API tokens revoked"}
        "revoke_sessions"  -> Admin.revoke_all_sessions(uid); {:ok, "All sessions terminated"}
        "make_moderator"   -> Admin.set_moderator(uid, true)  |> ok_msg("Made moderator")
        "remove_moderator" -> Admin.set_moderator(uid, false) |> ok_msg("Moderator role removed")
        "block"            -> Admin.block_user(uid)           |> ok_msg("User blocked")
        "unblock"          -> Admin.unblock_user(uid)         |> ok_msg("User unblocked")
        _                  -> {:error, "Unknown action"}
      end

    {msg_type, msg} =
      case result do
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
              :users ->
                assign(s, :users, Admin.list_users(%{
                  search: s.assigns.search,
                  filter: s.assigns.user_filter,
                  sort:   s.assigns.user_sort
                }))
              :user_detail -> assign(s, :user_detail, Admin.get_user_detail(uid))
              :permissions -> assign(s, :permissions, Admin.get_user_permissions(uid))
              _ -> s
            end
          end)

        {:error, r} ->
          socket
          |> assign(:confirm_action, nil)
          |> assign(:flash_msg, {:error, "Failed: #{inspect(r)}"})
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
    cas = Admin.list_cas_objects(%{
      filter: socket.assigns.cas_filter,
      search: socket.assigns.cas_search,
      page:   String.to_integer(p)
    })
    {:noreply, assign(socket, :cas_objects, cas)}
  end


  # ── S3 ────────────────────────────────────────────────────────────────────

  def handle_event("s3_browse", %{"prefix" => prefix}, socket) do
    {:noreply, load_s3(socket, prefix)}
  end

  def handle_event("s3_back", _, socket) do
    parts  = socket.assigns.s3_prefix |> String.trim_trailing("/") |> String.split("/")
    parent = parts |> Enum.drop(-1) |> Enum.join("/")
    prefix = if parent != "", do: parent <> "/", else: ""
    socket = if prefix == "",
      do: socket |> assign(:s3_result, nil) |> assign(:s3_prefix, ""),
      else: load_s3(socket, prefix)
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


  @impl true
  def render(assigns) do
    ~H"""
    <div id="adm" class={if @theme == :dark, do: "theme-dark", else: "theme-light"} phx-hook="ThemePersist">
      <%= raw(Styles.css()) %>

      <%= if @confirm_action, do: confirm_dialog(assigns) %>
      <%= if @flash_msg,      do: flash_toast(assigns) %>

      <div class="al">
        <%= sidebar(assigns) %>
        <div class="am">
          <%= topbar(assigns) %>
          <div class="ac">
            <%= case @page do %>
              <% :dashboard         -> %> <%= AlemWeb.Admin.Pages.Dashboard.page(assigns) %>
              <% :users             -> %> <%= AlemWeb.Admin.Pages.Users.page(assigns) %>
              <% :user_detail       -> %> <%= AlemWeb.Admin.Pages.UserProfile.page(assigns) %>
              <% :permissions       -> %> <%= AlemWeb.Admin.Pages.Permissions.page(assigns) %>
              <% :monitoring        -> %> <%= AlemWeb.Admin.Pages.Monitoring.page(assigns) %>
              <% :vault             -> %> <%= AlemWeb.Admin.Pages.Storage.vault(assigns) %>
              <% :duplicates        -> %> <%= AlemWeb.Admin.Pages.Storage.duplicates(assigns) %>
              <% :s3                -> %> <%= AlemWeb.Admin.Pages.Storage.s3(assigns) %>
              <% :users_analytics   -> %> <%= AlemWeb.Admin.Pages.Analytics.users(assigns) %>
              <% :storage_analytics -> %> <%= AlemWeb.Admin.Pages.Analytics.storage(assigns) %>
              <% :cas_analytics     -> %> <%= AlemWeb.Admin.Pages.Analytics.cas(assigns) %>
              <% _                  -> %> <%= AlemWeb.Admin.Pages.Dashboard.page(assigns) %>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp sidebar(assigns) do
    ~H"""
    <aside class="sb">
      <div class="sb-top">
        <div class="sb-logo">
          <div class="lm">
            <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
              <path d="M7 1L13 4V10L7 13L1 10V4L7 1Z" stroke="white" stroke-width="1.5" fill="none"/>
              <circle cx="7" cy="7" r="2" fill="white"/>
            </svg>
          </div>
          <span class="lt">PRZMA</span>
        </div>
        <div class="sb-sub">Control Plane</div>
      </div>

      <nav class="sb-nav">
        <div class="nsl">Platform</div>
        <.ni page={:dashboard}  cur={@page} ic="grid"     lb="Dashboard" />
        <.ni page={:monitoring} cur={@page} ic="activity" lb="Monitoring" />

        <div class="nsl">Analytics</div>
        <.ni page={:users_analytics}   cur={@page} ic="trending" lb="Users" />
        <.ni page={:storage_analytics} cur={@page} ic="trending" lb="Storage" />
        <.ni page={:cas_analytics}     cur={@page} ic="trending" lb="CAS" />

        <div class="nsl">Users</div>
        <.ni page={:users}       cur={@page} ic="users"  lb="All Users"   bd={@stats.total_users} />
        <.ni page={:permissions} cur={@page} ic="shield" lb="Permissions" />

        <div class="nsl">Storage</div>
        <.ni page={:vault}      cur={@page} ic="database" lb="CAS Vault"  bd={@stats.total_cas} />
        <.ni page={:duplicates} cur={@page} ic="copy"     lb="Duplicates" bd={@stats.duplicate_cas} />
        <.ni page={:s3}         cur={@page} ic="cloud"    lb="S3 Browser" />

        <div class="nsl">Developer</div>
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
      "trending" => ~s(<polyline points="23 6 13.5 15.5 8.5 10.5 1 18"/><polyline points="17 6 23 6 23 12"/>),
    }
    svg = Map.get(icons, assigns.ic, "")
    assigns = assign(assigns, :svg, svg)
    ~H"""
    <button class={["ni", @page == @cur && "active"]} phx-click="nav" phx-value-page={@page}>
      <span class="ni-ic">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor"
             stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <%= raw(@svg) %>
        </svg>
      </span>
      <span class="ni-lb"><%= @lb %></span>
      <%= if assigns[:bd] && assigns.bd > 0 do %>
        <span class="ni-bd"><%= @bd %></span>
      <% end %>
    </button>
    """
  end

  defp topbar(assigns) do
    titles = %{
      dashboard:         "Dashboard",
      users:             "Users",
      user_detail:       "User Profile",
      permissions:       "Permissions",
      monitoring:        "Monitoring",
      vault:             "CAS Vault",
      duplicates:        "Duplicates",
      s3:                "S3 Browser",
      users_analytics:   "Users Analytics",
      storage_analytics: "Storage Analytics",
      cas_analytics:     "CAS Analytics"
    }
    assigns = assign(assigns, :page_title, Map.get(titles, assigns.page, "Admin"))
    ~H"""
    <header class="tb">
      <div class="tb-left">
        <%= if length(@nav_history) > 0 do %>
          <button class="tb-back-btn" phx-click="nav_back" title="Go back">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <line x1="19" y1="12" x2="5" y2="12"/>
              <polyline points="12 19 5 12 12 5"/>
            </svg>
          </button>
        <% end %>
        <div>
          <div class="tb-t"><%= @page_title %></div>
          <div class="tb-bc"><%= full_breadcrumb(@nav_history, @page) %></div>
        </div>
      </div>
      <div class="tb-r">
        <div class="tb-chips">
          <span class="chip chip-users" title="Total users"><%= @stats.total_users %> users</span>
          <button class="chip chip-sessions chip-btn"
                  phx-click="nav" phx-value-page="monitoring"
                  title="View active sessions">
            <%= @stats.active_sessions %> sessions
          </button>
          <%= if @stats.blocked_users > 0 do %>
            <button class="chip chip-blocked chip-btn"
                    phx-click="nav_filtered" phx-value-page="users" phx-value-filter="blocked"
                    title="View blocked users">
              <%= @stats.blocked_users %> blocked
            </button>
          <% end %>
          <span class="chip chip-brand">PRZMA</span>
        </div>
        <button class="theme-btn" phx-click="toggle_theme" title="Toggle theme">
          <%= if @theme == :dark do %>
            <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <circle cx="12" cy="12" r="5"/>
              <line x1="12" y1="1" x2="12" y2="3"/><line x1="12" y1="21" x2="12" y2="23"/>
              <line x1="4.22" y1="4.22" x2="5.64" y2="5.64"/><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"/>
              <line x1="1" y1="12" x2="3" y2="12"/><line x1="21" y1="12" x2="23" y2="12"/>
              <line x1="4.22" y1="19.78" x2="5.64" y2="18.36"/><line x1="18.36" y1="5.64" x2="19.78" y2="4.22"/>
            </svg>
          <% else %>
            <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/>
            </svg>
          <% end %>
        </button>
        <a href="#" class="logout-btn" onclick="document.getElementById('logout-form').submit();return false;">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/>
            <polyline points="16 17 21 12 16 7"/>
            <line x1="21" y1="12" x2="9" y2="12"/>
          </svg>
          Logout
        </a>
        <form id="logout-form" method="post" action="/admin/logout" style="display:none">
          <input type="hidden" name="_method" value="delete"/>
          <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()}/>
        </form>
      </div>
    </header>
    """
  end

  # Build a full breadcrumb trail from history + current page
  defp full_breadcrumb(history, current_page) do
    history_labels =
      history
      |> Enum.reverse()
      |> Enum.map(fn
        {page, _filter} -> page_label(page)
        page            -> page_label(page)
      end)
    crumbs = history_labels ++ [page_label(current_page)]
    Enum.join(crumbs, " → ")
  end

  defp page_label(:dashboard),         do: "Dashboard"
  defp page_label(:users),             do: "All Users"
  defp page_label(:user_detail),       do: "User Profile"
  defp page_label(:permissions),       do: "Permissions"
  defp page_label(:monitoring),        do: "Monitoring"
  defp page_label(:vault),             do: "CAS Vault"
  defp page_label(:duplicates),        do: "Duplicates"
  defp page_label(:s3),                do: "S3 Browser"
  defp page_label(:users_analytics),   do: "Users Analytics"
  defp page_label(:storage_analytics), do: "Storage Analytics"
  defp page_label(:cas_analytics),     do: "CAS Analytics"
  defp page_label(_),                  do: "Admin"

  # ── Back Button Component ─────────────────────────────────────────────────


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
    {ft, fm} = assigns.flash_msg
    assigns = assigns |> assign(:ft, ft) |> assign(:fm, fm)
    ~H"""
    <div class={"toast toast-#{@ft}"}>
      <span><%= @fm %></span>
      <button phx-click="dismiss_flash" style="background:none;border:none;cursor:pointer;color:inherit;opacity:.6;font-size:14px;padding:0;margin-left:8px">&#215;</button>
    </div>
    """
  end



  # ── Helpers ────────────────────────────────────────────────────────────────


  end
