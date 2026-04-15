defmodule AlemWeb.Admin.Helpers do
  @moduledoc """
  Pure formatting utilities shared across all admin pages.
  No database calls, no LiveView dependencies.
  Add new formatters here — import this module in any page that needs them.
  """

  # ── Date helpers ──────────────────────────────────────────────────────────
  def fd(nil), do: "—"
  def fd(%NaiveDateTime{} = d), do: NaiveDateTime.to_date(d) |> Date.to_string()
  def fd(%DateTime{} = d),      do: DateTime.to_date(d) |> Date.to_string()
  def fd(_), do: "—"

  def fd_short(nil), do: "—"
  def fd_short(%NaiveDateTime{} = d) do
    months = ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
    Enum.at(months, d.month - 1) <> " \#{d.day}"
  end
  def fd_short(_), do: "—"

  # ── Time ago formatter ────────────────────────────────────────────────────
  def time_ago(nil), do: "—"
  def time_ago(%NaiveDateTime{} = dt) do
    now   = NaiveDateTime.utc_now()
    diff  = NaiveDateTime.diff(now, dt, :second)
    cond do
      diff < 60      -> "just now"
      diff < 3600    -> "#{div(diff, 60)}m ago"
      diff < 86400   -> "#{div(diff, 3600)}h ago"
      diff < 2592000 -> "#{div(diff, 86400)}d ago"
      diff < 31536000-> "#{div(diff, 2592000)} mo ago"
      true           -> "#{div(diff, 31536000)}yr ago"
    end
  end
  def time_ago(%DateTime{} = dt) do
    time_ago(DateTime.to_naive(dt))
  end
  def time_ago(_), do: "—"

  # ── Duration since joined ─────────────────────────────────────────────────
  # e.g. "3 days" / "1 year"
  def joined_ago(nil), do: "—"
  def joined_ago(%NaiveDateTime{} = dt) do
    now  = NaiveDateTime.utc_now()
    diff = NaiveDateTime.diff(now, dt, :second)
    cond do
      diff < 86400   -> "today"
      diff < 172800  -> "1 day"
      diff < 2592000 -> "#{div(diff, 86400)} days"
      diff < 5184000 -> "1 month"
      diff < 31536000-> "#{div(diff, 2592000)} months"
      diff < 63072000-> "1 year"
      true           -> "#{div(diff, 31536000)} years"
    end
  end
  def joined_ago(%DateTime{} = dt), do: joined_ago(DateTime.to_naive(dt))
  def joined_ago(_), do: "—"


  # ── Content-type icon ─────────────────────────────────────────────────────
  def ctic(nil), do: "◈"
  def ctic(ct) do
    cond do
      String.starts_with?(ct, "image/")              -> "◉"
      ct == "application/pdf"                        -> "◧"
      String.contains?(ct, "word")                   -> "◫"
      String.contains?(ct, "sheet")                  -> "◨"
      String.starts_with?(ct, "video/")              -> "◑"
      String.starts_with?(ct, "audio/")              -> "◐"
      String.starts_with?(ct, "text/")               -> "◪"
      String.contains?(ct, "zip")                    -> "◩"
      true                                           -> "◈"
    end
  end

  def sct(nil), do: "unknown"
  def sct(ct),  do: ct |> String.split("/") |> List.last() |> String.split(".") |> List.last() |> String.slice(0, 12)

  # ── MIME label (for chart legends) ────────────────────────────────────────
  # SECURITY: filenames never shown — only MIME type label visible to admin
  def short_mime(nil), do: "Binary"
  def short_mime("unknown"), do: "Binary"
  def short_mime("application/octet-stream"), do: "Binary"
  def short_mime(ct) do
    cond do
      ct == "application/pdf"          -> "PDF"
      String.contains?(ct, "word")     -> "DOCX"
      String.contains?(ct, "sheet")    -> "XLSX"
      String.contains?(ct, "zip")      -> "ZIP"
      ct == "application/msword"       -> "DOC"
      true ->
        ct |> String.split("/") |> List.last()
           |> String.split(".") |> List.last()
           |> String.slice(0, 10) |> String.upcase()
    end
  end

  # ── SQL result cell formatter ─────────────────────────────────────────────
  def fmt_cell(nil),                    do: "NULL"
  def fmt_cell(v) when is_binary(v),   do: v
  def fmt_cell(v) when is_boolean(v),  do: to_string(v)
  def fmt_cell(v) when is_integer(v),  do: Integer.to_string(v)
  def fmt_cell(v) when is_float(v),    do: Float.to_string(Float.round(v, 4))
  def fmt_cell(%Decimal{} = v),        do: Decimal.to_string(v)
  def fmt_cell(%NaiveDateTime{} = v),  do: NaiveDateTime.to_string(v)
  def fmt_cell(%DateTime{} = v),       do: DateTime.to_string(v)
  def fmt_cell(v),                     do: inspect(v)

  def parse_size(s) when is_binary(s),   do: String.to_integer(s)
  def parse_size(i) when is_integer(i),  do: i
  def parse_size(%Decimal{} = d),        do: Decimal.to_integer(d)
  def parse_size(_), do: 0

  def to_int_safe(%Decimal{} = d), do: Decimal.to_integer(d)
  def to_int_safe(i) when is_integer(i), do: i
  def to_int_safe(_), do: 0

  def compute_pct(val, max) do
    b = to_int_safe(val)
    m = max(to_int_safe(max), 1)
    min(100, round(b / m * 100))
  end
end
