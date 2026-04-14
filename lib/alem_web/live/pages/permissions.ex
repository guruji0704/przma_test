defmodule AlemWeb.Admin.Pages.Permissions do
  @moduledoc "Per-user permissions: access, API tokens, identity, service access control."
  use Phoenix.Component
  import AlemWeb.Admin.Helpers
  import AlemWeb.Admin.Components
  alias Alem.Admin

  import AlemWeb.Admin.Pages.Users, only: [user_badges: 1]

  def page(%{permissions: nil} = assigns) do
    ~H"""
    <div>
      <.back_button nav_history={@nav_history} />

      <div class="page-header" style="margin-bottom:16px">
        <div>
          <h2 class="page-heading">Permissions</h2>
          <div class="page-sub">Select a user below to manage their access and roles</div>
        </div>
        <div class="filter-shortcuts">
          <button class="fsc fsc-amber" phx-click="nav_filtered" phx-value-page="users" phx-value-filter="admin">
            ⭐ View Admins
          </button>
          <button class="fsc fsc-red" phx-click="nav_filtered" phx-value-page="users" phx-value-filter="blocked">
            🚫 View Blocked
          </button>
        </div>
      </div>

      <!-- Quick-access users table -->
      <div class="table-wrap">
        <table class="data-table">
          <thead>
            <tr><th>User</th><th>Email</th><th>Status</th><th>Roles</th><th>Actions</th></tr>
          </thead>
          <tbody>
            <%= for u <- @users.users do %>
              <tr class="data-row">
                <td>
                  <div class="user-cell">
                    <div class="user-avatar"><%= String.first(u.nickname || "?") |> String.upcase() %></div>
                    <div>
                      <div class="user-name"><%= u.nickname %></div>
                      <div class="user-id mono"><%= String.slice(u.id, 0, 8) %>…</div>
                    </div>
                  </div>
                </td>
                <td class="cell-sm mono"><%= u.email %></td>
                <td>
                  <%= if u.is_active do %>
                    <span class="badge green">Active</span>
                  <% else %>
                    <span class="badge red">Blocked</span>
                  <% end %>
                </td>
                <td><div class="badge-row"><.user_badges u={u}/></div></td>
                <td>
                  <div class="action-btns">
                    <button class="btn-sm" phx-click="view_user" phx-value-id={u.id}>Profile</button>
                    <button class="btn-sm accent" phx-click="view_permissions" phx-value-id={u.id}>Manage Perms</button>
                  </div>
                </td>
              </tr>
            <% end %>
            <%= if @users.users == [] do %>
              <tr><td colspan="5" class="empty-row">No users found</td></tr>
            <% end %>
          </tbody>
        </table>
      </div>
      <.pagination d={@users} e="user_page"/>
    </div>
    """
  end

  def page(assigns) do
    p = assigns.permissions
    u = p.user
    assigns = assign(assigns, :p, p) |> assign(:u, u)
    ~H"""
    <div>
      <.back_button nav_history={@nav_history} />

      <div class="profile-card" style="margin-bottom:16px">
        <div class="profile-avatar-lg"><%= String.first(@u.nickname || "?") |> String.upcase() %></div>
        <div class="profile-info">
          <div class="profile-name"><%= @u.nickname %></div>
          <div class="profile-email"><%= @u.email %></div>
          <div class="profile-id mono"><%= @u.id %></div>
          <div class="badge-row"><.user_badges u={@u}/></div>
        </div>
        <div class="profile-actions">
          <button class="action-btn gray" phx-click="view_user" phx-value-id={@u.id}>View Profile</button>
        </div>
      </div>

      <div class="perm-grid">
        <div class="card">
          <div class="card-head"><span class="card-title">🔐 Access Control</span></div>
          <div class="card-body" style="padding:0">
            <div class="perm-row">
              <div>
                <div class="perm-name">Account Active</div>
                <div class="perm-desc">User can log in and use the platform</div>
              </div>
              <div class="perm-ctrl">
                <span class={"perm-badge #{if @p.can_login, do: "on", else: "off"}"}>
                  <%= if @p.can_login, do: "ENABLED", else: "DISABLED" %>
                </span>
                <%= if @p.can_login do %>
                  <button class="perm-btn red" phx-click="perm_action" phx-value-action="block" phx-value-user_id={@u.id}>Block</button>
                <% else %>
                  <button class="perm-btn green" phx-click="perm_action" phx-value-action="unblock" phx-value-user_id={@u.id}>Unblock</button>
                <% end %>
              </div>
            </div>
            <div class="perm-row">
              <div>
                <div class="perm-name">Email Verified</div>
                <div class="perm-desc">Email address has been confirmed</div>
              </div>
              <span class={"perm-badge #{if @p.is_verified, do: "on", else: "off"}"}>
                <%= if @p.is_verified, do: "VERIFIED", else: "UNVERIFIED" %>
              </span>
            </div>
            <div class="perm-row">
              <div>
                <div class="perm-name">Admin Role</div>
                <div class="perm-desc">Full platform administration access</div>
              </div>
              <div class="perm-ctrl">
                <span class={"perm-badge #{if @p.is_admin, do: "on", else: "off"}"}>
                  <%= if @p.is_admin, do: "ADMIN", else: "USER" %>
                </span>
                <%= if @p.is_admin do %>
                  <button class="perm-btn gray"
                          phx-click="confirm_action"
                          phx-value-action="demote"
                          phx-value-user_id={@u.id}
                          phx-value-label={"Remove admin from #{@u.nickname}?"}>Remove</button>
                <% else %>
                  <button class="perm-btn amber"
                          phx-click="confirm_action"
                          phx-value-action="promote"
                          phx-value-user_id={@u.id}
                          phx-value-label={"Make #{@u.nickname} an admin?"}>Grant</button>
                <% end %>
              </div>
            </div>
            <div class="perm-row">
              <div>
                <div class="perm-name">Moderator Role</div>
                <div class="perm-desc">Content moderation privileges</div>
              </div>
              <div class="perm-ctrl">
                <span class={"perm-badge #{if @p.is_admin || @u.is_moderator, do: "on", else: "off"}"}>
                  <%= if @p.is_admin || @u.is_moderator, do: "ENABLED", else: "NONE" %>
                </span>
                <%= if @u.is_moderator do %>
                  <button class="perm-btn gray" phx-click="perm_action" phx-value-action="remove_moderator" phx-value-user_id={@u.id}>Revoke</button>
                <% else %>
                  <button class="perm-btn purple" phx-click="perm_action" phx-value-action="make_moderator" phx-value-user_id={@u.id}>Grant</button>
                <% end %>
              </div>
            </div>
          </div>
        </div>

        <div class="card">
          <div class="card-head"><span class="card-title">🔑 API & Sessions</span></div>
          <div class="card-body" style="padding:0">
            <div class="perm-row">
              <div>
                <div class="perm-name">Active API Tokens</div>
                <div class="perm-desc">OAuth tokens granting API access</div>
              </div>
              <div class="perm-ctrl">
                <span class={"perm-badge #{if @p.active_tokens > 0, do: "on", else: "off"}"}>
                  <%= @p.active_tokens %> active
                </span>
                <%= if @p.active_tokens > 0 do %>
                  <button class="perm-btn red" phx-click="perm_action" phx-value-action="revoke_tokens" phx-value-user_id={@u.id}>Revoke All</button>
                <% end %>
              </div>
            </div>
            <div class="perm-row">
              <div>
                <div class="perm-name">Active Sessions</div>
                <div class="perm-desc">Browser/device sessions currently active</div>
              </div>
              <div class="perm-ctrl">
                <span class={"perm-badge #{if @p.active_sessions > 0, do: "on", else: "off"}"}>
                  <%= @p.active_sessions %> active
                </span>
                <%= if @p.active_sessions > 0 do %>
                  <button class="perm-btn red" phx-click="perm_action" phx-value-action="revoke_sessions" phx-value-user_id={@u.id}>Kill All</button>
                <% end %>
              </div>
            </div>
          </div>
        </div>

        <div class="card">
          <div class="card-head"><span class="card-title">🌐 Identity</span></div>
          <div class="card-body" style="padding:0">
            <div class="perm-row">
              <div>
                <div class="perm-name">Decentralized ID</div>
                <div class="perm-desc mono" style="font-size:10px"><%= @u.did_id || "Not assigned" %></div>
              </div>
              <span class={"perm-badge #{if @u.did_id, do: "on", else: "off"}"}>
                <%= if @u.did_id, do: "ASSIGNED", else: "NONE" %>
              </span>
            </div>
            <div class="perm-row">
              <div>
                <div class="perm-name">API Access</div>
                <div class="perm-desc">Can authenticate via OAuth2</div>
              </div>
              <span class={"perm-badge #{if @p.api_access, do: "on", else: "off"}"}>
                <%= if @p.api_access, do: "GRANTED", else: "NO TOKENS" %>
              </span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Monitoring Page ───────────────────────────────────────────────────────

  defp monitoring_page(%{monitoring: nil} = assigns), do: ~H"""
  <div>
    <.back_button nav_history={@nav_history} />
    <div class="loading-state">
      <div class="loading-spinner"></div>
      <div>Loading monitoring data…</div>
    </div>
  </div>
  """


end
