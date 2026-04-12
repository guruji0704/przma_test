defmodule AlemWeb.AdminLive.Helpers do
  @moduledoc "Shared helper functions and components for admin LiveView pages."
  use Phoenix.Component

  # ── Date formatting ───────────────────────────────────────────────────────

  def fd(nil), do: "—"
  def fd(%NaiveDateTime{} = d), do: NaiveDateTime.to_date(d) |> Date.to_string()
  def fd(%DateTime{} = d),      do: DateTime.to_date(d) |> Date.to_string()
  def fd(_), do: "—"

  # ── Numeric helpers ───────────────────────────────────────────────────────

  def to_int_safe(%Decimal{} = d), do: Decimal.to_integer(d)
  def to_int_safe(i) when is_integer(i), do: i
  def to_int_safe(_), do: 0

  # ── MIME helpers ──────────────────────────────────────────────────────────

  def short_mime(nil), do: "Unknown"
  def short_mime(ct) do
    ct
    |> String.split("/")
    |> List.last()
    |> String.split(".")
    |> List.last()
    |> String.slice(0, 12)
    |> String.upcase()
  end

  def ctic(nil), do: "◈"
  def ctic(ct) do
    cond do
      String.starts_with?(ct, "image/")  -> "🖼"
      ct == "application/pdf"            -> "📄"
      String.contains?(ct, "word")       -> "📝"
      String.contains?(ct, "sheet")      -> "📊"
      String.starts_with?(ct, "video/")  -> "🎬"
      String.starts_with?(ct, "audio/")  -> "🎵"
      String.starts_with?(ct, "text/")   -> "📃"
      String.contains?(ct, "zip")        -> "🗜"
      true                               -> "◈"
    end
  end

  def sct(nil), do: "unknown"
  def sct(ct),  do: ct |> String.split("/") |> List.last() |> String.split(".") |> List.last() |> String.slice(0, 12)

  # ── Cell formatting ───────────────────────────────────────────────────────

  def fmt_cell(nil),  do: "NULL"
  def fmt_cell(v) when is_binary(v),  do: v
  def fmt_cell(v) when is_boolean(v), do: to_string(v)
  def fmt_cell(v) when is_integer(v), do: Integer.to_string(v)
  def fmt_cell(v) when is_float(v),   do: Float.to_string(Float.round(v, 4))
  def fmt_cell(%Decimal{} = v),       do: Decimal.to_string(v)
  def fmt_cell(%NaiveDateTime{} = v), do: NaiveDateTime.to_string(v)
  def fmt_cell(%DateTime{} = v),      do: DateTime.to_string(v)
  def fmt_cell(v),                    do: inspect(v)

  def parse_size(s) when is_binary(s), do: String.to_integer(s)
  def parse_size(i) when is_integer(i), do: i
  def parse_size(%Decimal{} = d), do: Decimal.to_integer(d)
  def parse_size(_), do: 0

  # ── Shared components ─────────────────────────────────────────────────────

  def user_badges(assigns) do
    ~H"""
    <%= if !@u.is_active do %><span class="badge red">Blocked</span><% else %><span class="badge green">Active</span><% end %>
    <%= if @u.is_verified do %><span class="badge blue">Verified</span><% else %><span class="badge gray">Unverified</span><% end %>
    <%= if @u.is_admin do %><span class="badge amber">Admin</span><% end %>
    <%= if Map.get(@u, :is_moderator) do %><span class="badge purple">Mod</span><% end %>
    """
  end

  def pagination(%{d: %{pages: p}} = assigns) when p > 1 do
    ~H"""
    <div class="pagination">
      <%= if @d.page > 1 do %>
        <button class="page-btn" phx-click={@e} phx-value-page={@d.page - 1}>‹ Prev</button>
      <% end %>
      <span class="page-info">Page <%= @d.page %> of <%= @d.pages %> · <%= @d.total %> total</span>
      <%= if @d.page < @d.pages do %>
        <button class="page-btn" phx-click={@e} phx-value-page={@d.page + 1}>Next ›</button>
      <% end %>
    </div>
    """
  end
  def pagination(assigns), do: ~H""
end
