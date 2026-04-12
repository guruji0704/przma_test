defmodule AlemWeb.AdminLive.Pages.Analytics do
  @moduledoc "Drill-down analytics: Users, Storage, CAS. Each with multiple chart types."
  use Phoenix.Component
  import AlemWeb.AdminLive.Helpers
  alias Alem.Admin
  alias AlemWeb.AdminLive.Charts

  # ── USER ANALYTICS ────────────────────────────────────────────────────────

  def users(%{analytics_users: nil} = assigns) do
    ~H"""
    <div class="empty-page">Loading user analytics...</div>
    """
  end

  def users(assigns) do
    a = assigns.analytics_users

    su_labels  = Enum.map(a.daily_signups, & &1.date)
    su_data    = Enum.map(a.daily_signups, & &1.count)
    area_chart = Charts.line(su_labels, [%{
      label: "Signups", data: su_data,
      borderColor: "#58a6ff", backgroundColor: "rgba(88,166,255,.15)",
      fill: true, tension: 0.4, pointRadius: 4, pointBackgroundColor: "#58a6ff"
    }])

    pie_chart = Charts.pie(
      ["Verified", "Unverified"],
      [a.verified, a.unverified],
      ["#3fb950", "#484f58"]
    )

    donut_chart = Charts.doughnut(
      ["Active", "Blocked", "Admin"],
      [a.active - a.admins, a.blocked, a.admins],
      ["#58a6ff", "#f85149", "#e3b341"]
    )

    hbar_labels = Enum.map(a.top_users, & &1.nickname)
    hbar_data   = Enum.map(a.top_users, & &1.files)
    hbar_chart  = Charts.hbar(hbar_labels, hbar_data, "Files", "rgba(188,140,255,.7)")

    radar_chart = Charts.radar(
      ["Total", "Verified", "Active", "Admins", "W/ Files"],
      [%{
        label: "Platform Users",
        data: [
          a.total,
          a.verified,
          a.active,
          a.admins,
          Enum.count(a.top_users, & &1.files > 0)
        ],
        backgroundColor: "rgba(88,166,255,.2)",
        borderColor: "#58a6ff",
        pointBackgroundColor: "#58a6ff",
        pointRadius: 4
      }]
    )

    vrate       = if a.total > 0, do: round(a.verified / a.total * 100), else: 0
    gauge_chart = Charts.gauge(vrate, "#3fb950")

    assigns =
      assigns
      |> assign(:area_chart,  area_chart)
      |> assign(:pie_chart,   pie_chart)
      |> assign(:donut_chart, donut_chart)
      |> assign(:hbar_chart,  hbar_chart)
      |> assign(:radar_chart, radar_chart)
      |> assign(:gauge_chart, gauge_chart)
      |> assign(:vrate, vrate)
      |> assign(:a, a)

    ~H"""
    <div>
      <%= back_to_dash(assigns) %>
      <div class="a-strip">
        <.astat v={@a.total}       lb="Total Users"  col="#58a6ff" />
        <.astat v={@a.verified}    lb="Verified"     col="#3fb950" />
        <.astat v={@a.unverified}  lb="Unverified"   col="#484f58" />
        <.astat v={@a.active}      lb="Active"       col="#58a6ff" />
        <.astat v={@a.blocked}     lb="Blocked"      col="#f85149" />
        <.astat v={@a.admins}      lb="Admins"       col="#e3b341" />
      </div>

      <div class="chart-r3" style="margin-bottom:12px">
        <div class="chart-card span2">
          <div class="chart-title">User Signups — Last 30 Days <span class="ct-sub">(Area)</span></div>
          <%= if @a.daily_signups != [] do %>
            <div class="chart-h200"><canvas id="c-area" phx-hook="Chart" data-chart={@area_chart}></canvas></div>
          <% else %>
            <div class="chart-empty">No signups in the last 30 days</div>
          <% end %>
        </div>
        <div class="chart-card">
          <div class="chart-title">Verification Rate <span class="ct-sub">(Gauge)</span></div>
          <div class="gauge-wrap">
            <canvas id="c-gauge" phx-hook="Chart" data-chart={@gauge_chart}></canvas>
            <div class="gauge-label"><%= @vrate %>%<br/><span>verified</span></div>
          </div>
        </div>
      </div>

      <div class="chart-r3" style="margin-bottom:12px">
        <div class="chart-card">
          <div class="chart-title">Verified vs Unverified <span class="ct-sub">(Pie)</span></div>
          <div class="chart-h180"><canvas id="c-pie" phx-hook="Chart" data-chart={@pie_chart}></canvas></div>
        </div>
        <div class="chart-card">
          <div class="chart-title">Account Status <span class="ct-sub">(Doughnut)</span></div>
          <div class="chart-h180"><canvas id="c-donut" phx-hook="Chart" data-chart={@donut_chart}></canvas></div>
        </div>
        <div class="chart-card">
          <div class="chart-title">Platform Profile <span class="ct-sub">(Radar)</span></div>
          <div class="chart-h180"><canvas id="c-radar" phx-hook="Chart" data-chart={@radar_chart}></canvas></div>
        </div>
      </div>

      <div class="chart-card">
        <div class="chart-title">Files per User <span class="ct-sub">(Horizontal Bar)</span></div>
        <%= if @a.top_users != [] do %>
          <div class="chart-h200"><canvas id="c-hbar" phx-hook="Chart" data-chart={@hbar_chart}></canvas></div>
        <% else %>
          <div class="chart-empty">No files yet</div>
        <% end %>
      </div>
    </div>
    """
  end

  # ── STORAGE ANALYTICS ─────────────────────────────────────────────────────

  def storage(%{analytics_storage: nil} = assigns) do
    ~H"""
    <div class="empty-page">Loading storage analytics...</div>
    """
  end

  def storage(assigns) do
    a = assigns.analytics_storage

    up_labels  = Enum.map(a.daily_uploads, & &1.date)
    up_data    = Enum.map(a.daily_uploads, & &1.count)
    area_chart = Charts.line(up_labels, [%{
      label: "Uploads", data: up_data,
      borderColor: "#bc8cff", backgroundColor: "rgba(188,140,255,.15)",
      fill: true, tension: 0.4, pointRadius: 4, pointBackgroundColor: "#bc8cff"
    }])

    top8   = Enum.take(a.type_breakdown, 8)
    colors = ~w(#58a6ff #3fb950 #e3b341 #f85149 #bc8cff #06b6d4 #f97316 #8b5cf6)

    pie_chart = Charts.pie(
      Enum.map(top8, & short_mime(&1.type)),
      Enum.map(top8, & &1.count),
      colors
    )

    donut_chart = Charts.doughnut(
      ["Used", "Saved by Dedup"],
      [max(a.total_bytes - a.saved_bytes, 0), a.saved_bytes],
      ["#58a6ff", "#3fb950"]
    )

    bar_labels = Enum.map(top8, & short_mime(&1.type))
    bar_data   = Enum.map(top8, fn t -> Float.round(t.bytes / 1_048_576, 1) end)
    col_chart  = Charts.bar(bar_labels, bar_data, "MB", colors)

    stack_chart = Charts.stacked(bar_labels, [
      %{label: "File Count", data: Enum.map(top8, & &1.count),
        backgroundColor: "rgba(88,166,255,.7)", borderRadius: 3},
      %{label: "Size (MB)", data: bar_data,
        backgroundColor: "rgba(63,185,80,.7)", borderRadius: 3}
    ])

    eff_pct     = if a.total_bytes > 0, do: round(a.saved_bytes / a.total_bytes * 100), else: 0
    gauge_chart = Charts.gauge(eff_pct, "#3fb950")

    assigns =
      assigns
      |> assign(:area_chart,  area_chart)
      |> assign(:pie_chart,   pie_chart)
      |> assign(:donut_chart, donut_chart)
      |> assign(:col_chart,   col_chart)
      |> assign(:stack_chart, stack_chart)
      |> assign(:gauge_chart, gauge_chart)
      |> assign(:eff_pct, eff_pct)
      |> assign(:a, a)

    ~H"""
    <div>
      <%= back_to_dash(assigns) %>
      <div class="a-strip">
        <.astat v={@a.total_files}                        lb="Documents"    col="#bc8cff" />
        <.astat v={@a.total_cas}                          lb="CAS Objects"  col="#58a6ff" />
        <.astat v={Admin.format_bytes(@a.total_bytes)}    lb="Total Stored" col="#3fb950" />
        <.astat v={Admin.format_bytes(@a.saved_bytes)}    lb="Dedup Saved"  col="#3fb950" />
        <.astat v={length(@a.type_breakdown)}             lb="File Types"   col="#e3b341" />
        <.astat v={"#{@eff_pct}%"}                        lb="Dedup Rate"   col="#bc8cff" />
      </div>

      <div class="chart-r3" style="margin-bottom:12px">
        <div class="chart-card span2">
          <div class="chart-title">Uploads Per Day — Last 30 Days <span class="ct-sub">(Area)</span></div>
          <%= if @a.daily_uploads != [] do %>
            <div class="chart-h200"><canvas id="c-up" phx-hook="Chart" data-chart={@area_chart}></canvas></div>
          <% else %>
            <div class="chart-empty">No uploads in last 30 days</div>
          <% end %>
        </div>
        <div class="chart-card">
          <div class="chart-title">Dedup Efficiency <span class="ct-sub">(Gauge)</span></div>
          <div class="gauge-wrap">
            <canvas id="c-geff" phx-hook="Chart" data-chart={@gauge_chart}></canvas>
            <div class="gauge-label"><%= @eff_pct %>%<br/><span>saved</span></div>
          </div>
        </div>
      </div>

      <div class="chart-r3" style="margin-bottom:12px">
        <div class="chart-card">
          <div class="chart-title">File Types by Count <span class="ct-sub">(Pie)</span></div>
          <div class="chart-h180">
            <%= if @a.type_breakdown != [] do %>
              <canvas id="c-ftype" phx-hook="Chart" data-chart={@pie_chart}></canvas>
            <% else %>
              <div class="chart-empty">No data</div>
            <% end %>
          </div>
        </div>
        <div class="chart-card">
          <div class="chart-title">Used vs Saved Storage <span class="ct-sub">(Doughnut)</span></div>
          <div class="chart-h180"><canvas id="c-stor" phx-hook="Chart" data-chart={@donut_chart}></canvas></div>
        </div>
        <div class="chart-card">
          <div class="chart-title">Count vs Size Per Type <span class="ct-sub">(Stacked Bar)</span></div>
          <div class="chart-h180">
            <%= if @a.type_breakdown != [] do %>
              <canvas id="c-stk" phx-hook="Chart" data-chart={@stack_chart}></canvas>
            <% else %>
              <div class="chart-empty">No data</div>
            <% end %>
          </div>
        </div>
      </div>

      <div class="chart-card">
        <div class="chart-title">Storage by File Type in MB <span class="ct-sub">(Column)</span></div>
        <%= if @a.type_breakdown != [] do %>
          <div class="chart-h200"><canvas id="c-col" phx-hook="Chart" data-chart={@col_chart}></canvas></div>
        <% else %>
          <div class="chart-empty">No data</div>
        <% end %>
      </div>
    </div>
    """
  end

  # ── CAS ANALYTICS ─────────────────────────────────────────────────────────

  def cas(%{analytics_cas: nil} = assigns) do
    ~H"""
    <div class="empty-page">Loading CAS analytics...</div>
    """
  end

  def cas(assigns) do
    a = assigns.analytics_cas

    ref_labels = Enum.map(a.ref_dist, fn r -> "#{r.ref_count}x" end)
    ref_data   = Enum.map(a.ref_dist, fn r -> r.count end)
    col_chart  = Charts.bar(ref_labels, ref_data, "Objects",
      Enum.map(a.ref_dist, fn r ->
        if r.ref_count == 1, do: "rgba(88,166,255,.7)", else: "rgba(245,158,11,.7)"
      end))

    donut_chart = Charts.doughnut(
      ["Unique", "Duplicates"],
      [a.total_cas - a.dupes, a.dupes],
      ["#3fb950", "#e3b341"]
    )

    waste    = a.saved_bytes
    actual   = max(a.total_bytes - waste, 0)
    pie_chart = Charts.pie(
      ["Actual Storage", "Wasted (dupes)"],
      [actual, waste],
      ["#58a6ff", "#f85149"]
    )

    gauge_chart = Charts.gauge(a.dedup_pct, "#e3b341")

    total_safe  = max(a.total_cas, 1)
    radar_chart = Charts.radar(
      ["Unique", "Dedup Rate", "Space Saved", "Verified", "Multi-ref"],
      [%{
        label: "CAS Health",
        data: [
          round((a.total_cas - a.dupes) / total_safe * 100),
          a.dedup_pct,
          if(a.total_bytes > 0, do: round(a.saved_bytes / a.total_bytes * 100), else: 0),
          90,
          round(a.dupes / total_safe * 100)
        ],
        backgroundColor: "rgba(227,179,65,.2)",
        borderColor: "#e3b341",
        pointBackgroundColor: "#e3b341",
        pointRadius: 4
      }]
    )

    scatter_data = Enum.map(a.top_dupes, fn d ->
      %{x: Float.round(d.file_size / 1_048_576, 2), y: d.ref_count}
    end)
    scatter_chart = Charts.scatter([%{
      label: "File size (MB) vs Ref count",
      data: scatter_data,
      backgroundColor: "rgba(245,158,11,.7)",
      pointRadius: 6,
      pointHoverRadius: 8
    }])

    assigns =
      assigns
      |> assign(:col_chart,     col_chart)
      |> assign(:donut_chart,   donut_chart)
      |> assign(:pie_chart,     pie_chart)
      |> assign(:gauge_chart,   gauge_chart)
      |> assign(:radar_chart,   radar_chart)
      |> assign(:scatter_chart, scatter_chart)
      |> assign(:a, a)

    ~H"""
    <div>
      <%= back_to_dash(assigns) %>
      <div class="a-strip">
        <.astat v={@a.total_cas}                        lb="CAS Objects"  col="#58a6ff" />
        <.astat v={@a.total_cas - @a.dupes}             lb="Unique"       col="#3fb950" />
        <.astat v={@a.dupes}                            lb="Duplicates"   col="#e3b341" />
        <.astat v={Admin.format_bytes(@a.saved_bytes)}  lb="Space Saved"  col="#3fb950" />
        <.astat v={Admin.format_bytes(@a.total_bytes)}  lb="Total Size"   col="#58a6ff" />
        <.astat v={"#{@a.dedup_pct}%"}                  lb="Dedup Rate"   col="#bc8cff" />
      </div>

      <div class="chart-r3" style="margin-bottom:12px">
        <div class="chart-card span2">
          <div class="chart-title">Reference Count Distribution <span class="ct-sub">(Column)</span></div>
          <%= if @a.ref_dist != [] do %>
            <div class="chart-h200"><canvas id="c-ref" phx-hook="Chart" data-chart={@col_chart}></canvas></div>
          <% else %>
            <div class="chart-empty">No CAS objects yet</div>
          <% end %>
        </div>
        <div class="chart-card">
          <div class="chart-title">Dedup Rate <span class="ct-sub">(Gauge)</span></div>
          <div class="gauge-wrap">
            <canvas id="c-cgauge" phx-hook="Chart" data-chart={@gauge_chart}></canvas>
            <div class="gauge-label"><%= @a.dedup_pct %>%<br/><span>efficiency</span></div>
          </div>
        </div>
      </div>

      <div class="chart-r3" style="margin-bottom:12px">
        <div class="chart-card">
          <div class="chart-title">Unique vs Duplicate <span class="ct-sub">(Doughnut)</span></div>
          <div class="chart-h180"><canvas id="c-cdonut" phx-hook="Chart" data-chart={@donut_chart}></canvas></div>
        </div>
        <div class="chart-card">
          <div class="chart-title">Storage Breakdown <span class="ct-sub">(Pie)</span></div>
          <div class="chart-h180"><canvas id="c-cpie" phx-hook="Chart" data-chart={@pie_chart}></canvas></div>
        </div>
        <div class="chart-card">
          <div class="chart-title">CAS Health Profile <span class="ct-sub">(Radar)</span></div>
          <div class="chart-h180"><canvas id="c-cradar" phx-hook="Chart" data-chart={@radar_chart}></canvas></div>
        </div>
      </div>

      <%= if @a.top_dupes != [] do %>
        <div class="chart-card" style="margin-bottom:12px">
          <div class="chart-title">File Size vs Reference Count <span class="ct-sub">(Scatter)</span></div>
          <div class="chart-h200"><canvas id="c-scatter" phx-hook="Chart" data-chart={@scatter_chart}></canvas></div>
        </div>

        <div class="card">
          <div class="card-head"><span class="card-title">Top Duplicated Objects</span></div>
          <div class="tbl-wrap" style="border:none;border-radius:0">
            <table class="data-table">
              <thead>
                <tr>
                  <th>Hash</th>
                  <th>Type</th>
                  <th class="ta-r">Size</th>
                  <th class="ta-r">Refs</th>
                  <th class="ta-r">Space Saved</th>
                </tr>
              </thead>
              <tbody>
                <%= for obj <- @a.top_dupes do %>
                  <tr class="data-row">
                    <td class="mono" style="font-size:10px"><%= String.slice(obj.content_hash, 0, 20) %>...</td>
                    <td style="font-size:11px"><%= short_mime(obj.media_type) %></td>
                    <td class="ta-r mono" style="font-size:11px"><%= Admin.format_bytes(obj.file_size) %></td>
                    <td class="ta-r"><span class="dup-badge"><%= obj.ref_count %>x</span></td>
                    <td class="ta-r mono ok" style="font-size:11px"><%= Admin.format_bytes(obj.saved) %></td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ── Private components ─────────────────────────────────────────────────────

  defp astat(assigns) do
    ~H"""
    <div class="a-stat">
      <div class="a-val" style={"color:#{@col}"}><%= @v %></div>
      <div class="a-lbl"><%= @lb %></div>
    </div>
    """
  end

  defp back_to_dash(assigns) do
    ~H"""
    <div style="display:flex;align-items:center;gap:10px;margin-bottom:16px">
      <button class="back-btn" phx-click="nav" phx-value-page="dashboard">&larr; Dashboard</button>
      <span class="muted sm">Drill-down Analytics</span>
    </div>
    """
  end

  defp short_mime(nil), do: "Unknown"
  defp short_mime(ct) do
    cond do
      ct == "application/pdf"                          -> "PDF"
      String.contains?(ct, "wordprocessingml")         -> "DOCX"
      String.contains?(ct, "spreadsheetml")            -> "XLSX"
      ct == "application/octet-stream"                 -> "Binary"
      ct == "application/msword"                       -> "DOC"
      true ->
        ct |> String.split("/") |> List.last()
           |> String.split(".") |> List.last()
           |> String.slice(0, 10) |> String.upcase()
    end
  end
end
