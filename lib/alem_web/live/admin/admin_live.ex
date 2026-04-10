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
      |> assign(:search,           "")
      |> assign(:user_filter,      "all")
      |> assign(:user_sort,        "newest")
      |> assign(:cas_filter,       "all")
      |> assign(:cas_search,       "")
      |> assign(:confirm_action,   nil)
      |> assign(:flash_msg,        nil)
      # SQL
      |> assign(:sql_query,        "SELECT id, nickname, email, is_verified, is_active, inserted_at\nFROM users\nORDER BY inserted_at DESC\nLIMIT 20;")
      |> assign(:sql_result,       nil)
      |> assign(:sql_error,        nil)
      |> assign(:sql_running,      false)
      # S3
      |> assign(:s3_prefix,        "")
      |> assign(:s3_result,        nil)
      |> assign(:s3_error,         nil)
      |> assign(:s3_presigned,     nil)

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
    socket    = socket |> assign(:page, page_atom) |> assign(:user_detail, nil) |> assign(:flash_msg, nil)

    socket =
      case page_atom do
        :users      -> assign(socket, :users, Admin.list_users(%{search: socket.assigns.search, filter: socket.assigns.user_filter, sort: socket.assigns.user_sort}))
        :vault      -> socket |> assign(:cas_objects, Admin.list_cas_objects(%{})) |> assign(:s3_tree, Admin.s3_folder_tree())
        :duplicates -> assign(socket, :duplicates, Admin.duplicate_analysis())
        :s3         -> load_s3(socket, "")
        :dashboard  -> assign(socket, :stats, Admin.dashboard_stats())
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
        _             -> {{:error, :unknown}, "Unknown action"}
      end

    socket =
      case result do
        {:ok, _} ->
          socket
          |> assign(:confirm_action, nil)
          |> assign(:flash_msg, {:success, msg})
          |> assign(:stats, Admin.dashboard_stats())
          |> then(fn s ->
            case s.assigns.page do
              :users       -> assign(s, :users, Admin.list_users(%{search: s.assigns.search, filter: s.assigns.user_filter, sort: s.assigns.user_sort}))
              :user_detail -> assign(s, :user_detail, Admin.get_user_detail(uid))
              _            -> s
            end
          end)
        {:error, reason} ->
          socket |> assign(:confirm_action, nil) |> assign(:flash_msg, {:error, "Failed: #{inspect(reason)}"})
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

  # ── SQL Console ───────────────────────────────────────────────────────────

  def handle_event("sql_input", %{"sql" => q}, socket) do
    {:noreply, socket |> assign(:sql_query, q) |> assign(:sql_error, nil)}
  end

  def handle_event("sql_run", _, socket) do
    {result, err} =
      case Admin.run_sql(socket.assigns.sql_query) do
        {:ok, data}      -> {data, nil}
        {:error, reason} -> {nil, reason}
      end
    {:noreply, socket |> assign(:sql_result, result) |> assign(:sql_error, err) |> assign(:sql_running, false)}
  end

  def handle_event("sql_preset", %{"q" => q}, socket) do
    {:noreply, socket |> assign(:sql_query, q) |> assign(:sql_result, nil) |> assign(:sql_error, nil)}
  end

  def handle_event("sql_clear", _, socket) do
    {:noreply, socket |> assign(:sql_result, nil) |> assign(:sql_error, nil) |> assign(:sql_query, "")}
  end

  # ── S3 Browser ────────────────────────────────────────────────────────────

  def handle_event("s3_browse", %{"prefix" => prefix}, socket) do
    {:noreply, load_s3(socket, prefix)}
  end

  def handle_event("s3_back", _, socket) do
    parts  = socket.assigns.s3_prefix |> String.trim_trailing("/") |> String.split("/")
    parent = parts |> Enum.drop(-1) |> Enum.join("/")
    prefix = if parent != "", do: parent <> "/", else: ""
    {:noreply, load_s3(socket, prefix)}
  end

  def handle_event("s3_presign", %{"key" => key}, socket) do
    case Admin.s3_presigned_url(key) do
      {:ok, url}       -> {:noreply, assign(socket, :s3_presigned, %{key: key, url: url})}
      {:error, reason} -> {:noreply, assign(socket, :flash_msg, {:error, "Presign failed: #{inspect(reason)}"})}
    end
  end

  def handle_event("s3_close_presign", _, socket) do
    {:noreply, assign(socket, :s3_presigned, nil)}
  end

  def handle_event("dismiss_flash", _, socket) do
    {:noreply, assign(socket, :flash_msg, nil)}
  end

  defp load_s3(socket, prefix) do
    case Admin.list_s3_objects(prefix) do
      {:ok, data}  -> socket |> assign(:s3_result, data) |> assign(:s3_prefix, prefix) |> assign(:s3_error, nil)
      {:error, r}  -> socket |> assign(:s3_error, r)     |> assign(:s3_prefix, prefix)
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
      </div>
      <nav class="sb-nav">
        <div class="nsl">Overview</div>
        <.ni page={:dashboard}  cur={@page} ic="⬡" lb="Dashboard" />
        <.ni page={:users}      cur={@page} ic="◎" lb="Users"      bd={@stats.total_users} />
        <div class="nsl">Storage</div>
        <.ni page={:vault}      cur={@page} ic="◈" lb="CAS Vault"  bd={@stats.total_cas} />
        <.ni page={:duplicates} cur={@page} ic="◉" lb="Duplicates" bd={@stats.duplicate_cas} />
        <.ni page={:s3}         cur={@page} ic="◫" lb="S3 Browser" />
        <div class="nsl">Developer</div>
        <.ni page={:sql}        cur={@page} ic="⌘" lb="SQL Console" />
      </nav>
      <div class="sb-ft">
        <div class="sbl"><span class="dot-on"></span><%= Admin.format_bytes(@stats.total_bytes) %> stored</div>
        <div class="sbl gc"><%= Admin.format_bytes(@stats.saved_bytes) %> saved by dedup</div>
      </div>
    </aside>
    """
  end

  defp ni(assigns) do
    ~H"""
    <button class={["ni", @page == @cur && "active"]} phx-click="nav" phx-value-page={@page}>
      <span class="ni-ic"><%= @ic %></span>
      <span class="ni-lb"><%= @lb %></span>
      <%= if assigns[:bd] && assigns.bd > 0 do %>
        <span class="ni-bd"><%= @bd %></span>
      <% end %>
    </button>
    """
  end

  defp topbar(assigns) do
    t = %{dashboard: "Dashboard", users: "Users", user_detail: "User Profile",
          vault: "CAS Vault", duplicates: "Duplicates", sql: "SQL Console", s3: "S3 Browser"}
    ~H"""
    <header class="tb">
      <div class="tb-t"><%= Map.get(t, @page, "Admin") %></div>
      <div class="tb-r"><span class="tb-pill">PRZMA Admin</span></div>
    </header>
    """
  end

  # ── Dashboard ─────────────────────────────────────────────────────────────

  defp dashboard_page(assigns) do
    ~H"""
    <div>
      <div class="sg">
        <.sc lb="Total Users"    v={@stats.total_users}    ic="◎" cl="bl" />
        <.sc lb="Verified"       v={@stats.verified_users} ic="✓" cl="gn" />
        <.sc lb="Blocked"        v={@stats.blocked_users}  ic="✗" cl="rd" />
        <.sc lb="Admins"         v={@stats.admin_users}    ic="★" cl="am" />
        <.sc lb="Total Files"    v={@stats.total_files}    ic="◈" cl="pu" />
        <.sc lb="Unique Objects" v={@stats.total_cas}      ic="◆" cl="bl" />
        <.sc lb="Duplicates"     v={@stats.duplicate_cas}  ic="◉" cl="am" />
        <.sc lb="New This Week"  v={@stats.new_this_week}  ic="↑" cl="gn" />
      </div>
      <div class="dr">
        <div class="dc" style="flex:2">
          <div class="dh">Storage</div>
          <div class="str">
            <span class="sl">Total stored</span>
            <div class="sb2"><div class="sf bl" style="width:100%"></div></div>
            <span class="sv"><%= Admin.format_bytes(@stats.total_bytes) %></span>
          </div>
          <div class="str">
            <span class="sl">Saved by dedup</span>
            <div class="sb2"><div class="sf gn" style={"width:#{if @stats.total_bytes > 0, do: min(100, round(@stats.saved_bytes / @stats.total_bytes * 100)), else: 0}%"}></div></div>
            <span class="sv gc"><%= Admin.format_bytes(@stats.saved_bytes) %></span>
          </div>
        </div>
        <div class="dc">
          <div class="dh">Quick Access</div>
          <button class="qb" phx-click="nav" phx-value-page="users"><span class="qic">◎</span> Manage Users</button>
          <button class="qb" phx-click="nav" phx-value-page="vault"><span class="qic">◈</span> CAS Vault</button>
          <button class="qb" phx-click="nav" phx-value-page="s3"><span class="qic">◫</span> S3 Browser</button>
          <button class="qb" phx-click="nav" phx-value-page="sql"><span class="qic">⌘</span> SQL Console</button>
          <button class="qb" phx-click="nav" phx-value-page="duplicates"><span class="qic">◉</span> Duplicates</button>
        </div>
      </div>
    </div>
    """
  end

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
        <div class="ts"><span>⌕</span><input class="ti" placeholder="Search…" value={@search} phx-keyup="search_users" phx-debounce="300" name="search" phx-value-search={@search}/></div>
        <div class="tfs">
          <%= for {v,l} <- [{"all","All"},{"active","Active"},{"blocked","Blocked"},{"verified","Verified"},{"unverified","Unverified"},{"admin","Admins"}] do %>
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
          <thead><tr><th>User</th><th>Email</th><th>Status</th><th>Files</th><th>Joined</th><th></th></tr></thead>
          <tbody>
            <%= for u <- @users.users do %>
              <tr class="tr" phx-click="view_user" phx-value-id={u.id}>
                <td><div class="uc"><div class="ua"><%= String.first(u.nickname || "?") |> String.upcase() %></div><div><div class="un"><%= u.nickname %></div><div class="uid mono"><%= String.slice(u.id, 0, 10) %>…</div></div></div></td>
                <td class="sm mono"><%= u.email %></td>
                <td><div class="bgs"><.ub u={u}/></div></td>
                <td class="nr"><%= u.file_count %></td>
                <td class="sm"><%= fd(u.inserted_at) %></td>
                <td><button class="rb" phx-click="view_user" phx-value-id={u.id}>View</button></td>
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
          <button class="ab rd" phx-click="confirm_action" phx-value-action="hard_delete" phx-value-user_id={@user_detail.user.id} phx-value-label={"PERMANENTLY delete #{@user_detail.user.nickname}? Cannot be undone."}>Hard Delete ⚠</button>
        </div>
      </div>

      <div class="dss">
        <div class="ds"><div class="dsv"><%= @user_detail.file_count %></div><div class="dsl">Files</div></div>
        <div class="ds"><div class="dsv"><%= Admin.format_bytes(@user_detail.storage_bytes) %></div><div class="dsl">Storage</div></div>
        <div class="ds"><div class="dsv"><%= length(@user_detail.duplicates) %></div><div class="dsl">Duplicates</div></div>
        <div class="ds"><div class="dsv"><%= fd(@user_detail.user.inserted_at) %></div><div class="dsl">Joined</div></div>
      </div>

      <div class="dg">
        <div class="dp">
          <div class="dph">Files (<%= @user_detail.file_count %>)</div>
          <div class="fl">
            <%= for f <- Enum.take(@user_detail.files, 50) do %>
              <div class="fr"><span><%= ctic(f.content_type) %></span><div><div class="fn"><%= f.filename %></div><div class="fm"><%= f.status %> · <%= fd(f.inserted_at) %></div></div></div>
            <% end %>
            <%= if @user_detail.file_count == 0 do %><div class="ess">No files yet</div><% end %>
          </div>
        </div>
        <div>
          <div class="dp" style="margin-bottom:14px">
            <div class="dph">Identity (DID)</div>
            <%= if @user_detail.user.did_id do %>
              <div class="db mono"><%= @user_detail.user.did_id %></div>
              <%= if @user_detail.namespace do %>
                <div class="ir"><span>Namespace</span><span class="mono"><%= @user_detail.namespace.id %></span></div>
                <div class="ir"><span>NS Status</span><span><%= @user_detail.namespace.status %></span></div>
              <% end %>
            <% else %>
              <div class="ess">No DID assigned</div>
            <% end %>
          </div>
          <div class="dp" style="margin-bottom:14px">
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
                <div class="ir"><span><%= d.filename %></span><span><%= d.ref_count %>× · <%= Admin.format_bytes(d.file_size) %></span></div>
              <% end %>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # ── Vault Page ────────────────────────────────────────────────────────────

  defp vault_page(assigns) do
    ~H"""
    <div class="vl">
      <div class="vt">
        <div class="dph">S3 Namespaces</div>
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
                <tr class="tr">
                  <td class="mono sm"><%= String.slice(obj.content_hash, 0, 16) %>…</td>
                  <td><%= ctic(obj.media_type) %> <%= sct(obj.media_type) %></td>
                  <td class="nr"><%= Admin.format_bytes(obj.file_size) %></td>
                  <td><span class={["rb2", obj.ref_count > 1 && "dup"]}><%= obj.ref_count %></span></td>
                  <td class="mono sm"><%= String.slice(obj.namespace_key || "—", 0, 12) %></td>
                  <td class="sm"><%= fd(obj.inserted_at) %></td>
                </tr>
              <% end %>
              <%= if @cas_objects.items == [] do %><tr><td colspan="6" class="er">No objects found</td></tr><% end %>
            </tbody>
          </table>
        </div>
        <.pg d={@cas_objects} e="cas_page"/>
      </div>
    </div>
    """
  end

  # ── Duplicates ────────────────────────────────────────────────────────────

  defp duplicates_page(assigns) do
    ~H"""
    <div>
      <div class="dss">
        <div class="ds"><div class="dsv"><%= length(@duplicates.duplicates) %></div><div class="dsl">Duplicate Objects</div></div>
        <div class="ds" style="color:var(--gn)"><div class="dsv"><%= Admin.format_bytes(@duplicates.total_wasted) %></div><div class="dsl">Saved by CAS Dedup</div></div>
      </div>
      <div class="tw" style="margin-top:18px">
        <table class="tt">
          <thead><tr><th>Hash</th><th>Type</th><th>Size</th><th>Refs</th><th>Saved</th><th>Namespace</th></tr></thead>
          <tbody>
            <%= for obj <- @duplicates.duplicates do %>
              <tr class="tr">
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
    {"All users",            "SELECT id, nickname, email, is_verified, is_active, is_admin, inserted_at\nFROM users\nORDER BY inserted_at DESC\nLIMIT 20;"},
    {"Files per user",       "SELECT u.nickname, COUNT(d.id) AS files, MAX(d.inserted_at) AS last_upload\nFROM users u\nLEFT JOIN documents d ON d.user_id = u.id\nGROUP BY u.id, u.nickname\nORDER BY files DESC;"},
    {"Storage by type",      "SELECT media_type, COUNT(*) AS count, SUM(file_size) AS bytes, AVG(ref_count) AS avg_refs\nFROM cas_objects\nGROUP BY media_type\nORDER BY bytes DESC;"},
    {"Duplicates",           "SELECT content_hash, media_type, file_size, ref_count,\n       file_size * (ref_count - 1) AS saved_bytes\nFROM cas_objects\nWHERE ref_count > 1\nORDER BY ref_count DESC\nLIMIT 50;"},
    {"Active sessions",      "SELECT s.id, u.nickname, s.ip_address, s.device, s.last_active_at\nFROM sessions s\nJOIN users u ON u.id = s.user_id\nWHERE s.revoked_at IS NULL\nORDER BY s.last_active_at DESC\nLIMIT 30;"},
    {"Namespace stats",      "SELECT id, status, document_count, storage_bytes, last_activity_at\nFROM namespaces\nORDER BY storage_bytes DESC;"},
    {"Unverified users",     "SELECT id, nickname, email, inserted_at\nFROM users\nWHERE is_verified = false\nORDER BY inserted_at DESC;"},
    {"CAS objects today",    "SELECT content_hash, media_type, file_size, ref_count, inserted_at\nFROM cas_objects\nWHERE inserted_at::date = CURRENT_DATE\nORDER BY inserted_at DESC;"},
    {"OAuth tokens active",  "SELECT t.id, u.nickname, t.scopes, t.valid_until\nFROM oauth_tokens t\nJOIN users u ON u.id = t.user_id\nWHERE t.revoked_at IS NULL AND t.valid_until > NOW()\nORDER BY t.valid_until DESC\nLIMIT 20;"},
    {"Large files",          "SELECT storage_key, media_type, file_size, ref_count, inserted_at\nFROM cas_objects\nORDER BY file_size DESC\nLIMIT 25;"},
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
          <div class="dph">SQL Editor <span style="color:var(--t3);font-size:9px;font-weight:400"> — SELECT only</span></div>
          <textarea class="sqle" phx-keyup="sql_input" phx-debounce="80" name="sql" rows="9" placeholder="SELECT ..."><%= @sql_query %></textarea>
          <div class="sqltb">
            <button class="sqlrun" phx-click="sql_run" disabled={@sql_running}>
              <%= if @sql_running, do: "⟳ Running…", else: "▶ Run Query" %>
            </button>
            <button class="sqlclr" phx-click="sql_clear">✕ Clear</button>
            <span class="sqlhint">SELECT queries only · 10s timeout</span>
          </div>
        </div>
      </div>

      <div class="sqlright">
        <%= if @sql_error do %>
          <div class="sqlerr">
            <div class="sqlerrh">⚠ Error</div>
            <pre class="sqlerrm"><%= @sql_error %></pre>
          </div>
        <% end %>

        <%= if @sql_result do %>
          <div class="dp">
            <div class="dph">Result — <strong><%= @sql_result.count %></strong> rows returned</div>
            <div class="sqlscroll">
              <table class="tt">
                <thead>
                  <tr><%= for col <- @sql_result.columns do %><th><%= col %></th><% end %></tr>
                </thead>
                <tbody>
                  <%= for row <- @sql_result.rows do %>
                    <tr class="tr"><%= for cell <- row do %><td class="sqltd"><%= fmt_cell(cell) %></td><% end %></tr>
                  <% end %>
                  <%= if @sql_result.rows == [] do %>
                    <tr><td colspan={length(@sql_result.columns)} class="er">0 rows returned</td></tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          </div>
        <% end %>

        <%= if !@sql_result && !@sql_error do %>
          <div class="ph2"><div style="font-size:40px;margin-bottom:10px">⌘</div><div>Pick a preset or write a query</div><div style="color:var(--t3);font-size:12px;margin-top:6px">Only SELECT queries are permitted</div></div>
        <% end %>
      </div>
    </div>
    """
  end

  # ── S3 Browser ────────────────────────────────────────────────────────────

  defp s3_page(assigns) do
    ~H"""
    <div>
      <div class="s3bc">
        <button class="s3cb" phx-click="s3_browse" phx-value-prefix="">perkeep /</button>
        <%= for {part, _i} <- Enum.with_index(breadcrumb_parts(@s3_prefix)) do %>
          <span class="s3sep">/</span>
          <span class="s3cw"><%= part %></span>
        <% end %>
        <%= if @s3_prefix != "" do %>
          <button class="s3bk" phx-click="s3_back">↑ Up</button>
        <% end %>
        <button class="s3rf" phx-click="s3_browse" phx-value-prefix={@s3_prefix}>⟳ Refresh</button>
      </div>

      <%= if @s3_error do %>
        <div class="sqlerr"><div class="sqlerrh">S3 Error</div><pre class="sqlerrm"><%= @s3_error %></pre></div>
      <% end %>

      <%= if !@s3_result && !@s3_error do %>
        <div class="ph2"><div style="font-size:40px;margin-bottom:10px">◫</div><div>Loading bucket…</div></div>
      <% end %>

      <%= if @s3_result do %>
        <%= if @s3_result.prefixes != [] do %>
          <div class="s3sl">Folders</div>
          <div class="s3g">
            <%= for pfx <- @s3_result.prefixes do %>
              <% p = if is_map(pfx), do: pfx.prefix, else: pfx %>
              <button class="s3f" phx-click="s3_browse" phx-value-prefix={p}>
                <span class="s3fi">▸</span>
                <span class="s3fn"><%= folder_name(p, @s3_prefix) %></span>
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
                <%= for obj <- @s3_result.objects do %>
                  <% key  = if is_map(obj), do: obj.key, else: "" %>
                  <% size = if is_map(obj), do: obj.size, else: 0 %>
                  <% mod  = if is_map(obj), do: obj.last_modified, else: "" %>
                  <tr class="tr">
                    <td class="mono sm" style="max-width:380px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title={key}><%= key %></td>
                    <td class="nr sm"><%= Admin.format_bytes(parse_size(size)) %></td>
                    <td class="sm"><%= mod %></td>
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
    </div>
    """
  end

  # ── Modals & Overlays ─────────────────────────────────────────────────────

  defp confirm_dialog(assigns) do
    ~H"""
    <div class="ov">
      <div class="cb">
        <div style="font-size:26px;margin-bottom:10px">⚠</div>
        <div class="pn" style="margin-bottom:8px;font-size:15px">Confirm</div>
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
      <div class="cb" style="width:500px" phx-click-away="s3_close_presign">
        <div style="font-size:13px;font-weight:700;color:var(--gn);margin-bottom:10px">⬇ Download Link (15 min)</div>
        <div class="mono sm" style="word-break:break-all;color:var(--bl);margin-bottom:14px"><%= @s3_presigned.key %></div>
        <a href={@s3_presigned.url} target="_blank" class="sqlrun" style="display:inline-block;text-decoration:none;margin-bottom:12px">Open / Download</a>
        <br/>
        <button class="sqlclr" phx-click="s3_close_presign">Close</button>
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

  # ── Private helpers ───────────────────────────────────────────────────────

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
  defp fmt_cell(%NaiveDateTime{} = v), do: NaiveDateTime.to_string(v)
  defp fmt_cell(%DateTime{} = v),      do: DateTime.to_string(v)
  defp fmt_cell(v),                    do: inspect(v)

  defp breadcrumb_parts(""), do: []
  defp breadcrumb_parts(p),  do: p |> String.trim_trailing("/") |> String.split("/") |> Enum.with_index()

  defp folder_name(prefix, parent) do
    prefix |> String.replace_prefix(parent, "") |> String.trim_trailing("/")
  end

  defp parse_size(s) when is_binary(s), do: String.to_integer(s)
  defp parse_size(i) when is_integer(i), do: i
  defp parse_size(_), do: 0

  # ── CSS ───────────────────────────────────────────────────────────────────

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
    .al{display:grid;grid-template-columns:220px 1fr;height:100vh}

    /* Sidebar */
    .sb{background:var(--bg2);border-right:1px solid var(--bo);display:flex;flex-direction:column;overflow:hidden}
    .sb-top{padding:13px 12px;border-bottom:1px solid var(--bo);display:flex;align-items:center;gap:9px}
    .sb-logo{display:flex;align-items:center;gap:9px}
    .lm{width:27px;height:27px;background:linear-gradient(135deg,var(--bl),var(--pu));border-radius:7px;display:flex;align-items:center;justify-content:center;font-size:13px;font-weight:800;color:#fff;flex-shrink:0}
    .lt{font-size:13px;font-weight:700;letter-spacing:2px;background:linear-gradient(135deg,var(--bl),var(--pu));-webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text}
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
    .dot-on{width:7px;height:7px;border-radius:50%;background:var(--gn);box-shadow:0 0 7px rgba(0,224,160,.5);flex-shrink:0}
    .gc{color:var(--gn)}

    /* Main */
    .am{display:flex;flex-direction:column;overflow:hidden}
    .tb{height:50px;background:var(--bg2);border-bottom:1px solid var(--bo);display:flex;align-items:center;justify-content:space-between;padding:0 22px;flex-shrink:0}
    .tb-t{font-size:14px;font-weight:600}
    .tb-pill{font-size:10px;padding:3px 8px;border-radius:10px;background:rgba(74,158,255,.1);color:var(--bl);font-weight:600;letter-spacing:.5px}
    .ac{flex:1;overflow-y:auto;padding:20px}

    /* Stat cards */
    .sg{display:grid;grid-template-columns:repeat(4,1fr);gap:10px}
    .sc{background:var(--bg2);border:1px solid var(--bo);border-radius:10px;padding:14px;display:flex;align-items:center;gap:11px;transition:all .15s}
    .sc:hover{border-color:var(--bo2);transform:translateY(-1px)}
    .sc-ic{font-size:18px;opacity:.75}
    .sc-v{font-size:22px;font-weight:700;line-height:1}
    .sc-l{font-size:10px;color:var(--t2);margin-top:3px;font-weight:500}
    .sc-bl .sc-ic{color:var(--bl)}.sc-gn .sc-ic{color:var(--gn)}.sc-rd .sc-ic{color:var(--rd)}.sc-am .sc-ic{color:var(--am)}.sc-pu .sc-ic{color:var(--pu)}

    /* Dashboard */
    .dr{display:grid;grid-template-columns:2fr 1fr;gap:12px;margin-top:12px}
    .dc{background:var(--bg2);border:1px solid var(--bo);border-radius:10px;padding:16px}
    .dh{font-size:10px;font-weight:600;color:var(--t2);text-transform:uppercase;letter-spacing:.8px;margin-bottom:12px}
    .str{display:grid;grid-template-columns:100px 1fr 80px;gap:8px;align-items:center;font-size:11px;margin-bottom:10px}
    .sl{color:var(--t2)}.sb2{height:5px;background:var(--bg4);border-radius:3px;overflow:hidden}.sf{height:100%;border-radius:3px;transition:width .5s}.sf.bl{background:var(--bl)}.sf.gn{background:var(--gn)}.sv{font-weight:600;text-align:right;font-size:11px}
    .qb{background:var(--bg3);border:1px solid var(--bo);border-radius:7px;padding:8px 12px;color:var(--tx);cursor:pointer;display:flex;align-items:center;gap:8px;font-size:12px;transition:all .15s;text-align:left;width:100%;margin-bottom:7px}
    .qb:hover{background:var(--bg4);border-color:var(--bo2)}
    .qic{color:var(--bl)}

    /* Toolbar */
    .tbar{display:flex;align-items:center;gap:9px;flex-wrap:wrap}
    .ts{display:flex;align-items:center;gap:7px;background:var(--bg2);border:1px solid var(--bo);border-radius:7px;padding:5px 10px;flex:1;min-width:160px}
    .ti{background:none;border:none;outline:none;color:var(--tx);font-size:12px;width:100%}
    .ti::placeholder{color:var(--t3)}
    .tfs{display:flex;gap:5px;flex-wrap:wrap}
    .fp{background:var(--bg3);border:1px solid var(--bo);border-radius:20px;padding:3px 10px;color:var(--t2);cursor:pointer;font-size:11px;font-weight:500;transition:all .15s}
    .fp:hover{border-color:var(--bo2);color:var(--tx)}
    .fp.active{background:rgba(74,158,255,.1);border-color:rgba(74,158,255,.3);color:var(--bl)}
    .ss{background:var(--bg2);border:1px solid var(--bo);border-radius:7px;padding:5px 9px;color:var(--tx);font-size:12px;cursor:pointer;outline:none}

    /* Table */
    .tw{background:var(--bg2);border:1px solid var(--bo);border-radius:10px;overflow:hidden;margin-top:12px}
    .tt{width:100%;border-collapse:collapse}
    .tt thead th{background:var(--bg3);padding:8px 12px;font-size:10px;font-weight:600;color:var(--t2);text-align:left;letter-spacing:.5px;text-transform:uppercase;border-bottom:1px solid var(--bo)}
    .tt tbody tr{border-bottom:1px solid var(--bo);transition:background .1s}
    .tt tbody tr:last-child{border-bottom:none}
    .tr:hover{background:var(--bg3);cursor:pointer}
    .tt td{padding:9px 12px;font-size:12px;color:var(--tx)}
    .er{text-align:center;color:var(--t3);padding:32px;font-size:13px}
    .nr{text-align:right;font-weight:600;font-variant-numeric:tabular-nums}
    .sm{font-size:11px;color:var(--t2)}.mono{font-family:"SF Mono","JetBrains Mono",monospace}

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
    .rb{background:var(--bg4);border:1px solid var(--bo);border-radius:6px;padding:3px 9px;color:var(--t2);cursor:pointer;font-size:10px;font-weight:600;transition:all .15s}
    .rb:hover{background:var(--bg3);color:var(--tx)}

    /* Pagination */
    .pgn{display:flex;align-items:center;gap:10px;padding:12px;justify-content:center}
    .pb{background:var(--bg3);border:1px solid var(--bo);border-radius:6px;padding:5px 12px;color:var(--t2);cursor:pointer;font-size:12px;font-weight:500;transition:all .15s}
    .pb:hover{background:var(--bg4);color:var(--tx)}
    .pi{font-size:11px;color:var(--t3)}

    /* User detail */
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
    .ab:hover{opacity:.85;transform:translateY(-1px)}
    .dss{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin-bottom:12px}
    .ds{background:var(--bg2);border:1px solid var(--bo);border-radius:10px;padding:13px;text-align:center}
    .dsv{font-size:18px;font-weight:700;margin-bottom:3px}.dsl{font-size:10px;color:var(--t2)}
    .dg{display:grid;grid-template-columns:1fr 1fr;gap:12px}
    .dp{background:var(--bg2);border:1px solid var(--bo);border-radius:10px;overflow:hidden}
    .dph{padding:9px 13px;font-size:10px;font-weight:600;color:var(--t2);text-transform:uppercase;letter-spacing:.8px;border-bottom:1px solid var(--bo);background:var(--bg3)}
    .fl{max-height:320px;overflow-y:auto}
    .fr{display:flex;align-items:center;gap:8px;padding:8px 13px;border-bottom:1px solid var(--bo);transition:background .1s}
    .fr:last-child{border-bottom:none}.fr:hover{background:var(--bg3)}
    .fn{font-size:12px;font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    .fm{font-size:10px;color:var(--t3)}
    .es{text-align:center;color:var(--t3);padding:45px;font-size:13px}
    .ess{padding:16px;text-align:center;color:var(--t3);font-size:11px}
    .db{background:var(--bg3);padding:9px 13px;font-size:10px;color:var(--bl);font-family:"SF Mono","JetBrains Mono",monospace;word-break:break-all;border-bottom:1px solid var(--bo)}
    .ir{display:flex;justify-content:space-between;padding:7px 13px;font-size:11px;border-bottom:1px solid var(--bo)}
    .ir:last-child{border-bottom:none}

    /* Vault */
    .vl{display:grid;grid-template-columns:190px 1fr;gap:12px}
    .vt{background:var(--bg2);border:1px solid var(--bo);border-radius:10px;overflow:hidden}
    .vta{padding:8px 12px;cursor:pointer;border-bottom:1px solid var(--bo);font-size:12px;color:var(--bl);font-weight:600;transition:background .1s}
    .vta:hover{background:var(--bg3)}
    .vtn{padding:8px 12px;border-bottom:1px solid var(--bo);cursor:pointer;transition:background .1s}
    .vtn:hover{background:var(--bg3)}
    .rb2{background:var(--bg4);color:var(--t2);font-size:10px;padding:2px 6px;border-radius:10px;font-weight:600}
    .rb2.dup{background:rgba(255,184,0,.1);color:var(--am);border:1px solid rgba(255,184,0,.2)}

    /* SQL */
    .sqll{display:grid;grid-template-columns:270px 1fr;gap:12px;height:calc(100vh - 90px)}
    .sqlleft{display:flex;flex-direction:column;gap:12px;overflow-y:auto}
    .sqlright{overflow-y:auto}
    .pq{display:block;width:100%;text-align:left;background:none;border:none;border-bottom:1px solid var(--bo);padding:8px 13px;color:var(--t2);cursor:pointer;font-size:12px;transition:all .15s}
    .pq:last-child{border-bottom:none}
    .pq:hover{background:var(--bg3);color:var(--tx)}
    .sqle{width:100%;background:var(--bg3);border:none;border-top:none;padding:10px 13px;color:var(--tx);font-family:"SF Mono","JetBrains Mono",monospace;font-size:12px;line-height:1.6;resize:vertical;outline:none;min-height:130px;border-top:1px solid var(--bo)}
    .sqle:focus{border-top-color:var(--bl)}
    .sqltb{display:flex;align-items:center;gap:8px;padding:9px 13px;background:var(--bg3);border-top:1px solid var(--bo)}
    .sqlrun{background:var(--bl);color:#fff;border:none;border-radius:6px;padding:7px 14px;font-size:12px;font-weight:700;cursor:pointer;transition:all .15s}
    .sqlrun:hover{background:#3a8eef}
    .sqlrun:disabled{opacity:.5;cursor:not-allowed}
    .sqlclr{background:var(--bg4);border:1px solid var(--bo);border-radius:6px;padding:7px 11px;color:var(--t2);cursor:pointer;font-size:12px;transition:all .15s}
    .sqlclr:hover{background:var(--bg3);color:var(--tx)}
    .sqlhint{font-size:10px;color:var(--t3);margin-left:auto}
    .sqlerr{background:rgba(255,90,90,.07);border:1px solid rgba(255,90,90,.2);border-radius:10px;padding:14px;margin-bottom:12px}
    .sqlerrh{font-size:12px;font-weight:700;color:var(--rd);margin-bottom:7px}
    .sqlerrm{font-size:11px;color:var(--rd);font-family:"SF Mono","JetBrains Mono",monospace;white-space:pre-wrap;word-break:break-word}
    .sqlscroll{overflow-x:auto;max-height:58vh}
    .sqltd{font-size:11px;font-family:"SF Mono","JetBrains Mono",monospace;max-width:240px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    .ph2{text-align:center;color:var(--t3);padding:55px;font-size:13px}

    /* S3 */
    .s3bc{display:flex;align-items:center;gap:5px;margin-bottom:14px;flex-wrap:wrap;font-size:12px}
    .s3cb{background:none;border:none;color:var(--bl);cursor:pointer;font-size:12px;font-family:"SF Mono","JetBrains Mono",monospace;padding:2px 6px;border-radius:5px;transition:background .15s}
    .s3cb:hover{background:rgba(74,158,255,.1)}
    .s3sep{color:var(--t3)}
    .s3cw{color:var(--t2);font-family:"SF Mono","JetBrains Mono",monospace}
    .s3bk{background:var(--bg3);border:1px solid var(--bo);border-radius:6px;padding:3px 9px;color:var(--t2);cursor:pointer;font-size:11px;transition:all .15s}
    .s3bk:hover{color:var(--tx)}
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
    </style>
    """
  end
end
