defmodule AlemWeb.AdminLive do
  use AlemWeb, :live_view
  alias Alem.Admin
  require Logger

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page,             :dashboard)
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

  # Fallback: phx-keyup sends %{"key"=>k,"value"=>v} - ignore stale events
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
    <div id="adm">
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
        <div class="sb-logo"><div class="lm">P</div><span class="lt">PRZMA</span></div>
        <div class="sb-sub">Control Plane</div>
      </div>
      <nav class="sb-nav">
        <div class="nsl">Platform</div>
        <.ni page={:dashboard}  cur={@page} ic="⬡" lb="Dashboard" />
        <.ni page={:monitoring} cur={@page} ic="◈" lb="Monitoring" />

        <div class="nsl">Users</div>
        <.ni page={:users}      cur={@page} ic="◎" lb="All Users"     bd={@stats.total_users} />
        <.ni page={:permissions}cur={@page} ic="🔐" lb="Permissions" />

        <div class="nsl">Storage</div>
        <.ni page={:vault}      cur={@page} ic="◆" lb="CAS Vault"    bd={@stats.total_cas} />
        <.ni page={:duplicates} cur={@page} ic="◉" lb="Duplicates"   bd={@stats.duplicate_cas} />
        <.ni page={:s3}         cur={@page} ic="◫" lb="S3 Browser" />

        <div class="nsl">Developer</div>
        <.ni page={:sql}        cur={@page} ic="⌘" lb="SQL Console" />
      </nav>
      <div class="sb-ft">
        <div class="sbl"><span class="dot-on"></span><%= Admin.format_bytes(@stats.total_bytes) %> stored</div>
        <div class="sbl gc"><%= Admin.format_bytes(@stats.saved_bytes) %> dedup savings</div>
        <div class="sbl" style="color:var(--t3)"><%= @stats.active_sessions %> active sessions</div>
      </div>
    </aside>
    """
  end

  defp ni(assigns) do
    ~H"""
    <button class={["ni", @page == @cur && "active"]} phx-click="nav" phx-value-page={@page}>
      <span class="ni-ic"><%= @ic %></span>
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
      <div class="tb-t"><%= Map.get(t, @page, "Admin") %></div>
      <div class="tb-r">
        <span class="tb-stat"><%= @stats.total_users %> users</span>
        <span class="tb-stat"><%= @stats.active_sessions %> sessions</span>
        <span class="tb-pill">PRZMA Control Plane</span>
      </div>
    </header>
    """
  end

  # ── Dashboard ─────────────────────────────────────────────────────────────

  defp dashboard_page(assigns) do
    ~H"""
    <div>
      <div class="sg">
        <.sc lb="Total Users"      v={@stats.total_users}      ic="u" cl="bl" />
        <.sc lb="Verified"         v={@stats.verified_users}   ic="v" cl="gn" />
        <.sc lb="Blocked"          v={@stats.blocked_users}    ic="b" cl="rd" />
        <.sc lb="Admins"           v={@stats.admin_users}      ic="a" cl="am" />
        <.sc lb="Total Files"      v={@stats.total_files}      ic="f" cl="pu" />
        <.sc lb="CAS Objects"      v={@stats.total_cas}        ic="c" cl="bl" />
        <.sc lb="Sessions"         v={@stats.active_sessions}  ic="s" cl="gn" />
        <.sc lb="New This Week"    v={@stats.new_this_week}    ic="n" cl="am" />
      </div>

      <div class="dr" style="grid-template-columns:1.4fr 1fr">
        <!-- Left: Storage + Services -->
        <div>
          <div class="dc" style="margin-bottom:12px">
            <div class="dh">Storage Health</div>
            <div class="str">
              <span class="sl">Total stored</span>
              <div class="sb2"><div class="sf bl" style="width:100%"></div></div>
              <span class="sv"><%= Admin.format_bytes(@stats.total_bytes) %></span>
            </div>
            <div class="str">
              <span class="sl">Dedup savings</span>
              <div class="sb2">
                <div class="sf gn" style={"width:#{compute_pct(@stats.saved_bytes, @stats.total_bytes)}%"}></div>
              </div>
              <span class="sv gc"><%= Admin.format_bytes(@stats.saved_bytes) %></span>
            </div>
            <div class="str">
              <span class="sl">Duplicates</span>
              <div class="sb2">
                <div class="sf rd" style={"width:#{if @stats.total_cas > 0, do: min(100, round(@stats.duplicate_cas/@stats.total_cas*100)), else: 0}%"}></div>
              </div>
              <span class="sv" style="color:var(--rd)"><%= @stats.duplicate_cas %> objects</span>
            </div>

            <div style="margin-top:16px;padding-top:12px;border-top:1px solid var(--bo)">
              <div style="font-size:10px;font-weight:600;color:var(--t2);text-transform:uppercase;letter-spacing:.6px;margin-bottom:10px">Data Plane</div>
              <div class="dp-row"><span>Documents</span><b><%= @stats.total_files %></b></div>
              <div class="dp-row"><span>CAS Objects</span><b><%= @stats.total_cas %></b></div>
              <div class="dp-row"><span>Active Sessions</span><b><%= @stats.active_sessions %></b></div>
              <div class="dp-row"><span>Active OAuth Tokens</span><b><%= @stats.active_tokens %></b></div>
            </div>
          </div>

          <div class="dc">
            <div class="dh">Quick Actions</div>
            <button class="qb" phx-click="nav" phx-value-page="users"><span class="qi">+</span> Manage Users</button>
            <button class="qb" phx-click="nav" phx-value-page="permissions"><span class="qi">*</span> Permissions</button>
            <button class="qb" phx-click="nav" phx-value-page="monitoring"><span class="qi">~</span> Monitoring</button>
            <button class="qb" phx-click="nav" phx-value-page="s3"><span class="qi">&gt;</span> S3 Browser</button>
            <button class="qb" phx-click="nav" phx-value-page="sql"><span class="qi">&gt;</span> SQL Console</button>
          </div>
        </div>

        <!-- Right: Services + Audit -->
        <div>
          <div class="dc" style="margin-bottom:12px">
            <div class="dh">Services</div>
            <div class="svc-row"><span class="dot-on"></span><span>PostgreSQL</span><span class="sbadge gn">Online</span></div>
            <div class="svc-row"><span class="dot-on"></span><span>Linode S3 (in-maa-1)</span><span class="sbadge gn">Online</span></div>
            <div class="svc-row"><span class="dot-on"></span><span>Horde Registry</span><span class="sbadge gn">Online</span></div>
            <div class="svc-row"><span class="dot-on"></span><span>CAS Engine</span><span class="sbadge gn">Online</span></div>
            <div class="svc-row"><span class="dot-on blue"></span><span>Tokens</span><span class="sbadge bl"><%= @stats.active_tokens %></span></div>
          </div>

          <div class="dc">
            <div class="dh">Audit Log</div>
            <%= if @audit_log == [] do %>
              <div class="audit-empty">No admin actions yet this session</div>
            <% end %>
            <%= for entry <- Enum.take(@audit_log, 10) do %>
              <div class="audit-row">
                <span class="audit-action"><%= entry.action %></span>
                <%= if entry.target do %><span class="audit-target"><%= String.slice(entry.target, 0, 12) %>...</span><% end %>
                <span class="audit-time"><%= Calendar.strftime(entry.at, "%H:%M:%S") %></span>
              </div>
            <% end %>
          </div>
        </div>
      </div>
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
    ~H"""
    <div class={["sc", "sc-#{@cl}"]}>
      <div class="sc-ic"><%= @ic %></div>
      <div><div class="sc-v"><%= @v %></div><div class="sc-l"><%= @lb %></div></div>
    </div>
    """
  end

  # ── Users Page ────────────────────────────────────────────────────────────

  defp users_page(assigns) do
    ~H"""
    <div>
      <div class="tbar">
        <div class="ts"><span>⌕</span><input class="ti" placeholder="Search users…" value={@search} phx-keyup="search_users" phx-debounce="300" name="search" phx-value-search={@search}/></div>
        <div class="tfs">
          <%= for {v,l} <- [{"all","All"},{"active","Active"},{"blocked","Blocked"},{"verified","Verified"},{"unverified","Unverified"},{"admin","Admins"},{"moderator","Mods"}] do %>
            <button class={["fp", @user_filter == v && "active"]} phx-click="filter_users" phx-value-filter={v}><%= l %></button>
          <% end %>
        </div>
        <select class="ss" phx-change="sort_users" name="sort">
          <%= for {v,l} <- [{"newest","Newest"},{"oldest","Oldest"},{"files_desc","Most Files"},{"name_asc","Name A→Z"}] do %>
            <option value={v} selected={@user_sort == v}><%= l %></option>
          <% end %>
        </select>
      </div>
      <div class="tw">
        <table class="tt">
          <thead><tr><th>User</th><th>Email</th><th>Status</th><th>Files</th><th>Joined</th><th>Actions</th></tr></thead>
          <tbody>
            <%= for u <- @users.users do %>
              <tr class="trow">
                <td phx-click="view_user" phx-value-id={u.id} style="cursor:pointer">
                  <div class="uc"><div class="ua"><%= String.first(u.nickname || "?") |> String.upcase() %></div><div><div class="un"><%= u.nickname %></div><div class="uid mono"><%= String.slice(u.id, 0, 10) %>…</div></div></div>
                </td>
                <td class="sm mono"><%= u.email %></td>
                <td><div class="bgs"><.ub u={u}/></div></td>
                <td class="nr"><%= u.file_count %></td>
                <td class="sm"><%= fd(u.inserted_at) %></td>
                <td>
                  <div style="display:flex;gap:5px">
                    <button class="rb" phx-click="view_user" phx-value-id={u.id}>Profile</button>
                    <button class="rb" style="color:var(--pu);border-color:rgba(167,139,250,.3)" phx-click="view_permissions" phx-value-id={u.id}>Perms</button>
                  </div>
                </td>
              </tr>
            <% end %>
            <%= if @users.users == [] do %><tr><td colspan="6" class="er">No users found</td></tr><% end %>
          </tbody>
        </table>
      </div>
      <.pg d={@users} e="user_page"/>
    </div>
    """
  end

  defp ub(assigns) do
    ~H"""
    <%= if !@u.is_active do %><span class="b rd">Blocked</span><% else %><span class="b gn">Active</span><% end %>
    <%= if @u.is_verified do %><span class="b bl">Verified</span><% else %><span class="b gy">Unverified</span><% end %>
    <%= if @u.is_admin do %><span class="b am">Admin</span><% end %>
    <%= if Map.get(@u, :is_moderator) do %><span class="b pu">Mod</span><% end %>
    """
  end

  # ── User Detail ───────────────────────────────────────────────────────────

  defp user_detail_page(%{user_detail: nil} = assigns), do: ~H"<div class='es'>User not found</div>"
  defp user_detail_page(assigns) do
    ~H"""
    <div>
      <button class="bk" phx-click="back_to_users">← Back to Users</button>
      <div class="ph">
        <div class="pa"><%= String.first(@user_detail.user.nickname || "?") |> String.upcase() %></div>
        <div style="flex:1">
          <div class="pn"><%= @user_detail.user.nickname %></div>
          <div class="pe"><%= @user_detail.user.email %></div>
          <div class="pi mono"><%= @user_detail.user.id %></div>
          <div class="bgs"><.ub u={@user_detail.user}/></div>
        </div>
        <div class="pas">
          <button class="ab pu" phx-click="view_permissions" phx-value-id={@user_detail.user.id}>🔐 Permissions</button>
          <%= if @user_detail.user.is_active do %>
            <button class="ab rd" phx-click="confirm_action" phx-value-action="block" phx-value-user_id={@user_detail.user.id} phx-value-label={"Block #{@user_detail.user.nickname}?"}>Block</button>
          <% else %>
            <button class="ab gn" phx-click="confirm_action" phx-value-action="unblock" phx-value-user_id={@user_detail.user.id} phx-value-label={"Unblock #{@user_detail.user.nickname}?"}>Unblock</button>
          <% end %>
          <%= if @user_detail.user.is_admin do %>
            <button class="ab gy" phx-click="confirm_action" phx-value-action="demote" phx-value-user_id={@user_detail.user.id} phx-value-label={"Remove admin from #{@user_detail.user.nickname}?"}>Remove Admin</button>
          <% else %>
            <button class="ab am" phx-click="confirm_action" phx-value-action="promote" phx-value-user_id={@user_detail.user.id} phx-value-label={"Make #{@user_detail.user.nickname} admin?"}>Make Admin</button>
          <% end %>
          <button class="ab or" phx-click="confirm_action" phx-value-action="soft_delete" phx-value-user_id={@user_detail.user.id} phx-value-label={"Soft delete #{@user_detail.user.nickname}? (reversible)"}>Soft Delete</button>
          <button class="ab rd" phx-click="confirm_action" phx-value-action="hard_delete" phx-value-user_id={@user_detail.user.id} phx-value-label={"PERMANENTLY delete #{@user_detail.user.nickname}?"}>Hard Delete ⚠</button>
        </div>
      </div>

      <div class="dss">
        <div class="ds"><div class="dsv"><%= @user_detail.file_count %></div><div class="dsl">Files</div></div>
        <div class="ds"><div class="dsv"><%= Admin.format_bytes(@user_detail.storage_bytes) %></div><div class="dsl">Storage</div></div>
        <div class="ds"><div class="dsv"><%= length(@user_detail.duplicates) %></div><div class="dsl">Duplicates</div></div>
        <div class="ds"><div class="dsv"><%= length(@user_detail.sessions) %></div><div class="dsl">Sessions</div></div>
        <div class="ds"><div class="dsv"><%= length(@user_detail.tokens) %></div><div class="dsl">API Tokens</div></div>
        <div class="ds"><div class="dsv"><%= fd(@user_detail.user.inserted_at) %></div><div class="dsl">Joined</div></div>
      </div>

      <div class="dgrid3">
        <!-- Files -->
        <div class="dp">
          <div class="dph">Files (<%= @user_detail.file_count %>)</div>
          <div class="flist">
            <%= for f <- Enum.take(@user_detail.files, 50) do %>
              <div class="fr"><span><%= ctic(f.content_type) %></span><div><div class="fn"><%= f.filename %></div><div class="fm"><%= f.status %> · <%= fd(f.inserted_at) %></div></div></div>
            <% end %>
            <%= if @user_detail.file_count == 0 do %><div class="ess">No files</div><% end %>
          </div>
        </div>

        <!-- Sessions -->
        <div class="dp">
          <div class="dph">Recent Sessions</div>
          <%= for s <- @user_detail.sessions do %>
            <div class="fr" style="flex-direction:column;align-items:flex-start;gap:2px">
              <div class="fn mono" style="font-size:10px"><%= s.ip_address %> · <%= s.device %></div>
              <div class="fm">Last active: <%= fd(s.last_active_at) %> <%= if s.revoked_at, do: "· REVOKED", else: "" %></div>
            </div>
          <% end %>
          <%= if @user_detail.sessions == [] do %><div class="ess">No sessions</div><% end %>
        </div>

        <!-- Right col: DID + types + dupes -->
        <div>
          <div class="dp" style="margin-bottom:12px">
            <div class="dph">Identity</div>
            <%= if @user_detail.user.did_id do %>
              <div class="db mono"><%= @user_detail.user.did_id %></div>
              <%= if @user_detail.namespace do %>
                <div class="ir"><span>Namespace</span><span class="mono"><%= @user_detail.namespace.id %></span></div>
                <div class="ir"><span>Status</span><span><%= @user_detail.namespace.status %></span></div>
              <% end %>
            <% else %>
              <div class="ess">No DID</div>
            <% end %>
          </div>
          <div class="dp" style="margin-bottom:12px">
            <div class="dph">File Types</div>
            <%= for {ct, cnt} <- @user_detail.type_breakdown do %>
              <div class="ir"><span><%= ctic(ct) %> <%= sct(ct) %></span><span class="nr"><%= cnt %></span></div>
            <% end %>
            <%= if @user_detail.type_breakdown == %{} do %><div class="ess">No files</div><% end %>
          </div>
          <%= if length(@user_detail.duplicates) > 0 do %>
            <div class="dp">
              <div class="dph">Duplicate Files</div>
              <%= for d <- @user_detail.duplicates do %>
                <div class="ir"><span><%= d.filename %></span><span class="rd"><%= d.ref_count %>×</span></div>
              <% end %>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # ── Permissions Page ──────────────────────────────────────────────────────

  defp permissions_page(%{permissions: nil} = assigns) do
    ~H"""
    <div>
      <button class="bk" phx-click="back_from_permissions">← Back to Users</button>
      <div class="es">Select a user to manage permissions</div>
      <div class="tw" style="margin-top:20px">
        <table class="tt">
          <thead><tr><th>User</th><th>Email</th><th>Status</th><th>Actions</th></tr></thead>
          <tbody>
            <%= for u <- @users.users do %>
              <tr class="trow">
                <td><div class="uc"><div class="ua"><%= String.first(u.nickname || "?") |> String.upcase() %></div><div class="un"><%= u.nickname %></div></div></td>
                <td class="sm mono"><%= u.email %></td>
                <td><div class="bgs"><.ub u={u}/></div></td>
                <td><button class="rb" style="color:var(--pu)" phx-click="view_permissions" phx-value-id={u.id}>Manage</button></td>
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
      <button class="bk" phx-click="back_from_permissions">← Back to Users</button>

      <div class="ph">
        <div class="pa"><%= String.first(@u.nickname || "?") |> String.upcase() %></div>
        <div>
          <div class="pn"><%= @u.nickname %></div>
          <div class="pe"><%= @u.email %></div>
          <div class="pi mono"><%= @u.id %></div>
          <div class="bgs"><.ub u={@u}/></div>
        </div>
      </div>

      <div class="perm-grid">
        <!-- Access Control -->
        <div class="dp">
          <div class="dph">🔐 Access Control</div>
          <div class="perm-row">
            <div>
              <div class="perm-name">Account Active</div>
              <div class="perm-desc">User can log in and use the platform</div>
            </div>
            <div class="perm-ctrl">
              <span class={["perm-badge", if(@p.can_login, do: "on", else: "off")]}><%= if @p.can_login, do: "ENABLED", else: "DISABLED" %></span>
              <%= if @p.can_login do %>
                <button class="pact-btn rd" phx-click="perm_action" phx-value-action="block" phx-value-user_id={@u.id}>Block</button>
              <% else %>
                <button class="pact-btn gn" phx-click="perm_action" phx-value-action="unblock" phx-value-user_id={@u.id}>Unblock</button>
              <% end %>
            </div>
          </div>
          <div class="perm-row">
            <div>
              <div class="perm-name">Email Verified</div>
              <div class="perm-desc">Email address has been confirmed</div>
            </div>
            <span class={["perm-badge", if(@p.is_verified, do: "on", else: "off")]}><%= if @p.is_verified, do: "VERIFIED", else: "UNVERIFIED" %></span>
          </div>
          <div class="perm-row">
            <div>
              <div class="perm-name">Admin Role</div>
              <div class="perm-desc">Full platform administration access</div>
            </div>
            <div class="perm-ctrl">
              <span class={["perm-badge", if(@p.is_admin, do: "on", else: "off")]}><%= if @p.is_admin, do: "ADMIN", else: "USER" %></span>
              <%= if @p.is_admin do %>
                <button class="pact-btn gy" phx-click="confirm_action" phx-value-action="demote" phx-value-user_id={@u.id} phx-value-label={"Remove admin from #{@u.nickname}?"}>Remove</button>
              <% else %>
                <button class="pact-btn am" phx-click="confirm_action" phx-value-action="promote" phx-value-user_id={@u.id} phx-value-label={"Make #{@u.nickname} an admin?"}>Grant</button>
              <% end %>
            </div>
          </div>
          <div class="perm-row">
            <div>
              <div class="perm-name">Moderator Role</div>
              <div class="perm-desc">Content moderation privileges</div>
            </div>
            <div class="perm-ctrl">
              <span class={["perm-badge", if(@p.is_admin || @u.is_moderator, do: "on", else: "off")]}><%= if @p.is_admin || @u.is_moderator, do: "ENABLED", else: "NONE" %></span>
              <%= if @u.is_moderator do %>
                <button class="pact-btn gy" phx-click="perm_action" phx-value-action="remove_moderator" phx-value-user_id={@u.id}>Revoke</button>
              <% else %>
                <button class="pact-btn pu" phx-click="perm_action" phx-value-action="make_moderator" phx-value-user_id={@u.id}>Grant</button>
              <% end %>
            </div>
          </div>
        </div>

        <!-- API & Sessions -->
        <div class="dp">
          <div class="dph">🔑 API & Sessions</div>
          <div class="perm-row">
            <div>
              <div class="perm-name">Active API Tokens</div>
              <div class="perm-desc">OAuth tokens granting API access</div>
            </div>
            <div class="perm-ctrl">
              <span class={["perm-badge", if(@p.active_tokens > 0, do: "on", else: "off")]}><%= @p.active_tokens %> active</span>
              <%= if @p.active_tokens > 0 do %>
                <button class="pact-btn rd" phx-click="perm_action" phx-value-action="revoke_tokens" phx-value-user_id={@u.id}>Revoke All</button>
              <% end %>
            </div>
          </div>
          <div class="perm-row">
            <div>
              <div class="perm-name">Active Sessions</div>
              <div class="perm-desc">Browser/device sessions currently active</div>
            </div>
            <div class="perm-ctrl">
              <span class={["perm-badge", if(@p.active_sessions > 0, do: "on", else: "off")]}><%= @p.active_sessions %> active</span>
              <%= if @p.active_sessions > 0 do %>
                <button class="pact-btn rd" phx-click="perm_action" phx-value-action="revoke_sessions" phx-value-user_id={@u.id}>Kill All</button>
              <% end %>
            </div>
          </div>
        </div>

        <!-- DID / Namespace -->
        <div class="dp">
          <div class="dph">🌐 Identity & Storage</div>
          <div class="perm-row">
            <div>
              <div class="perm-name">Decentralized ID</div>
              <div class="perm-desc mono" style="font-size:10px"><%= @u.did_id || "Not assigned" %></div>
            </div>
            <span class={["perm-badge", if(@u.did_id, do: "on", else: "off")]}><%= if @u.did_id, do: "ASSIGNED", else: "NONE" %></span>
          </div>
          <div class="perm-row">
            <div>
              <div class="perm-name">API Access</div>
              <div class="perm-desc">Can authenticate via OAuth2</div>
            </div>
            <span class={["perm-badge", if(@p.api_access, do: "on", else: "off")]}><%= if @p.api_access, do: "GRANTED", else: "NO TOKENS" %></span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Monitoring Page ───────────────────────────────────────────────────────

  defp monitoring_page(%{monitoring: nil} = assigns) do
    ~H"<div class='es'>Loading monitoring data…</div>"
  end

  defp monitoring_page(assigns) do
    ~H"""
    <div>
      <!-- Storage by type -->
      <div class="dr" style="margin-bottom:20px">
        <div class="dc" style="flex:1">
          <div class="dh">Storage by File Type</div>
          <%= for t <- Enum.take(@monitoring.storage_by_type, 8) do %>
            <div class="str">
              <span class="sl"><%= ctic(t.type) %> <%= sct(t.type) %></span>
              <div class="sb2">
                <div class="sf bl" style={"width:#{if @stats.total_bytes > 0, do: min(100, round(Decimal.to_integer(Decimal.new(t.bytes)) / max(Decimal.to_integer(Decimal.new(@stats.total_bytes)), 1) * 100)), else: 0}%"}></div>
              </div>
              <span class="sv"><%= Admin.format_bytes(t.bytes) %></span>
            </div>
          <% end %>
          <%= if @monitoring.storage_by_type == [] do %><div class="ess">No data yet</div><% end %>
        </div>
      </div>

      <!-- Per-user table -->
      <div class="dh" style="margin-bottom:10px">Per-User Resource Usage</div>
      <div class="tw">
        <table class="tt">
          <thead>
            <tr>
              <th>User</th>
              <th>Status</th>
              <th>Files</th>
              <th>Storage Used</th>
              <th>Sessions</th>
              <th>Last Active</th>
              <th>Joined</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <%= for u <- @monitoring.users do %>
              <tr class="trow">
                <td>
                  <div class="uc">
                    <div class="ua"><%= String.first(u.nickname || "?") |> String.upcase() %></div>
                    <div><div class="un"><%= u.nickname %></div><div class="uid mono"><%= String.slice(u.user_id, 0, 8) %>…</div></div>
                  </div>
                </td>
                <td>
                  <%= if u.is_active do %><span class="b gn">Active</span><% else %><span class="b rd">Blocked</span><% end %>
                  <%= if u.is_verified do %><span class="b bl">Verified</span><% end %>
                </td>
                <td class="nr"><%= u.file_count %></td>
                <td class="nr">
                  <span class={[if(Decimal.to_integer(Decimal.new(u.storage_bytes)) > 100_000_000, do: "rd", else: "")]}>
                    <%= Admin.format_bytes(u.storage_bytes) %>
                  </span>
                </td>
                <td class="nr"><%= Map.get(u, :sessions, 0) %></td>
                <td class="sm"><%= fd(Map.get(u, :last_active)) %></td>
                <td class="sm"><%= fd(u.joined) %></td>
                <td>
                  <div style="display:flex;gap:4px">
                    <button class="rb" phx-click="view_user" phx-value-id={u.user_id}>Profile</button>
                    <button class="rb" style="color:var(--pu)" phx-click="view_permissions" phx-value-id={u.user_id}>Perms</button>
                  </div>
                </td>
              </tr>
            <% end %>
            <%= if @monitoring.users == [] do %><tr><td colspan="8" class="er">No users yet</td></tr><% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  # ── Vault Page ────────────────────────────────────────────────────────────

  defp vault_page(assigns) do
    ~H"""
    <div class="vl">
      <div class="vt">
        <div class="dph">Namespaces</div>
        <div class="vta" phx-click="filter_cas" phx-value-filter="all">◈ All Objects</div>
        <%= for ns <- @s3_tree do %>
          <div class="vtn"><div class="mono sm"><%= String.slice(ns.namespace_key || "—", 0, 14) %></div><div class="fm"><%= ns.file_count %> · <%= Admin.format_bytes(ns.total_bytes) %></div></div>
        <% end %>
      </div>
      <div>
        <div class="tbar" style="margin-bottom:12px">
          <div class="ts"><span>⌕</span><input class="ti" placeholder="Hash, path, type…" phx-keyup="search_cas" phx-debounce="300" name="search" phx-value-search={@cas_search} value={@cas_search}/></div>
          <div class="tfs">
            <%= for {v,l} <- [{"all","All"},{"duplicates","Dupes"},{"large",">10MB"},{"images","Images"},{"docs","Docs"}] do %>
              <button class={["fp", @cas_filter == v && "active"]} phx-click="filter_cas" phx-value-filter={v}><%= l %></button>
            <% end %>
          </div>
        </div>
        <div class="tw">
          <table class="tt">
            <thead><tr><th>Hash</th><th>Type</th><th>Size</th><th>Refs</th><th>Namespace</th><th>Stored</th></tr></thead>
            <tbody>
              <%= for obj <- @cas_objects.items do %>
                <tr class="trow">
                  <td class="mono sm"><%= String.slice(obj.content_hash, 0, 16) %>…</td>
                  <td><%= ctic(obj.media_type) %> <%= sct(obj.media_type) %></td>
                  <td class="nr"><%= Admin.format_bytes(obj.file_size) %></td>
                  <td><span class={["rb2", obj.ref_count > 1 && "dup"]}><%= obj.ref_count %></span></td>
                  <td class="mono sm"><%= String.slice(obj.namespace_key || "—", 0, 12) %></td>
                  <td class="sm"><%= fd(obj.inserted_at) %></td>
                </tr>
              <% end %>
              <%= if @cas_objects.items == [] do %><tr><td colspan="6" class="er">No objects</td></tr><% end %>
            </tbody>
          </table>
        </div>
        <.pg d={@cas_objects} e="cas_page"/>
      </div>
    </div>
    """
  end

  # ── Duplicates Page ───────────────────────────────────────────────────────

  defp duplicates_page(assigns) do
    ~H"""
    <div>
      <div class="dss">
        <div class="ds"><div class="dsv"><%= length(@duplicates.duplicates) %></div><div class="dsl">Duplicate Objects</div></div>
        <div class="ds" style="color:var(--gn)"><div class="dsv"><%= Admin.format_bytes(@duplicates.total_wasted) %></div><div class="dsl">Saved by Dedup</div></div>
      </div>
      <div class="tw" style="margin-top:18px">
        <table class="tt">
          <thead><tr><th>Hash</th><th>Type</th><th>Size</th><th>Refs</th><th>Saved</th><th>Namespace</th></tr></thead>
          <tbody>
            <%= for obj <- @duplicates.duplicates do %>
              <tr class="trow">
                <td class="mono sm"><%= String.slice(obj.content_hash, 0, 20) %>…</td>
                <td><%= ctic(obj.media_type) %> <%= sct(obj.media_type) %></td>
                <td class="nr"><%= Admin.format_bytes(obj.file_size) %></td>
                <td><span class="rb2 dup"><%= obj.ref_count %>×</span></td>
                <td class="nr" style="color:var(--gn)"><%= Admin.format_bytes(obj.file_size * (obj.ref_count - 1)) %></td>
                <td class="mono sm"><%= String.slice(obj.namespace_key || "—", 0, 12) %></td>
              </tr>
            <% end %>
            <%= if @duplicates.duplicates == [] do %><tr><td colspan="6" class="er">No duplicates — CAS is clean!</td></tr><% end %>
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
    <div class="sqll">
      <div class="sqlleft">
        <div class="dp" style="margin-bottom:12px">
          <div class="dph">Quick Queries</div>
          <%= for {label, q} <- @presets do %>
            <button class="pq" phx-click="sql_preset" phx-value-q={q}><%= label %></button>
          <% end %>
        </div>
        <div class="dp">
          <div class="dph">SQL Editor <span style="color:var(--t3);font-size:9px"> — SELECT only</span></div>
          <textarea class="sqle" phx-change="sql_input" phx-debounce="80" name="sql" rows="9" placeholder="SELECT ..."><%= @sql_query %></textarea>
          <div class="sqltb">
            <button class="sqlrun" phx-click="sql_run">▶ Run</button>
            <button class="sqlclr" phx-click="sql_clear">✕ Clear</button>
            <span class="sqlhint">SELECT only · 10s timeout</span>
          </div>
        </div>
      </div>
      <div class="sqlright">
        <%= if @sql_error do %>
          <div class="sqlerr"><div class="sqlerrh">⚠ Error</div><pre class="sqlerrm"><%= @sql_error %></pre></div>
        <% end %>
        <%= if @sql_result do %>
          <div class="dp">
            <div class="dph">Result — <strong><%= @sql_result.count %></strong> rows</div>
            <div class="sqlscroll">
              <table class="tt">
                <thead><tr><%= for col <- @sql_result.columns do %><th><%= col %></th><% end %></tr></thead>
                <tbody>
                  <%= for row <- @sql_result.rows do %>
                    <tr class="trow"><%= for cell <- row do %><td class="sqltd"><%= fmt_cell(cell) %></td><% end %></tr>
                  <% end %>
                  <%= if @sql_result.rows == [] do %><tr><td colspan={length(@sql_result.columns)} class="er">0 rows</td></tr><% end %>
                </tbody>
              </table>
            </div>
          </div>
        <% end %>
        <%= if !@sql_result && !@sql_error do %>
          <div class="ph2"><div style="font-size:36px;margin-bottom:10px">⌘</div><div>Pick a preset or write a query</div></div>
        <% end %>
      </div>
    </div>
    """
  end

  # ── S3 Browser (user/ and analytics/ only) ────────────────────────────────

  defp s3_page(assigns) do
    ~H"""
    <div>
      <%= if @s3_prefix == "" do %>
        <!-- Root: show only user/ and analytics/ -->
        <div class="dh" style="margin-bottom:16px">Scoped to platform storage paths</div>
        <div class="s3-roots">
          <%= for root <- @s3_roots do %>
            <button class="s3-root-card" phx-click="s3_browse" phx-value-prefix={root.prefix}>
              <div class="s3ri"><%= if String.starts_with?(root.prefix, "user/"), do: "◎", else: "◈" %></div>
              <div class="s3rn mono"><%= root.prefix %></div>
              <div class="s3rm"><%= root.object_count %> files · <%= root.subfolder_count %> subfolders</div>
              <div class="s3ra">Browse →</div>
            </button>
          <% end %>
        </div>
      <% else %>
        <!-- Browsing a path -->
        <div class="s3bc">
          <button class="s3cb" phx-click="s3_back">← Back</button>
          <span class="s3sep">Browsing:</span>
          <span class="s3cw mono"><%= @s3_prefix %></span>
          <button class="s3rf" phx-click="s3_browse" phx-value-prefix={@s3_prefix}>⟳ Refresh</button>
        </div>

        <%= if @s3_error do %>
          <div class="sqlerr"><div class="sqlerrh">S3 Error</div><pre class="sqlerrm"><%= @s3_error %></pre></div>
        <% end %>

        <%= if @s3_result do %>
          <%= if @s3_result.prefixes != [] do %>
            <div class="s3sl">Subfolders (<%= length(@s3_result.prefixes) %>)</div>
            <div class="s3g">
              <%= for pfx <- @s3_result.prefixes, is_map(pfx), Map.has_key?(pfx, :prefix) do %>
                <button class="s3f" phx-click="s3_browse" phx-value-prefix={pfx.prefix}>
                  <span class="s3fi">▸</span>
                  <span class="s3fn"><%= pfx.prefix |> String.replace_prefix(@s3_prefix, "") |> String.trim_trailing("/") %></span>
                </button>
              <% end %>
            </div>
          <% end %>

          <%= if @s3_result.objects != [] do %>
            <div class="s3sl" style="margin-top:20px">Files (<%= length(@s3_result.objects) %>)</div>
            <div class="tw">
              <table class="tt">
                <thead><tr><th>Key</th><th>Size</th><th>Modified</th><th></th></tr></thead>
                <tbody>
                  <%= for obj <- @s3_result.objects, is_map(obj) do %>
                    <% key = Map.get(obj, :key, "") %>
                    <tr class="trow">
                      <td class="mono sm" style="max-width:400px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title={key}><%= key %></td>
                      <td class="nr sm"><%= Admin.format_bytes(parse_size(Map.get(obj, :size, 0))) %></td>
                      <td class="sm"><%= Map.get(obj, :last_modified, "") %></td>
                      <td><button class="rb" phx-click="s3_presign" phx-value-key={key}>⬇ Link</button></td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>

          <%= if @s3_result.objects == [] && @s3_result.prefixes == [] do %>
            <div class="es">Folder is empty</div>
          <% end %>
        <% end %>
      <% end %>
    </div>
    """
  end

  # ── Shared Components ──────────────────────────────────────────────────────

  defp confirm_dialog(assigns) do
    ~H"""
    <div class="ov">
      <div class="cb">
        <div style="font-size:26px;margin-bottom:10px">⚠</div>
        <div class="pn" style="margin-bottom:8px;font-size:15px">Confirm Action</div>
        <div style="font-size:13px;color:var(--t2);margin-bottom:20px;line-height:1.5"><%= @confirm_action.label %></div>
        <div style="display:flex;gap:10px;justify-content:center">
          <button class="cg" phx-click="cancel_confirm">Cancel</button>
          <button class="cd" phx-click="execute_confirm">Confirm</button>
        </div>
      </div>
    </div>
    """
  end

  defp flash_toast(assigns) do
    {type, msg} = assigns.flash_msg
    ~H"""
    <div class={["ft", "ft-#{type}"]}>
      <span><%= msg %></span>
      <button phx-click="dismiss_flash" style="background:none;border:none;cursor:pointer;color:inherit;opacity:.6;font-size:14px">✕</button>
    </div>
    """
  end

  defp presign_modal(assigns) do
    ~H"""
    <div class="ov" phx-click="s3_close_presign">
      <div class="cb" style="width:500px">
        <div style="font-size:13px;font-weight:700;color:var(--gn);margin-bottom:10px">⬇ Download Link (15 min)</div>
        <div class="mono sm" style="word-break:break-all;color:var(--bl);margin-bottom:14px"><%= @s3_presigned.key %></div>
        <a href={@s3_presigned.url} target="_blank" class="sqlrun" style="display:inline-block;text-decoration:none;margin-bottom:12px">Open / Download</a>
        <br/><button class="sqlclr" phx-click="s3_close_presign">Close</button>
      </div>
    </div>
    """
  end

  defp pg(%{d: %{pages: p}} = assigns) when p > 1 do
    ~H"""
    <div class="pgn">
      <%= if @d.page > 1 do %><button class="pb" phx-click={@e} phx-value-page={@d.page - 1}>‹ Prev</button><% end %>
      <span class="pi">Page <%= @d.page %> of <%= @d.pages %> · <%= @d.total %> total</span>
      <%= if @d.page < @d.pages do %><button class="pb" phx-click={@e} phx-value-page={@d.page + 1}>Next ›</button><% end %>
    </div>
    """
  end
  defp pg(assigns), do: ~H""

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
    *{margin:0;padding:0;box-sizing:border-box}
    :root{
      --bg:#0a0a0f;--bg2:#111118;--bg3:#18181f;--bg4:#1e1e28;
      --bo:rgba(255,255,255,.07);--bo2:rgba(255,255,255,.12);
      --tx:#e8e8f0;--t2:#9898b0;--t3:#5a5a72;
      --bl:#4a9eff;--gn:#00e0a0;--rd:#ff5a5a;--am:#ffb800;--pu:#a78bfa;--or:#ff8c42;
      font-family:-apple-system,BlinkMacSystemFont,"SF Pro Display","Segoe UI",sans-serif;
    }
    #adm{height:100vh;background:var(--bg);color:var(--tx);overflow:hidden}
    .al{display:grid;grid-template-columns:230px 1fr;height:100vh}

    /* Sidebar */
    .sb{background:var(--bg2);border-right:1px solid var(--bo);display:flex;flex-direction:column;overflow:hidden}
    .sb-top{padding:14px 14px 8px;border-bottom:1px solid var(--bo)}
    .sb-logo{display:flex;align-items:center;gap:9px;margin-bottom:2px}
    .lm{width:28px;height:28px;background:linear-gradient(135deg,var(--bl),var(--pu));border-radius:7px;display:flex;align-items:center;justify-content:center;font-size:13px;font-weight:800;color:#fff;flex-shrink:0}
    .lt{font-size:14px;font-weight:700;letter-spacing:2px;background:linear-gradient(135deg,var(--bl),var(--pu));-webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text}
    .sb-sub{font-size:9px;color:var(--t3);letter-spacing:1.5px;text-transform:uppercase;padding-left:37px}
    .sb-nav{flex:1;padding:8px;overflow-y:auto}
    .nsl{font-size:9px;font-weight:700;color:var(--t3);letter-spacing:1.2px;text-transform:uppercase;padding:10px 10px 3px}
    .ni{display:flex;align-items:center;gap:8px;padding:7px 10px;border-radius:6px;border:none;background:none;color:var(--t2);cursor:pointer;width:100%;text-align:left;font-size:12px;font-weight:500;transition:all .15s;white-space:nowrap}
    .ni:hover{background:var(--bg3);color:var(--tx)}
    .ni.active{background:rgba(74,158,255,.1);color:var(--bl)}
    .ni-ic{font-size:13px;width:17px;text-align:center;flex-shrink:0}
    .ni-lb{flex:1}
    .ni-bd{background:var(--bg4);color:var(--t3);font-size:10px;padding:1px 6px;border-radius:10px;font-weight:600}
    .ni.active .ni-bd{background:rgba(74,158,255,.12);color:var(--bl)}
    .sb-ft{padding:10px 12px;border-top:1px solid var(--bo);font-size:11px;color:var(--t3)}
    .sbl{display:flex;align-items:center;gap:6px;margin-bottom:3px}
    .dot-on{width:6px;height:6px;border-radius:50%;background:var(--gn);box-shadow:0 0 6px rgba(0,224,160,.5);flex-shrink:0}
    .gc{color:var(--gn)}

    /* Main */
    .am{display:flex;flex-direction:column;overflow:hidden}
    .tb{height:50px;background:var(--bg2);border-bottom:1px solid var(--bo);display:flex;align-items:center;justify-content:space-between;padding:0 22px;flex-shrink:0}
    .tb-t{font-size:14px;font-weight:600}
    .tb-r{display:flex;align-items:center;gap:10px}
    .tb-stat{font-size:11px;color:var(--t2)}
    .tb-pill{font-size:10px;padding:3px 8px;border-radius:10px;background:rgba(74,158,255,.1);color:var(--bl);font-weight:600;letter-spacing:.5px}
    .ac{flex:1;overflow-y:auto;padding:20px}

    /* Stat cards */
    .sg{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin-bottom:16px}
    .sc{background:var(--bg2);border:1px solid var(--bo);border-radius:10px;padding:14px;display:flex;align-items:center;gap:11px;transition:all .15s}
    .sc:hover{border-color:var(--bo2);transform:translateY(-1px)}
    .sc-ic{font-size:18px;opacity:.75}
    .sc-v{font-size:22px;font-weight:700;line-height:1}
    .sc-l{font-size:10px;color:var(--t2);margin-top:3px;font-weight:500}
    .sc-bl .sc-ic{color:var(--bl)}.sc-gn .sc-ic{color:var(--gn)}.sc-rd .sc-ic{color:var(--rd)}.sc-am .sc-ic{color:var(--am)}.sc-pu .sc-ic{color:var(--pu)}

    /* Dashboard */
    .dr{display:grid;grid-template-columns:repeat(3,1fr);gap:12px}
    .dc{background:var(--bg2);border:1px solid var(--bo);border-radius:10px;padding:16px}
    .dh{font-size:10px;font-weight:600;color:var(--t2);text-transform:uppercase;letter-spacing:.8px;margin-bottom:12px}
    .str{display:grid;grid-template-columns:90px 1fr 80px;gap:8px;align-items:center;font-size:11px;margin-bottom:10px}
    .sl{color:var(--t2)}.sb2{height:5px;background:var(--bg4);border-radius:3px;overflow:hidden}.sf{height:100%;border-radius:3px;transition:width .5s}.sf.bl{background:var(--bl)}.sf.gn{background:var(--gn)}.sf.rd{background:var(--rd)}.sv{font-weight:600;text-align:right;font-size:11px}
    .status-row{display:flex;align-items:center;gap:8px;padding:6px 0;font-size:12px;border-bottom:1px solid var(--bo)}
    .status-row:last-child{border-bottom:none}
    .status-row span:nth-child(2){flex:1}
    .sbadge{font-size:10px;padding:2px 7px;border-radius:10px;font-weight:600}
    .sbadge.gn{background:rgba(0,224,160,.1);color:var(--gn)}
    .sbadge.bl{background:rgba(74,158,255,.1);color:var(--bl)}
    .qb{background:var(--bg3);border:1px solid var(--bo);border-radius:7px;padding:8px 12px;color:var(--tx);cursor:pointer;display:flex;align-items:center;gap:8px;font-size:12px;transition:all .15s;text-align:left;width:100%;margin-bottom:7px}
    .qb:hover{background:var(--bg4);border-color:var(--bo2)}
    .qic{color:var(--bl)}

    /* Toolbar */
    .tbar{display:flex;align-items:center;gap:9px;flex-wrap:wrap;margin-bottom:12px}
    .ts{display:flex;align-items:center;gap:7px;background:var(--bg2);border:1px solid var(--bo);border-radius:7px;padding:5px 10px;flex:1;min-width:160px}
    .ti{background:none;border:none;outline:none;color:var(--tx);font-size:12px;width:100%}
    .ti::placeholder{color:var(--t3)}
    .tfs{display:flex;gap:5px;flex-wrap:wrap}
    .fp{background:var(--bg3);border:1px solid var(--bo);border-radius:20px;padding:3px 10px;color:var(--t2);cursor:pointer;font-size:11px;font-weight:500;transition:all .15s}
    .fp:hover{border-color:var(--bo2);color:var(--tx)}
    .fp.active{background:rgba(74,158,255,.1);border-color:rgba(74,158,255,.3);color:var(--bl)}
    .ss{background:var(--bg2);border:1px solid var(--bo);border-radius:7px;padding:5px 9px;color:var(--tx);font-size:12px;cursor:pointer;outline:none}

    /* Table */
    .tw{background:var(--bg2);border:1px solid var(--bo);border-radius:10px;overflow:hidden}
    .tt{width:100%;border-collapse:collapse}
    .tt thead th{background:var(--bg3);padding:8px 12px;font-size:10px;font-weight:600;color:var(--t2);text-align:left;letter-spacing:.5px;text-transform:uppercase;border-bottom:1px solid var(--bo)}
    .tt tbody tr{border-bottom:1px solid var(--bo);transition:background .1s}
    .tt tbody tr:last-child{border-bottom:none}
    .trow:hover{background:var(--bg3)}
    .tt td{padding:9px 12px;font-size:12px;color:var(--tx)}
    .er{text-align:center;color:var(--t3);padding:32px;font-size:13px}
    .nr{text-align:right;font-weight:600;font-variant-numeric:tabular-nums}
    .sm{font-size:11px;color:var(--t2)}.mono{font-family:"SF Mono","JetBrains Mono",monospace}
    .rd{color:var(--rd)}

    /* User cells */
    .uc{display:flex;align-items:center;gap:8px}
    .ua{width:28px;height:28px;border-radius:50%;background:linear-gradient(135deg,var(--bl),var(--pu));display:flex;align-items:center;justify-content:center;font-size:11px;font-weight:700;color:#fff;flex-shrink:0}
    .un{font-size:12px;font-weight:600}.uid{color:var(--t3);font-size:10px}
    .bgs{display:flex;gap:3px;flex-wrap:wrap}
    .b{font-size:9px;padding:2px 6px;border-radius:10px;font-weight:600}
    .b.gn{background:rgba(0,224,160,.1);color:var(--gn);border:1px solid rgba(0,224,160,.2)}
    .b.rd{background:rgba(255,90,90,.1);color:var(--rd);border:1px solid rgba(255,90,90,.2)}
    .b.bl{background:rgba(74,158,255,.1);color:var(--bl);border:1px solid rgba(74,158,255,.2)}
    .b.gy{background:var(--bg4);color:var(--t3);border:1px solid var(--bo)}
    .b.am{background:rgba(255,184,0,.1);color:var(--am);border:1px solid rgba(255,184,0,.2)}
    .b.pu{background:rgba(167,139,250,.1);color:var(--pu);border:1px solid rgba(167,139,250,.2)}
    .rb{background:var(--bg4);border:1px solid var(--bo);border-radius:6px;padding:3px 9px;color:var(--t2);cursor:pointer;font-size:10px;font-weight:600;transition:all .15s}
    .rb:hover{background:var(--bg3);color:var(--tx)}
    .rb2{background:var(--bg4);color:var(--t2);font-size:10px;padding:2px 6px;border-radius:10px;font-weight:600}
    .rb2.dup{background:rgba(255,184,0,.1);color:var(--am);border:1px solid rgba(255,184,0,.2)}

    /* Pagination */
    .pgn{display:flex;align-items:center;gap:10px;padding:12px;justify-content:center}
    .pb{background:var(--bg3);border:1px solid var(--bo);border-radius:6px;padding:5px 12px;color:var(--t2);cursor:pointer;font-size:12px;font-weight:500;transition:all .15s}
    .pb:hover{background:var(--bg4);color:var(--tx)}
    .pi{font-size:11px;color:var(--t3)}

    /* User Detail */
    .bk{background:none;border:none;color:var(--t2);cursor:pointer;font-size:12px;margin-bottom:16px;padding:0;transition:color .15s}
    .bk:hover{color:var(--tx)}
    .ph{background:var(--bg2);border:1px solid var(--bo);border-radius:10px;padding:20px;display:flex;align-items:flex-start;gap:16px;margin-bottom:12px}
    .pa{width:52px;height:52px;border-radius:50%;background:linear-gradient(135deg,var(--bl),var(--pu));display:flex;align-items:center;justify-content:center;font-size:20px;font-weight:700;color:#fff;flex-shrink:0}
    .pn{font-size:16px;font-weight:700;margin-bottom:3px}
    .pe{font-size:12px;color:var(--t2);margin-bottom:2px}
    .pi{font-size:10px;color:var(--t3);margin-bottom:7px;font-family:"SF Mono","JetBrains Mono",monospace}
    .pas{display:flex;flex-direction:column;gap:6px;flex-shrink:0}
    .ab{padding:6px 13px;border-radius:6px;border:none;cursor:pointer;font-size:11px;font-weight:600;transition:all .15s}
    .ab.gn{background:rgba(0,224,160,.1);color:var(--gn);border:1px solid rgba(0,224,160,.2)}
    .ab.rd{background:rgba(255,90,90,.1);color:var(--rd);border:1px solid rgba(255,90,90,.2)}
    .ab.am{background:rgba(255,184,0,.1);color:var(--am);border:1px solid rgba(255,184,0,.2)}
    .ab.gy{background:var(--bg4);color:var(--t2);border:1px solid var(--bo)}
    .ab.or{background:rgba(255,140,66,.1);color:var(--or);border:1px solid rgba(255,140,66,.2)}
    .ab.pu{background:rgba(167,139,250,.1);color:var(--pu);border:1px solid rgba(167,139,250,.2)}
    .ab:hover{opacity:.85;transform:translateY(-1px)}
    .dss{display:grid;grid-template-columns:repeat(6,1fr);gap:10px;margin-bottom:12px}
    .ds{background:var(--bg2);border:1px solid var(--bo);border-radius:10px;padding:12px;text-align:center}
    .dsv{font-size:16px;font-weight:700;margin-bottom:3px}.dsl{font-size:10px;color:var(--t2)}
    .dgrid3{display:grid;grid-template-columns:1fr 1fr 1fr;gap:12px}
    .dp{background:var(--bg2);border:1px solid var(--bo);border-radius:10px;overflow:hidden}
    .dph{padding:9px 13px;font-size:10px;font-weight:600;color:var(--t2);text-transform:uppercase;letter-spacing:.8px;border-bottom:1px solid var(--bo);background:var(--bg3)}
    .flist{max-height:300px;overflow-y:auto}
    .fr{display:flex;align-items:center;gap:8px;padding:8px 13px;border-bottom:1px solid var(--bo);transition:background .1s;font-size:12px}
    .fr:last-child{border-bottom:none}.fr:hover{background:var(--bg3)}
    .fn{font-size:12px;font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    .fm{font-size:10px;color:var(--t3)}
    .es{text-align:center;color:var(--t3);padding:45px;font-size:13px}
    .ess{padding:16px;text-align:center;color:var(--t3);font-size:11px}
    .db{background:var(--bg3);padding:9px 13px;font-size:10px;color:var(--bl);font-family:"SF Mono","JetBrains Mono",monospace;word-break:break-all;border-bottom:1px solid var(--bo)}
    .ir{display:flex;justify-content:space-between;align-items:center;padding:7px 13px;font-size:12px;border-bottom:1px solid var(--bo)}
    .ir:last-child{border-bottom:none}

    /* Permissions */
    .perm-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:14px;margin-top:4px}
    .perm-row{display:flex;justify-content:space-between;align-items:center;padding:12px 14px;border-bottom:1px solid var(--bo)}
    .perm-row:last-child{border-bottom:none}
    .perm-name{font-size:13px;font-weight:600;margin-bottom:2px}
    .perm-desc{font-size:10px;color:var(--t3)}
    .perm-ctrl{display:flex;align-items:center;gap:6px}
    .perm-badge{font-size:9px;padding:3px 8px;border-radius:10px;font-weight:700;letter-spacing:.3px;white-space:nowrap}
    .perm-badge.on{background:rgba(0,224,160,.12);color:var(--gn);border:1px solid rgba(0,224,160,.25)}
    .perm-badge.off{background:var(--bg4);color:var(--t3);border:1px solid var(--bo)}
    .pact-btn{font-size:10px;padding:4px 10px;border-radius:6px;border:none;cursor:pointer;font-weight:700;transition:all .15s;white-space:nowrap}
    .pact-btn.rd{background:rgba(255,90,90,.12);color:var(--rd);border:1px solid rgba(255,90,90,.25)}
    .pact-btn.gn{background:rgba(0,224,160,.12);color:var(--gn);border:1px solid rgba(0,224,160,.25)}
    .pact-btn.am{background:rgba(255,184,0,.12);color:var(--am);border:1px solid rgba(255,184,0,.25)}
    .pact-btn.pu{background:rgba(167,139,250,.12);color:var(--pu);border:1px solid rgba(167,139,250,.25)}
    .pact-btn.gy{background:var(--bg4);color:var(--t2);border:1px solid var(--bo)}
    .pact-btn:hover{opacity:.8;transform:translateY(-1px)}

    /* Vault */
    .vl{display:grid;grid-template-columns:190px 1fr;gap:12px}
    .vt{background:var(--bg2);border:1px solid var(--bo);border-radius:10px;overflow:hidden}
    .vta{padding:8px 12px;cursor:pointer;border-bottom:1px solid var(--bo);font-size:12px;color:var(--bl);font-weight:600;transition:background .1s}
    .vta:hover{background:var(--bg3)}
    .vtn{padding:8px 12px;border-bottom:1px solid var(--bo);cursor:pointer;transition:background .1s}
    .vtn:hover{background:var(--bg3)}

    /* Monitoring */
    .dgrid{display:grid;grid-template-columns:1fr 1fr;gap:12px}

    /* SQL */
    .sqll{display:grid;grid-template-columns:260px 1fr;gap:12px;height:calc(100vh - 90px)}
    .sqlleft{display:flex;flex-direction:column;gap:12px;overflow-y:auto}
    .sqlright{overflow-y:auto}
    .pq{display:block;width:100%;text-align:left;background:none;border:none;border-bottom:1px solid var(--bo);padding:8px 13px;color:var(--t2);cursor:pointer;font-size:12px;transition:all .15s}
    .pq:last-child{border-bottom:none}.pq:hover{background:var(--bg3);color:var(--tx)}
    .sqle{width:100%;background:var(--bg3);border:none;border-top:1px solid var(--bo);padding:10px 13px;color:var(--tx);font-family:"SF Mono","JetBrains Mono",monospace;font-size:12px;line-height:1.6;resize:vertical;outline:none;min-height:130px}
    .sqle:focus{border-top-color:var(--bl)}
    .sqltb{display:flex;align-items:center;gap:8px;padding:9px 13px;background:var(--bg3);border-top:1px solid var(--bo)}
    .sqlrun{background:var(--bl);color:#fff;border:none;border-radius:6px;padding:7px 14px;font-size:12px;font-weight:700;cursor:pointer;transition:all .15s}
    .sqlrun:hover{background:#3a8eef}
    .sqlclr{background:var(--bg4);border:1px solid var(--bo);border-radius:6px;padding:7px 11px;color:var(--t2);cursor:pointer;font-size:12px;transition:all .15s}
    .sqlclr:hover{background:var(--bg3);color:var(--tx)}
    .sqlhint{font-size:10px;color:var(--t3);margin-left:auto}
    .sqlerr{background:rgba(255,90,90,.07);border:1px solid rgba(255,90,90,.2);border-radius:10px;padding:14px;margin-bottom:12px}
    .sqlerrh{font-size:12px;font-weight:700;color:var(--rd);margin-bottom:7px}
    .sqlerrm{font-size:11px;color:var(--rd);font-family:"SF Mono","JetBrains Mono",monospace;white-space:pre-wrap}
    .sqlscroll{overflow-x:auto;max-height:58vh}
    .sqltd{font-size:11px;font-family:"SF Mono","JetBrains Mono",monospace;max-width:220px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    .ph2{text-align:center;color:var(--t3);padding:55px;font-size:13px}

    /* S3 */
    .s3-roots{display:grid;grid-template-columns:repeat(2,1fr);gap:16px;max-width:600px}
    .s3-root-card{background:var(--bg2);border:1px solid var(--border2,rgba(255,255,255,.12));border-radius:12px;padding:24px;cursor:pointer;text-align:left;transition:all .2s;display:flex;flex-direction:column;gap:6px;position:relative;overflow:hidden}
    .s3-root-card::before{content:'';position:absolute;top:0;left:0;right:0;height:2px;background:linear-gradient(90deg,var(--bl),var(--pu))}
    .s3-root-card:hover{border-color:rgba(74,158,255,.3);transform:translateY(-2px);box-shadow:0 8px 24px rgba(0,0,0,.3)}
    .s3ri{font-size:28px;margin-bottom:4px;color:var(--bl)}
    .s3rn{font-size:16px;font-weight:700;color:var(--tx);font-family:"SF Mono","JetBrains Mono",monospace}
    .s3rm{font-size:12px;color:var(--t2)}
    .s3ra{font-size:11px;color:var(--bl);font-weight:600;margin-top:4px}
    .s3bc{display:flex;align-items:center;gap:8px;margin-bottom:16px;font-size:12px;flex-wrap:wrap}
    .s3cb{background:var(--bg3);border:1px solid var(--bo);border-radius:6px;padding:4px 12px;color:var(--t2);cursor:pointer;font-size:12px;transition:all .15s}
    .s3cb:hover{color:var(--tx)}
    .s3sep{color:var(--t3)}
    .s3cw{color:var(--bl);font-family:"SF Mono","JetBrains Mono",monospace}
    .s3rf{background:none;border:1px solid var(--bo);border-radius:6px;padding:3px 9px;color:var(--t3);cursor:pointer;font-size:11px;transition:all .15s}
    .s3rf:hover{color:var(--tx)}
    .s3sl{font-size:10px;font-weight:600;color:var(--t3);text-transform:uppercase;letter-spacing:.8px;margin-bottom:7px}
    .s3g{display:grid;grid-template-columns:repeat(auto-fill,minmax(170px,1fr));gap:7px}
    .s3f{background:var(--bg2);border:1px solid var(--bo);border-radius:8px;padding:10px 12px;cursor:pointer;display:flex;align-items:center;gap:8px;text-align:left;transition:all .15s;font-size:12px;color:var(--tx)}
    .s3f:hover{background:var(--bg3);border-color:var(--bo2)}
    .s3fi{color:var(--bl);font-size:12px}
    .s3fn{font-weight:500;font-family:"SF Mono","JetBrains Mono",monospace;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}

    /* Modals */
    .ov{position:fixed;inset:0;background:rgba(0,0,0,.75);z-index:1000;display:flex;align-items:center;justify-content:center;backdrop-filter:blur(4px)}
    .cb{background:var(--bg2);border:1px solid var(--bo2);border-radius:14px;padding:24px;width:350px;text-align:center;box-shadow:0 20px 60px rgba(0,0,0,.6)}
    .cg{background:var(--bg4);border:1px solid var(--bo);border-radius:6px;padding:7px 16px;color:var(--t2);cursor:pointer;font-size:12px;font-weight:600;transition:all .15s}
    .cg:hover{background:var(--bg3);color:var(--tx)}
    .cd{background:rgba(255,90,90,.15);border:1px solid rgba(255,90,90,.3);border-radius:6px;padding:7px 16px;color:var(--rd);cursor:pointer;font-size:12px;font-weight:700;transition:all .15s}
    .cd:hover{background:rgba(255,90,90,.25)}
    .ft{position:fixed;top:16px;right:16px;z-index:2000;background:var(--bg2);border:1px solid var(--bo2);border-radius:10px;padding:10px 14px;display:flex;align-items:center;gap:9px;font-size:12px;box-shadow:0 8px 28px rgba(0,0,0,.4);animation:fi .3s ease}
    .ft-success{border-color:rgba(0,224,160,.3);color:var(--gn)}
    .ft-error{border-color:rgba(255,90,90,.3);color:var(--rd)}
    @keyframes fi{from{transform:translateX(40px);opacity:0}to{transform:translateX(0);opacity:1}}

    /* Dashboard extras */
    .dp-row{display:flex;justify-content:space-between;align-items:center;padding:5px 0;border-bottom:1px solid var(--bo);font-size:12px}
    .dp-row:last-child{border-bottom:none}
    .dp-row span{color:var(--t2)}
    .dp-row b{font-family:monospace;font-size:11px}
    .svc-row{display:flex;align-items:center;gap:8px;padding:6px 0;border-bottom:1px solid var(--bo);font-size:12px}
    .svc-row:last-child{border-bottom:none}
    .svc-row span:nth-child(2){flex:1;color:var(--t2)}
    .sbadge.bl{background:rgba(74,158,255,.1);color:var(--bl)}
    .dot-on{width:6px;height:6px;border-radius:50%;background:var(--gn);box-shadow:0 0 5px rgba(0,224,160,.5);flex-shrink:0}
    .dot-on.blue{background:var(--bl);box-shadow:0 0 5px rgba(74,158,255,.4)}
    .qi{font-size:11px;opacity:.7}
    .audit-row{display:flex;align-items:center;gap:6px;padding:5px 0;border-bottom:1px solid var(--bo);font-size:11px}
    .audit-row:last-child{border-bottom:none}
    .audit-action{flex:1;font-weight:600;color:var(--tx)}
    .audit-target{color:var(--t3);font-family:monospace;font-size:10px}
    .audit-time{color:var(--t3);font-size:10px;white-space:nowrap}
    .audit-empty{padding:12px;text-align:center;color:var(--t3);font-size:11px}
    </style>
    """
  end
end
