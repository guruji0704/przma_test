defmodule AlemWeb.Admin.Pages.UserProfile do
  @moduledoc """
  User Profile page with full activity analytics.

  SECURITY CONTRACT:
    - Filenames are NEVER shown. Only CAS content hash (first 24 chars) is displayed.
    - Activity log shows: CAS hash + file type for uploads; device + IP for logins.
    - admin@przma.com account has all destructive buttons hidden.
    - user_activity/1 in admin.ex already enforces these at the DB query level.

  Charts included:
    1. Files uploaded per month (bar)
    2. Logins per month (bar)
    3. Storage growth per month (area)
    4. File types (pie)
    5. Device breakdown (doughnut)
    6. Platform usage profile (radar)
    7. Quota usage (gauge)
    8. Storage by file type (horizontal bar)

  To add a new chart: add a new cj_* call here, assign it, add canvas in the template.
  To add a new service: edit services_used/1 in admin.ex — it auto-appears in the grid.
  """
  use Phoenix.Component
  import AlemWeb.Admin.Helpers
  import AlemWeb.Admin.Components
  alias AlemWeb.Admin.Charts
  alias Alem.Admin

  def page(%{user_detail: nil} = assigns) do
    ~H"""
    <div class="empty-state">User not found</div>
    """
  end

  def page(assigns) do
    ua  = Admin.user_activity(assigns.user_detail.user.id)
    uid = assigns.user_detail.user.id

    # Chart data — add new charts here
    fm = Charts.bar(Enum.map(ua.files_by_month, & &1.month), Enum.map(ua.files_by_month, & &1.count), "Uploads", "rgba(88,166,255,.75)")
    lm = Charts.bar(Enum.map(ua.logins_by_month, & &1.month), Enum.map(ua.logins_by_month, & &1.count), "Logins", "rgba(63,185,80,.75)")
    sg = Charts.area(Enum.map(ua.storage_by_month, & &1.month), Enum.map(ua.storage_by_month, & &1.mb), "MB", "#bc8cff")

    t6 = Enum.take(ua.type_counts, 6)
    ft = Charts.pie(Enum.map(t6, & short_mime(&1.type)), Enum.map(t6, & &1.count), Charts.palette())

    dv = Charts.doughnut(
      Enum.map(ua.device_counts, & String.capitalize(&1.device || "unknown")),
      Enum.map(ua.device_counts, & &1.count),
      Charts.palette()
    )

    rd = Charts.radar(
      ["Files", "Sessions", "Storage", "API", "Dedup"],
      [%{
        label: "Profile",
        data: [
          min(100, ua.total_files * 3),
          min(100, ua.total_sessions * 8),
          min(100, round(ua.total_bytes / max(1, ua.total_bytes) * 100)),
          if(ua.active_tokens > 0, do: 75, else: 0),
          if(assigns.user_detail.duplicates != [], do: 60, else: 0)
        ],
        backgroundColor: "rgba(88,166,255,.15)",
        borderColor: "#58a6ff", pointBackgroundColor: "#58a6ff",
        pointRadius: 4, borderWidth: 2
      }]
    )

    quota_bytes = 5_368_709_120
    quota_pct   = min(100, round(ua.total_bytes / quota_bytes * 100))
    qt = Charts.gauge(quota_pct, if(quota_pct > 80, do: "#f85149", else: "#3fb950"))

    sz = Charts.hbar(
      Enum.map(t6, & short_mime(&1.type)),
      Enum.map(t6, & Float.round(to_int_safe(&1.bytes) / 1_048_576, 1)),
      "MB", "rgba(188,140,255,.7)"
    )

    assigns = assigns
      |> assign(:ua, ua) |> assign(:uid, uid) |> assign(:quota_pct, quota_pct)
      |> assign(:fm, fm) |> assign(:lm, lm) |> assign(:sg, sg)
      |> assign(:ft, ft) |> assign(:dv, dv) |> assign(:rd, rd)
      |> assign(:qt, qt) |> assign(:sz, sz)

    ~H"""
    <div>
      <button class="back-btn" phx-click="nav_back">&#8592; Back</button>

      <!-- Profile card -->
      <div class="profile-card">
        <div class="profile-avatar-lg"><%= String.first(@user_detail.user.nickname || "?") |> String.upcase() %></div>
        <div class="profile-info">
          <div class="profile-name"><%= @user_detail.user.nickname %></div>
          <div class="profile-email"><%= @user_detail.user.email %></div>
          <div class="profile-id mono"><%= @user_detail.user.id %></div>
          <div class="badge-row">
            <%= if @user_detail.user.is_active do %><span class="badge green">Active</span><% else %><span class="badge red">Blocked</span><% end %>
            <%= if @user_detail.user.is_verified do %><span class="badge blue">Verified</span><% else %><span class="badge gray">Unverified</span><% end %>
            <%= if @user_detail.user.is_admin do %><span class="badge amber">Admin</span><% end %>
          </div>
          <div class="muted sm">Joined <%= joined_ago(@user_detail.user.inserted_at) %> ago</div>
        </div>
        <div class="profile-actions">
          <button class="action-btn purple" phx-click="view_permissions" phx-value-id={@user_detail.user.id}>Permissions</button>
          <%!-- admin@przma.com is protected — no destructive actions shown --%>
          <%= if @user_detail.user.email != "admin@przma.com" do %>
            <%= if @user_detail.user.is_active do %>
              <button class="action-btn red" phx-click="confirm_action" phx-disable-with="..." phx-value-action="block" phx-value-user_id={@user_detail.user.id} phx-value-label={"Block #{@user_detail.user.nickname}?"}>Block</button>
            <% else %>
              <button class="action-btn green" phx-click="confirm_action" phx-disable-with="..." phx-value-action="unblock" phx-value-user_id={@user_detail.user.id} phx-value-label={"Unblock #{@user_detail.user.nickname}?"}>Unblock</button>
            <% end %>
            <%!-- Admin promotion handled via Admin Management page --%>
            <%= if @user_detail.user.is_admin do %>
              <button class="action-btn gray" phx-click="confirm_action" phx-disable-with="..." phx-value-action="demote" phx-value-user_id={@user_detail.user.id} phx-value-label={"Remove admin from #{@user_detail.user.nickname}?"}>Remove Admin</button>
            <% end %>
            <button class="action-btn orange" phx-click="confirm_action" phx-disable-with="..." phx-value-action="soft_delete" phx-value-user_id={@user_detail.user.id} phx-value-label={"Soft delete #{@user_detail.user.nickname}?"}>Soft Delete</button>
          <% else %>
            <div class="protected-badge">&#128274; Super Admin &middot; Protected</div>
          <% end %>
        </div>
      </div>

      <!-- KPI strip -->
      <div class="up-strip">
        <div class="up-kpi blue"><div class="up-kpi-val"><%= @ua.total_files %></div><div class="up-kpi-lbl">Files</div></div>
        <div class="up-kpi green"><div class="up-kpi-val"><%= Admin.format_bytes(@ua.total_bytes) %></div><div class="up-kpi-lbl">Stored</div></div>
        <div class="up-kpi purple"><div class="up-kpi-val"><%= @ua.total_sessions %></div><div class="up-kpi-lbl">Logins</div></div>
        <div class="up-kpi amber"><div class="up-kpi-val"><%= @ua.active_tokens %></div><div class="up-kpi-lbl">API Tokens</div></div>
        <div class="up-kpi red"><div class="up-kpi-val"><%= length(@user_detail.duplicates) %></div><div class="up-kpi-lbl">Duplicates</div></div>
        <div class={["up-kpi", if(@quota_pct > 80, do: "red", else: "green")]}>
          <div class="up-kpi-val"><%= @quota_pct %>%</div><div class="up-kpi-lbl">Quota</div>
        </div>
      </div>

      <!-- Row A: uploads + logins bar charts -->
      <div class="up-row2" style="margin-bottom:12px">
        <div class="chart-card">
          <div class="chart-title">Files Uploaded <span class="ct-sub">bar · 12 months</span></div>
          <%= if @ua.files_by_month != [] do %>
            <div class="ch240"><canvas id={"p-fm-#{@uid}"} phx-hook="Chart" data-chart={@fm}></canvas></div>
          <% else %>
            <div class="chart-empty" style="height:240px">No uploads yet</div>
          <% end %>
        </div>
        <div class="chart-card">
          <div class="chart-title">Logins <span class="ct-sub">bar · 6 months</span></div>
          <%= if @ua.logins_by_month != [] do %>
            <div class="ch240"><canvas id={"p-lm-#{@uid}"} phx-hook="Chart" data-chart={@lm}></canvas></div>
          <% else %>
            <div class="chart-empty" style="height:240px">No logins recorded</div>
          <% end %>
        </div>
      </div>

      <!-- Row B: storage area + quota gauge -->
      <div class="up-row-wide" style="margin-bottom:12px">
        <div class="chart-card">
          <div class="chart-title">Storage Growth <span class="ct-sub">area · MB / month</span></div>
          <%= if @ua.storage_by_month != [] do %>
            <div class="ch180"><canvas id={"p-sg-#{@uid}"} phx-hook="Chart" data-chart={@sg}></canvas></div>
          <% else %>
            <div class="chart-empty" style="height:180px">No storage data</div>
          <% end %>
        </div>
        <div class="chart-card" style="display:flex;flex-direction:column;align-items:center;justify-content:center">
          <div class="chart-title" style="text-align:center">Quota <span class="ct-sub">of 5 GB</span></div>
          <div class="gauge-wrap" style="height:150px;width:170px">
            <canvas id={"p-qt-#{@uid}"} phx-hook="Chart" data-chart={@qt}></canvas>
            <div class="gauge-label">
              <span style={"font-size:20px;font-weight:800;color:#{if @quota_pct > 80, do: "#f85149", else: "#3fb950"}"}><%= @quota_pct %>%</span><br/>
              <span class="muted sm">used</span>
            </div>
          </div>
        </div>
      </div>

      <!-- Row C: file types + devices + radar -->
      <div class="up-row3" style="margin-bottom:12px">
        <div class="chart-card">
          <div class="chart-title">File Types <span class="ct-sub">pie</span></div>
          <%= if @ua.type_counts != [] do %>
            <div class="ch180"><canvas id={"p-ft-#{@uid}"} phx-hook="Chart" data-chart={@ft}></canvas></div>
          <% else %>
            <div class="chart-empty" style="height:180px">No files</div>
          <% end %>
        </div>
        <div class="chart-card">
          <div class="chart-title">Devices <span class="ct-sub">doughnut</span></div>
          <%= if @ua.device_counts != [] do %>
            <div class="ch180"><canvas id={"p-dv-#{@uid}"} phx-hook="Chart" data-chart={@dv}></canvas></div>
          <% else %>
            <div class="chart-empty" style="height:180px">No sessions</div>
          <% end %>
        </div>
        <div class="chart-card">
          <div class="chart-title">Platform Usage <span class="ct-sub">radar</span></div>
          <div class="ch180"><canvas id={"p-rd-#{@uid}"} phx-hook="Chart" data-chart={@rd}></canvas></div>
        </div>
      </div>

      <!-- Row D: storage by type hbar -->
      <%= if @ua.type_counts != [] do %>
        <div class="chart-card" style="margin-bottom:12px">
          <div class="chart-title">Storage by Type <span class="ct-sub">hbar · MB</span></div>
          <div class="ch160"><canvas id={"p-sz-#{@uid}"} phx-hook="Chart" data-chart={@sz}></canvas></div>
        </div>
      <% end %>

      <!-- Row E: services + activity log -->
      <div class="up-row2" style="margin-bottom:12px">
        <div class="card">
          <div class="card-head">
            <span class="card-title">Platform Services</span>
            <span class="card-meta">Add new in admin.ex services_used/1</span>
          </div>
          <div class="svc-list">
            <%= for {name, svc} <- @ua.services do %>
              <div class={["svc-item", svc.enabled && "svc-on"]}>
                <div class="svc-ico"><%= svc.icon %></div>
                <div class="svc-body">
                  <div class="svc-name"><%= name %></div>
                  <div class="svc-desc"><%= svc.description %></div>
                  <div class="svc-use"><%= svc.usage %></div>
                </div>
                <span class={["svc-pill", svc.enabled && "on"]}><%= if svc.enabled, do: "Active", else: "Off" %></span>
              </div>
            <% end %>
          </div>
        </div>
        <div class="card">
          <div class="card-head">
            <span class="card-title">Recent Activity</span>
            <span class="card-meta"><%!-- SECURITY: filenames hidden, CAS hash only --%></span>
          </div>
          <div class="act-log">
            <%= for ev <- @ua.activity_log do %>
              <div class="act-row">
                <div class={["act-dot", ev.kind]}><%= if ev.kind == "upload", do: "F", else: "L" %></div>
                <div class="act-body">
                  <%= if ev.kind == "upload" do %>
                    <div class="act-label mono" style="font-size:10px;color:var(--muted2)"><%= ev.cas_hash || "—" %></div>
                    <div class="act-sub"><%= ev.file_type || "binary" %></div>
                  <% else %>
                    <div class="act-label"><%= ev.device || "unknown" %></div>
                    <div class="act-sub"><%= ev.ip_address || "—" %></div>
                  <% end %>
                </div>
                <div class="act-time"><%= fd_short(ev.at) %></div>
              </div>
            <% end %>
            <%= if @ua.activity_log == [] do %>
              <div class="empty-state" style="padding:20px">No activity yet</div>
            <% end %>
          </div>
        </div>
      </div>

      <!-- Row F: identity + recent files (CAS hash only) -->
      <div class="up-row2">
        <div class="card">
          <div class="card-head"><span class="card-title">Identity & Namespace</span></div>
          <div class="card-body" style="padding:0">
            <%= if @user_detail.user.did_id do %>
              <div class="did-block mono"><%= @user_detail.user.did_id %></div>
              <%= if @user_detail.namespace do %>
                <div class="kv-row"><span>Namespace</span><span class="mono sm"><%= @user_detail.namespace.id %></span></div>
                <div class="kv-row"><span>Status</span><span><%= @user_detail.namespace.status %></span></div>
              <% end %>
            <% else %>
              <div class="empty-state" style="padding:20px">No DID assigned</div>
            <% end %>
          </div>
        </div>
        <div class="card">
          <div class="card-head">
            <span class="card-title">Recent Files (<%= @user_detail.file_count %>)</span>
            <span class="card-meta"><%!-- SECURITY: filename hidden, CAS hash shown --%></span>
          </div>
          <div class="scroll-list">
            <%= for f <- Enum.take(@user_detail.files, 20) do %>
              <div class="list-row">
                <span class="file-icon"><%= ctic(f.content_type) %></span>
                <div>
                  <div class="row-name mono" style="font-size:10px;color:var(--muted2)"><%= String.slice(Map.get(f, :content_hash) || "—", 0, 24) %>...</div>
                  <div class="row-meta"><%= sct(f.content_type) %> &middot; <%= fd(f.inserted_at) %></div>
                </div>
              </div>
            <% end %>
            <%= if @user_detail.file_count == 0 do %><div class="empty-state" style="padding:20px">No files</div><% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
