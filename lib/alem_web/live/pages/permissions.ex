defmodule AlemWeb.AdminLive.Pages.Permissions do
  @moduledoc "Per-user permission management: access, API, identity, services."
  use Phoenix.Component
  import AlemWeb.AdminLive.Helpers
  alias Alem.Admin
  import AlemWeb.AdminLive.Pages.Users, only: [user_badges: 1]

  def page(%{permissions: nil} = assigns) do
    ~H"""
    <div>
      <button class="back-btn" phx-click="nav_back">
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

  def page(assigns) do
    p = assigns.permissions
    u = p.user
    assigns = assign(assigns, :p, p) |> assign(:u, u)
    ~H"""
    <div>
      <button class="back-btn" phx-click="nav_back">
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

end
