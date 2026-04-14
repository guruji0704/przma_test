defmodule AlemWeb.Admin.Components do
  @moduledoc """
  Shared UI components used across admin pages.
  Import this in any page that needs back_button, pagination, storage_bar, etc.

  To add a new shared component:
    1. Add a def here with @doc
    2. Import it in the pages that need it
  """
  use Phoenix.Component
  import AlemWeb.Admin.Helpers

  # ── Back button ────────────────────────────────────────────────────────────
  attr :label, :string, default: "Back"
  def back_button(assigns) do
    ~H"""
    <button class="back-btn" phx-click="nav_back">
      <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor"
           stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
        <line x1="19" y1="12" x2="5" y2="12"/>
        <polyline points="12 19 5 12 12 5"/>
      </svg>
      <%= @label %>
    </button>
    """
  end

  # ── Pagination ─────────────────────────────────────────────────────────────
  attr :d, :map,    required: true   # expects %{page: int, pages: int}
  attr :e, :string, required: true   # event name e.g. "user_page"
  def pagination(%{d: %{pages: p}} = assigns) when p > 1 do
    ~H"""
    <div class="pag">
      <%= for pg <- 1..@d.pages do %>
        <button class={["pag-btn", pg == @d.page && "active"]}
                phx-click={@e} phx-value-page={pg}><%= pg %></button>
      <% end %>
    </div>
    """
  end
  def pagination(assigns), do: ~H""

  # ── Storage bar (used in monitoring + dashboard) ───────────────────────────
  attr :label, :string, required: true
  attr :value, :any,    required: true
  attr :max,   :any,    required: true
  attr :color, :string, default: "blue"
  attr :fmt,   :string, default: ""
  def storage_bar(assigns) do
    pct = compute_pct(assigns.value, assigns.max)
    assigns = assign(assigns, :pct, pct)
    ~H"""
    <div class="sbar-row">
      <div class="sbar-label"><%= @label %></div>
      <div class="sbar-track">
        <div class={["sbar-fill", "sbar-#{@color}"]} style={"width:#{@pct}%"}></div>
      </div>
      <div class="sbar-val"><%= @fmt %></div>
    </div>
    """
  end

  # ── Stat card (used in dashboard) ──────────────────────────────────────────
  attr :label, :string, required: true
  attr :value, :any,    required: true
  attr :color, :string, default: "blue"
  attr :icon,  :string, default: ""
  attr :page,  :string, default: ""
  def stat_card(assigns) do
    ~H"""
    <div class={["sc", @color, @page != "" && "sc-link"]}
         phx-click={if @page != "", do: "nav", else: nil}
         phx-value-page={@page}>
      <div class="sc-icon"><%= @icon %></div>
      <div class="sc-val"><%= @value %></div>
      <div class="sc-lbl"><%= @label %></div>
    </div>
    """
  end

  # ── Service row (used in dashboard) ────────────────────────────────────────
  # Called as: <.svc_row name="PostgreSQL" status="online" />
  attr :name,   :string, required: true
  attr :status, :string, default: "online"
  def svc_row(assigns) do
    ~H"""
    <div class="svc-row">
      <div class={["svc-dot", @status]}></div>
      <span><%= @name %></span>
      <span class={["svc-badge", @status]}><%= String.capitalize(@status) %></span>
    </div>
    """
  end

  # ── User badges ────────────────────────────────────────────────────────────
  attr :u, :map, required: true
  def user_badges(assigns) do
    ~H"""
    <%= if !@u.is_active do %><span class="badge red">Blocked</span><% end %>
    <%= if @u.is_admin do %><span class="badge amber">Admin</span><% end %>
    <%= if @u.is_moderator do %><span class="badge purple">Mod</span><% end %>
    <%= if @u.is_verified do %><span class="badge blue">Verified</span><% else %><span class="badge gray">Unverified</span><% end %>
    """
  end
  # ── Stat card (KPI card on dashboard) ──────────────────────────────────────
  # Clickable card that navigates to a page. Used by dashboard.ex.
  # attrs: lb (label), v (value), ic (icon key), cl (color class), nav, nav_filter, tt
  attr :lb,         :string,  required: true
  attr :v,          :any,     required: true
  attr :ic,         :string,  default: "circle"
  attr :cl,         :string,  default: "blue"
  attr :nav,        :string,  default: ""
  attr :nav_filter, :string,  default: ""
  attr :tt,         :string,  default: ""
  def sc(assigns) do
    icon_svg =
      case assigns.ic do
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
      class={["sc", "sc-\#{@cl}", "sc-click"]}
      phx-click={if @nav_filter != "", do: "nav_filtered", else: "nav"}
      phx-value-page={@nav}
      phx-value-filter={@nav_filter}
      title={@tt}
    >
      <div class="sc-ic">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor"
             stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <%= Phoenix.HTML.raw(@icon_svg) %>
        </svg>
      </div>
      <div class="sc-body">
        <div class="sc-v"><%= @v %></div>
        <div class="sc-l"><%= @lb %></div>
      </div>
      <div class="sc-arr">&#8594;</div>
    </div>
    """
  end

  # ── Back to dashboard button (used in analytics drill-down pages) ───────────
  def back_to_dash(assigns) do
    ~H"""
    <div style="display:flex;align-items:center;gap:10px;margin-bottom:18px">
      <button class="btn-sm" phx-click="nav_back">&#8592; Back</button>
      <span class="section-label" style="margin:0">Drill-down Analytics</span>
    </div>
    """
  end

end
