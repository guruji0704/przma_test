defmodule AlemWeb.AdminLive.Pages.Users do
  @moduledoc "Users list with search, filter, sort, and pagination."
  use Phoenix.Component
  import AlemWeb.AdminLive.Helpers
  alias Alem.Admin

  def page(assigns) do
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
end
