defmodule AlemWeb.AdminLive.Pages.UserProfile do
  @moduledoc """
  User Profile page with full activity analytics.
  Charts: uploads/month, logins/month, storage growth, file types,
  device breakdown, platform usage radar, quota gauge, activity log.
  """
  use Phoenix.Component
  import AlemWeb.AdminLive.Helpers
  alias AlemWeb.AdminLive.Charts
  alias Alem.Admin

  def page(%{user_detail: nil} = assigns) do
    ~H"""
    <div class="empty-state">User not found</div>
    """
  end

  def page(assigns) do
    ua  = Admin.user_activity(assigns.user_detail.user.id)
    uid = assigns.user_detail.user.id

    # ── Chart 1: Files uploaded per month (bar, blue)
    fm_chart = Charts.bar(
      Enum.map(ua.files_by_month, & &1.month),
      Enum.map(ua.files_by_month, & &1.count),
      "Uploads", "rgba(88,166,255,.75)"
    )

    # ── Chart 2: Logins per month (bar, green)
    lm_chart = Charts.bar(
      Enum.map(ua.logins_by_month, & &1.month),
      Enum.map(ua.logins_by_month, & &1.count),
      "Logins", "rgba(63,185,80,.75)"
    )

    # ── Chart 3: Storage growth (area, purple)
    sg_chart = Charts.area(
      Enum.map(ua.storage_by_month, & &1.month),
      Enum.map(ua.storage_by_month, & &1.mb),
      "MB", "#bc8cff"
    )

    # ── Chart 4: File types (pie)
    t6       = Enum.take(ua.type_counts, 6)
    ft_chart = Charts.pie(
      Enum.map(t6, & short_mime(&1.type)),
      Enum.map(t6, & &1.count),
      Charts.palette()
    )

    # ── Chart 5: Device breakdown (doughnut)
    dv_chart = Charts.doughnut(
      Enum.map(ua.device_counts, & String.capitalize(&1.device || "unknown")),
      Enum.map(ua.device_counts, & &1.count),
      Charts.palette()
    )

    # ── Chart 6: Platform usage radar (normalised to 100)
    total = max(ua.total_files, 1)
    radar_chart = Charts.radar(
      ["Files", "Storage", "Sessions", "API Access", "Dedup"],
      [%{
        label: "Usage Profile",
        data: [
          min(100, round(ua.total_files / max(total, 1) * 100)),
          min(100, round(ua.total_bytes / max(ua.total_bytes, 1) * 100)),
          min(100, round(ua.total_sessions / max(ua.total_sessions, 1) * 100)),
          if(ua.active_tokens > 0, do: 80, else: 0),
          if(assigns.user_detail.duplicates != [], do: 60, else: 0)
        ],
        backgroundColor: "rgba(88,166,255,.15)",
        borderColor: "#58a6ff",
        pointBackgroundColor: "#58a6ff",
        pointRadius: 4, borderWidth: 2
      }]
    )

    # ── Chart 7: Quota utilisation gauge
    quota_bytes  = 5_368_709_120  # 5 GB default free plan
    quota_pct    = min(100, round(ua.total_bytes / quota_bytes * 100))
    quota_chart  = Charts.gauge(quota_pct, if(quota_pct > 80, do: "#f85149", else: "#3fb950"))

    # ── Chart 8: File size distribution by type (hbar)
    sz_labels = Enum.map(t6, & short_mime(&1.type))
    sz_data   = t6 |> Enum.map(& Map.get(&1, :bytes, 0)) |> Enum.map(& Float.round(to_int_safe(&1) / 1_048_576, 1))
    sz_chart  = Charts.hbar(sz_labels, sz_data, "MB", "rgba(188,140,255,.7)")

    assigns = assigns
      |> assign(:ua, ua)
      |> assign(:uid, uid)
      |> assign(:fm_chart,    fm_chart)
      |> assign(:lm_chart,    lm_chart)
      |> assign(:sg_chart,    sg_chart)
      |> assign(:ft_chart,    ft_chart)
      |> assign(:dv_chart,    dv_chart)
      |> assign(:radar_chart, radar_chart)
      |> assign(:quota_chart, quota_chart)
      |> assign(:quota_pct,   quota_pct)
      |> assign(:sz_chart,    sz_chart)

    ~H"""
    <div>
      <!-- Profile header -->
      <button class="back-btn" phx-click="nav_back">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="19" y1="12" x2="5" y2="12"/><polyline points="12 19 5 12 12 5"/></svg>
        Back
      </button>

      <div class="profile-card">
        <div class="profile-avatar-lg"><%= String.first(@user_detail.user.nickname || "?") |> String.upcase() %></div>
        <div class="profile-info">
          <div class="profile-name"><%= @user_detail.user.nickname %></div>
          <div class="profile-email"><%= @user_detail.user.email %></div>
          <div class="profile-id mono"><%= @user_detail.user.id %></div>
          <div class="badge-row">
            <%= if !@user_detail.user.is_active do %><span class="badge red">Blocked</span><% else %><span class="badge green">Active</span><% end %>
            <%= if @user_detail.user.is_verified do %><span class="badge blue">Verified</span><% else %><span class="badge gray">Unverified</span><% end %>
            <%= if @user_detail.user.is_admin do %><span class="badge amber">Admin</span><% end %>
          </div>
          <div class="profile-join">Member since <%= fd(@user_detail.user.inserted_at) %></div>
        </div>
        <div class="profile-actions">
          <button class="action-btn purple" phx-click="view_permissions" phx-value-id={@user_detail.user.id}>Permissions</button>
          <%= if @user_detail.user.is_active do %>
            <button class="action-btn red" phx-click="confirm_action" phx-value-action="block" phx-value-user_id={@user_detail.user.id} phx-value-label={"Block #{@user_detail.user.nickname}?"}>Block</button>
          <% else %>
            <button class="action-btn green" phx-click="confirm_action" phx-value-action="unblock" phx-value-user_id={@user_detail.user.id} phx-value-label={"Unblock #{@user_detail.user.nickname}?"}>Unblock</button>
          <% end %>
          <%= if @user_detail.user.is_admin do %>
            <button class="action-btn gray" phx-click="confirm_action" phx-value-action="demote" phx-value-user_id={@user_detail.user.id} phx-value-label={"Remove admin from #{@user_detail.user.nickname}?"}>Remove Admin</button>
          <% else %>
            <button class="action-btn amber" phx-click="confirm_action" phx-value-action="promote" phx-value-user_id={@user_detail.user.id} phx-value-label={"Make #{@user_detail.user.nickname} admin?"}>Make Admin</button>
          <% end %>
        </div>
      </div>

      <!-- KPI strip: 6 key numbers at a glance -->
      <div class="up-strip">
        <div class="up-kpi blue">
          <div class="up-kpi-val"><%= @ua.total_files %></div>
          <div class="up-kpi-lbl">Files</div>
        </div>
        <div class="up-kpi green">
          <div class="up-kpi-val"><%= Admin.format_bytes(@ua.total_bytes) %></div>
          <div class="up-kpi-lbl">Stored</div>
        </div>
        <div class="up-kpi purple">
          <div class="up-kpi-val"><%= @ua.total_sessions %></div>
          <div class="up-kpi-lbl">Logins</div>
        </div>
        <div class="up-kpi amber">
          <div class="up-kpi-val"><%= @ua.active_tokens %></div>
          <div class="up-kpi-lbl">API Tokens</div>
        </div>
        <div class="up-kpi red">
          <div class="up-kpi-val"><%= length(@user_detail.duplicates) %></div>
          <div class="up-kpi-lbl">Duplicates</div>
        </div>
        <div class={["up-kpi", if(@quota_pct > 80, do: "red", else: "green")]}>
          <div class="up-kpi-val"><%= @quota_pct %>%</div>
          <div class="up-kpi-lbl">Quota Used</div>
        </div>
      </div>

      <!-- ROW A: uploads bar + logins bar -->
      <div class="up-row2" style="margin-bottom:12px">
        <div class="chart-card">
          <div class="chart-title">Files Uploaded per Month <span class="ct-sub">bar · 12mo</span></div>
          <%= if @ua.files_by_month != [] do %>
            <div class="ch220"><canvas id={"p-fm-#{@uid}"} phx-hook="Chart" data-chart={@fm_chart}></canvas></div>
          <% else %>
            <div class="chart-empty" style="height:220px">No uploads yet</div>
          <% end %>
        </div>
        <div class="chart-card">
          <div class="chart-title">Logins per Month <span class="ct-sub">bar · 6mo</span></div>
          <%= if @ua.logins_by_month != [] do %>
            <div class="ch220"><canvas id={"p-lm-#{@uid}"} phx-hook="Chart" data-chart={@lm_chart}></canvas></div>
          <% else %>
            <div class="chart-empty" style="height:220px">No logins recorded</div>
          <% end %>
        </div>
      </div>

      <!-- ROW B: storage area (wide) + quota gauge (narrow) -->
      <div class="up-row-wide" style="margin-bottom:12px">
        <div class="chart-card">
          <div class="chart-title">Storage Growth <span class="ct-sub">area · MB per month</span></div>
          <%= if @ua.storage_by_month != [] do %>
            <div class="ch180"><canvas id={"p-sg-#{@uid}"} phx-hook="Chart" data-chart={@sg_chart}></canvas></div>
          <% else %>
            <div class="chart-empty" style="height:180px">No storage data</div>
          <% end %>
        </div>
        <div class="chart-card" style="display:flex;flex-direction:column;align-items:center;justify-content:center">
          <div class="chart-title" style="text-align:center">Quota Usage <span class="ct-sub">gauge</span></div>
          <div class="gauge-wrap" style="height:160px;width:180px;position:relative">
            <canvas id={"p-qt-#{@uid}"} phx-hook="Chart" data-chart={@quota_chart}></canvas>
            <div class="gauge-label">
              <span class={if @quota_pct > 80, do: "red", else: "green"} style="font-size:22px;font-weight:800"><%= @quota_pct %>%</span><br/>
              <span style="font-size:10px;color:var(--muted)">of 5 GB</span>
            </div>
          </div>
        </div>
      </div>

      <!-- ROW C: 3 charts: file types pie + device doughnut + platform radar -->
      <div class="up-row3" style="margin-bottom:12px">
        <div class="chart-card">
          <div class="chart-title">File Types <span class="ct-sub">pie</span></div>
          <%= if @ua.type_counts != [] do %>
            <div class="ch180"><canvas id={"p-ft-#{@uid}"} phx-hook="Chart" data-chart={@ft_chart}></canvas></div>
          <% else %>
            <div class="chart-empty" style="height:180px">No files</div>
          <% end %>
        </div>
        <div class="chart-card">
          <div class="chart-title">Device Breakdown <span class="ct-sub">doughnut</span></div>
          <%= if @ua.device_counts != [] do %>
            <div class="ch180"><canvas id={"p-dv-#{@uid}"} phx-hook="Chart" data-chart={@dv_chart}></canvas></div>
          <% else %>
            <div class="chart-empty" style="height:180px">No sessions</div>
          <% end %>
        </div>
        <div class="chart-card">
          <div class="chart-title">Platform Usage <span class="ct-sub">radar</span></div>
          <div class="ch180"><canvas id={"p-rd-#{@uid}"} phx-hook="Chart" data-chart={@radar_chart}></canvas></div>
        </div>
      </div>

      <!-- ROW D: file size by type (hbar) -->
      <%= if @ua.type_counts != [] do %>
        <div class="chart-card" style="margin-bottom:12px">
          <div class="chart-title">Storage by File Type <span class="ct-sub">horizontal bar · MB</span></div>
          <div class="ch160"><canvas id={"p-sz-#{@uid}"} phx-hook="Chart" data-chart={@sz_chart}></canvas></div>
        </div>
      <% end %>

      <!-- ROW E: Services + Activity log -->
      <div class="up-row2" style="margin-bottom:12px">

        <!-- Platform services -->
        <div class="card">
          <div class="card-head">
            <span class="card-title">Platform Services</span>
            <span class="card-meta">Add new in admin.ex</span>
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

        <!-- Activity log -->
        <div class="card">
          <div class="card-head">
            <span class="card-title">Activity Log</span>
            <span class="card-meta">uploads + logins</span>
          </div>
          <div class="act-log">
            <%= for ev <- @ua.activity_log do %>
              <div class="act-row">
                <div class={["act-dot", ev.kind]}><%= if ev.kind == "upload", do: "F", else: "L" %></div>
                <div class="act-body">
                  <%= if ev.kind == "upload" do %>
                    <%# Filename intentionally hidden — show only CAS identifiers %>
                    <div class="act-label mono" style="font-size:10px;color:var(--muted)"><%= ev.cas_hash %></div>
                    <div class="act-sub"><%= ev.file_type %></div>
                  <% else %>
                    <div class="act-label"><%= ev.device %></div>
                    <div class="act-sub"><%= ev.ip_address %></div>
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

      <!-- ROW F: Identity + Recent files -->
      <div class="up-row2">
        <div class="card">
          <div class="card-head"><span class="card-title">Identity</span></div>
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
          <div class="card-head"><span class="card-title">Recent Files (<%= @user_detail.file_count %>)</span></div>
          <div class="scroll-list">
            <%# Filenames are NOT shown in the super-admin view — only CAS identifiers %>
            <%= for f <- Enum.take(@user_detail.files, 20) do %>
              <div class="list-row">
                <span class="file-icon"><%= ctic(f.content_type) %></span>
                <div>
                  <div class="row-name mono" style="font-size:10px;color:var(--muted)"><%= String.slice(f.content_hash || "—", 0, 20) %>...</div>
                  <div class="row-meta"><%= sct(f.content_type) %> · <%= fd(f.inserted_at) %></div>
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
