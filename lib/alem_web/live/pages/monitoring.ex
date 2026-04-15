defmodule AlemWeb.Admin.Pages.Monitoring do
  @moduledoc "Platform monitoring: storage by type, per-user resource usage."
  use Phoenix.Component
  import AlemWeb.Admin.Helpers
  import AlemWeb.Admin.Components
  alias Alem.Admin

  def page(%{monitoring: nil} = assigns) do
    ~H"""
    <div class="empty-state">Loading monitoring data...</div>
    """
  end

  def page(assigns) do
    ~H"""
    <div>
      <.back_button nav_history={@nav_history} />

      <div class="card" style="margin-bottom:16px">
        <div class="card-head"><span class="card-title">Storage by File Type</span></div>
        <div class="card-body">
          <%= if @monitoring.storage_by_type != [] do %>
            <%= for t <- Enum.take(@monitoring.storage_by_type, 8) do %>
              <.storage_bar label={"#{ctic(t.type)} #{sct(t.type)}"} value={t.bytes}
                            max={@stats.total_bytes} color="blue" fmt={Admin.format_bytes(t.bytes)} />
            <% end %>
          <% else %>
            <div class="empty-state">No storage data yet</div>
          <% end %>
        </div>
      </div>

      <div class="tbl-wrap">
        <table class="data-table">
          <thead>
            <tr>
              <th>User</th><th>Status</th><th>Files</th>
              <th>Storage</th><th>Sessions</th><th>Last Active</th><th>Joined</th><th></th>
            </tr>
          </thead>
          <tbody>
            <%= for u <- @monitoring.users do %>
              <tr class="data-row">
                <td>
                  <div class="user-cell"><div class="user-info"><div class="user-name"><%= u.nickname %></div><div class="user-id mono"><%= String.slice(u.user_id, 0, 8) %></div></div></div>
                </td>
                <td>
                  <div class="badge-row">
                    <%= if u.is_active do %>
                      <span class="badge green">Active</span>
                    <% else %>
                      <span class="badge red">Blocked</span>
                    <% end %>
                    <%= if u.is_verified do %><span class="badge blue">Verified</span><% end %>
                  </div>
                </td>
                <td class="cell-num"><%= u.file_count %></td>
                <td class="cell-num"><%= Admin.format_bytes(u.storage_bytes) %></td>
                <td class="cell-num"><%= Map.get(u, :sessions, 0) %></td>
                <td class="cell-sm"><%= fd(Map.get(u, :last_active)) %></td>
                <td class="cell-sm"><%= joined_ago(u.joined) %></td>
                <td>
                  <div class="action-btns">
                    <button class="btn-sm" phx-click="view_user" phx-value-id={u.user_id}>Profile</button>
                    <button class="btn-sm accent" phx-click="view_permissions" phx-value-id={u.user_id}>Perms</button>
                  </div>
                </td>
              </tr>
            <% end %>
            <%= if @monitoring.users == [] do %>
              <tr><td colspan="8" class="empty-row">No users yet</td></tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
