defmodule AlemWeb.AdminLive.Pages.Dashboard do
  @moduledoc "Dashboard KPI cards, service health, and quick actions."
  use Phoenix.Component
  import AlemWeb.AdminLive.Helpers
  alias Alem.Admin

  def page(assigns) do
    ~H"""
    <div class="dash">
      <!-- Stat Cards -->
      <div class="sg">
        <.sc lb="Total Users"    v={@stats.total_users}     ic="users"    cl="blue"   nav="users_analytics"   tt="User analytics" />
        <.sc lb="Verified"       v={@stats.verified_users}  ic="check"    cl="green"  nav="users_analytics"   tt="Verification stats" />
        <.sc lb="Blocked"        v={@stats.blocked_users}   ic="ban"      cl="red"    nav="users"             tt="Manage blocked users" />
        <.sc lb="Admins"         v={@stats.admin_users}     ic="star"     cl="amber"  nav="users"             tt="Manage admins" />
        <.sc lb="Total Files"    v={@stats.total_files}     ic="file"     cl="purple" nav="storage_analytics" tt="Storage analytics" />
        <.sc lb="CAS Objects"    v={@stats.total_cas}       ic="db"       cl="blue"   nav="cas_analytics"     tt="CAS analytics" />
        <.sc lb="Sessions"       v={@stats.active_sessions} ic="zap"      cl="green"  nav="permissions"       tt="Manage sessions" />
        <.sc lb="New This Week"  v={@stats.new_this_week}   ic="trending" cl="amber"  nav="users_analytics"   tt="Signup trends" />
      </div>

      <div class="dash-grid">
        <!-- Storage Health -->
        <div class="card">
          <div class="card-head"><span class="card-title">Storage Health</span></div>
          <div class="card-body">
            <.storage_bar label="Total Stored"    value={@stats.total_bytes}   max={@stats.total_bytes} color="blue"  fmt={Admin.format_bytes(@stats.total_bytes)} />
            <.storage_bar label="Dedup Savings"   value={@stats.saved_bytes}   max={@stats.total_bytes} color="green" fmt={Admin.format_bytes(@stats.saved_bytes)} />
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
            <.svc_row name="PostgreSQL" />
            <.svc_row name="Linode S3 (in-maa-1)" />
            <.svc_row name="Horde Registry" />
            <.svc_row name="CAS Engine" />
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
          <div class="card-head">
            <span class="card-title">Audit Log</span>
            <span class="card-meta">Recent actions</span>
          </div>
          <div class="card-body" style="padding:0">
            <%= if @audit_log == [] do %>
              <div class="empty-state" style="padding:28px">No admin actions yet</div>
            <% end %>
            <%= for entry <- Enum.take(@audit_log, 10) do %>
              <div class="audit-row">
                <div class="audit-dot"></div>
                <div class="audit-info">
                  <span class="audit-action"><%= entry.action %></span>
                  <%= if entry.target do %>
                    <span class="audit-target"><%= String.slice(entry.target, 0, 10) %>…</span>
                  <% end %>
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

  # ── Private components ─────────────────────────────────────────────────────

  defp storage_bar(assigns) do
    b   = to_int_safe(assigns.value)
    m   = max(to_int_safe(assigns.max), 1)
    pct = if m > 0, do: min(100, round(b / m * 100)), else: 0
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

  # Stat card — clickable, navigates to a page
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
    <div
      class={["sc", "sc-#{@cl}", assigns[:nav] && "sc-click"]}
      phx-click={assigns[:nav] && "nav"}
      phx-value-page={assigns[:nav]}
      title={assigns[:tt] || ""}
    >
      <div class="sc-ic">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <%= raw(@icon_svg) %>
        </svg>
      </div>
      <div class="sc-body">
        <div class="sc-v"><%= @v %></div>
        <div class="sc-l"><%= @lb %></div>
      </div>
      <%= if assigns[:nav] do %><div class="sc-arr">&#8594;</div><% end %>
    </div>
    """
  end

  defp to_int_safe(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_int_safe(i) when is_integer(i), do: i
  defp to_int_safe(_), do: 0
end
