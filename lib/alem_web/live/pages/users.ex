defmodule AlemWeb.Admin.Pages.Users do
  @moduledoc "Users list: search, filter, sort, pagination. Shares user_badges/1 with other pages."
  use Phoenix.Component
  import AlemWeb.Admin.Helpers
  import AlemWeb.Admin.Components
  alias Alem.Admin

  def page(assigns) do
    filter_label =
      case assigns.user_filter do
        "all"        -> "All Users"
        "active"     -> "Active Users"
        "blocked"    -> "Blocked Users"
        "verified"   -> "Verified Users"
        "unverified" -> "Unverified Users"
        "admin"      -> "Admins"
        "moderator"  -> "Moderators"
        _            -> "Users"
      end
    assigns = assign(assigns, :filter_label, filter_label)
    ~H"""
    <div>
      <!-- Page header with context -->
      <div class="page-header">
        <div>
          <div class="page-title-row">
            <h2 class="page-heading"><%= @filter_label %></h2>
            <span class="page-count-badge"><%= @users.total %> total</span>
          </div>
          <div class="page-sub">
            <%= if @user_filter != "all" do %>
              Filtered: <strong><%= @filter_label %></strong> ·
              <button class="inline-link" phx-click="filter_users" phx-value-filter="all">Clear filter</button>
            <% else %>
              All registered users on the platform
            <% end %>
          </div>
        </div>
        <!-- Filter quick-jump pills at top -->
        <div class="filter-shortcuts">
          <%= for {v,l,col} <- [{"blocked","Blocked","red"},{"admin","Admins","amber"},{"verified","Verified","green"},{"unverified","Unverified","gray"}] do %>
            <button class={["fsc fsc-#{col}", @user_filter == v && "active"]}
                    phx-click="filter_users" phx-value-filter={v}>
              <%= l %>
            </button>
          <% end %>
        </div>
      </div>

      <div class="toolbar">
        <div class="search-box">
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/>
          </svg>
          <input class="search-input" placeholder="Search by name, email or ID…"
                 value={@search} phx-keyup="search_users" phx-debounce="300"
                 name="search" phx-value-search={@search}/>
        </div>
        <div class="filter-pills">
          <%= for {v,l} <- [{"all","All"},{"active","Active"},{"blocked","Blocked"},
                             {"verified","Verified"},{"unverified","Unverified"},
                             {"admin","Admins"},{"moderator","Mods"}] do %>
            <button class={["pill", @user_filter == v && "active"]}
                    phx-click="filter_users" phx-value-filter={v}><%= l %></button>
          <% end %>
        </div>
        <select class="select-box" phx-change="sort_users" name="sort">
          <%= for {v,l} <- [{"newest","Newest"},{"oldest","Oldest"},{"files_desc","Most Files"},{"name_asc","Name A→Z"}] do %>
            <option value={v} selected={@user_sort == v}><%= l %></option>
          <% end %>
        </select>
      </div>

      <%= if @users.users == [] && @user_filter != "all" do %>
        <div class="empty-filtered-state">
          <div class="ef-icon">
            <%= case @user_filter do %>
              <% "blocked" -> %> 🚫
              <% "admin"   -> %> ⭐
              <% "verified"-> %> ✅
              <% _         -> %> 👤
            <% end %>
          </div>
          <div class="ef-title">
            No <%= String.downcase(@filter_label) %>
          </div>
          <div class="ef-sub">
            <%= case @user_filter do %>
              <% "blocked"    -> %> Great news! No users are currently blocked.
              <% "admin"      -> %> No admin users found. Promote a user to grant admin access.
              <% "verified"   -> %> No verified users yet. Users verify via email confirmation.
              <% "unverified" -> %> All users are verified — the platform is clean!
              <% "moderator"  -> %> No moderators assigned yet.
              <% _            -> %> No users match this filter.
            <% end %>
          </div>
          <button class="ef-btn" phx-click="filter_users" phx-value-filter="all">View all users</button>
        </div>
      <% else %>
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
                      <div class="user-avatar">
                        <%= String.first(u.nickname || "?") |> String.upcase() %>
                      </div>
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
      <% end %>
    </div>
    """
  end


  # ── User Detail ───────────────────────────────────────────────────────────
end
