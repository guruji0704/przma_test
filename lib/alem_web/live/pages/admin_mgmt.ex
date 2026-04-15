defmodule AlemWeb.Admin.Pages.AdminMgmt do
  @moduledoc """
  Admin Account Management page.
  Super admin (admin@przma.com) can grant or revoke admin status for any existing user.
  Does NOT create new user accounts — only elevates existing users.
  Uses the is_admin flag on the users table (no separate table needed).
  """
  use Phoenix.Component
  import AlemWeb.Admin.Helpers
  import AlemWeb.Admin.Components

  def page(assigns) do
    ~H"""
    <div>
      <.back_button nav_history={@nav_history} />

      <!-- Header -->
      <div class="page-header" style="margin-bottom:20px">
        <div>
          <h2 class="page-heading">Admin Accounts</h2>
          <div class="page-sub">Grant or revoke admin access. Only super admin can manage admins.</div>
        </div>
      </div>

      <!-- Grant Admin Form -->
      <div class="card" style="margin-bottom:20px;max-width:560px">
        <div class="card-head">
          <span class="card-title">Grant Admin Access</span>
          <span class="card-meta">By existing user email</span>
        </div>
        <div class="card-body">
          <div class="page-sub" style="margin-bottom:12px">
            Enter the email of an existing registered user to grant them admin privileges.
            They must already have a regular account.
          </div>
          <div style="display:flex;gap:10px;align-items:flex-start">
            <div class="search-box" style="flex:1">
              <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <path d="M4 4h16c1.1 0 2 .9 2 2v12c0 1.1-.9 2-2 2H4c-1.1 0-2-.9-2-2V6c0-1.1.9-2 2-2z"/>
                <polyline points="22,6 12,12 2,6"/>
              </svg>
              <input class="search-input"
                     placeholder="user@example.com"
                     value={@new_admin_email}
                     phx-keyup="new_admin_email_change"
                     phx-debounce="200"
                     name="admin_email" />
            </div>
            <button class="btn-sm accent"
                    style="padding:7px 16px;white-space:nowrap"
                    phx-click="create_admin"
                    phx-disable-with="Granting...">
              Grant Admin
            </button>
          </div>
          <%= if @new_admin_error do %>
            <div style="margin-top:8px;padding:8px 12px;border-radius:7px;background:rgba(255,85,102,.08);border:1px solid rgba(255,85,102,.2);color:var(--clr-red);font-size:11px">
              ⚠ <%= @new_admin_error %>
            </div>
          <% end %>
          <div style="margin-top:10px;padding:10px 12px;border-radius:7px;background:var(--bg3);border:1px solid var(--border);font-size:10px;color:var(--tx3)">
            ℹ Admin users can manage all users, view all data, and perform platform operations.
            They cannot grant admin to others — only the super admin can do that.
          </div>
        </div>
      </div>

      <!-- Current Admins Table -->
      <div class="card">
        <div class="card-head">
          <span class="card-title">Current Admin Accounts</span>
          <span class="card-meta"><%= length(@admin_users) %> admins</span>
        </div>
        <div class="table-wrap" style="border:none;border-radius:0">
          <table class="data-table">
            <thead>
              <tr>
                <th>User</th>
                <th>Email</th>
                <th>Status</th>
                <th>Admin Since</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              <%= for u <- @admin_users do %>
                <tr class="data-row">
                  <td>
                    <div class="user-info">
                      <div class="user-name"><%= u.nickname %></div>
                      <div class="user-id mono"><%= String.slice(u.id, 0, 10) %>…</div>
                    </div>
                  </td>
                  <td class="cell-sm mono"><%= u.email %></td>
                  <td>
                    <%= if u.is_active do %>
                      <span class="badge green">Active</span>
                    <% else %>
                      <span class="badge red">Blocked</span>
                    <% end %>
                    <span class="badge amber">Admin</span>
                  </td>
                  <td class="cell-sm"><%= joined_ago(u.inserted_at) %> ago</td>
                  <td>
                    <%= if u.email != "admin@przma.com" do %>
                      <button class="btn-sm"
                              style="color:var(--clr-red);border-color:rgba(255,85,102,.3)"
                              phx-click="revoke_admin"
                              phx-value-id={u.id}
                              phx-disable-with="Revoking..."
                              onclick="return confirm('Remove admin from #{u.nickname}?')">
                        Revoke Admin
                      </button>
                    <% else %>
                      <span class="cell-sm" style="color:var(--tx3)">Super Admin (protected)</span>
                    <% end %>
                  </td>
                </tr>
              <% end %>
              <%= if @admin_users == [] do %>
                <tr><td colspan="5" class="empty-row">No admin accounts</td></tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>

      <!-- Info box -->
      <div style="margin-top:16px;padding:12px 16px;border-radius:8px;background:var(--bg3);border:1px solid var(--border);font-size:11px;color:var(--tx2);max-width:560px">
        <strong style="color:var(--tx)">Note:</strong> Admin status uses the
        <code style="font-family:monospace;background:var(--bg4);padding:1px 5px;border-radius:3px">is_admin</code>
        flag on the existing users table.
        The <strong>admin@przma.com</strong> super admin account cannot be revoked.
        For complete access control, consider creating a dedicated
        <code style="font-family:monospace;background:var(--bg4);padding:1px 5px;border-radius:3px">admin_roles</code>
        table in a future migration.
      </div>
    </div>
    """
  end
end
