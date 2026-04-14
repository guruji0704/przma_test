defmodule AlemWeb.Admin.Charts do
  @moduledoc """
  Chart.js 4.x JSON builders for the admin control plane.
  All functions return a JSON string consumed by the Chart LiveView hook.

  Usage:
    chart = Charts.bar(labels, data, "Files", "#58a6ff")
    assign(assigns, :my_chart, chart)
    # template: <canvas phx-hook="Chart" data-chart={@my_chart}></canvas>

  To add a new chart type: add a new def following the same pattern.
  """

  @palette ~w(#58a6ff #3fb950 #e3b341 #f85149 #bc8cff #06b6d4 #f97316 #8b5cf6 #ec4899 #14b8a6)
  def palette, do: @palette

  defp opts(extra) do
    Map.merge(%{responsive: true, maintainAspectRatio: false, animation: %{duration: 400}}, extra)
  end

  defp grids do
    %{
      x: %{grid: %{color: "rgba(255,255,255,.04)"}, ticks: %{color: "#6e7681", font: %{size: 10}, maxRotation: 45}},
      y: %{grid: %{color: "rgba(255,255,255,.04)"}, ticks: %{color: "#6e7681", font: %{size: 10}}, beginAtZero: true}
    }
  end

  defp lgnd(show, pos) do
    %{display: show, position: pos, labels: %{color: "#8b949e", boxWidth: 10, padding: 8, font: %{size: 10}}}
  end

  # ── Line ────────────────────────────────────────────────────────────────────
  def line(labels, datasets) do
    Jason.encode!(%{
      type: "line", data: %{labels: labels, datasets: datasets},
      options: opts(%{plugins: %{legend: lgnd(length(datasets) > 1, "bottom")}, scales: grids()})
    })
  end

  # ── Area (filled line) ──────────────────────────────────────────────────────
  def area(labels, data, label, color) do
    bg = if String.starts_with?(color, "#") and byte_size(color) == 7, do: color <> "26", else: "rgba(88,140,255,0.15)"
    line(labels, [%{
      label: label, data: data,
      borderColor: color, backgroundColor: bg,
      fill: true, tension: 0.4, pointRadius: 3, pointBackgroundColor: color
    }])
  end

  # ── Bar (vertical columns) ──────────────────────────────────────────────────
  def bar(labels, data, label, color) when is_binary(color),
    do: bar(labels, data, label, List.duplicate(color, length(data)))
  def bar(labels, data, label, colors) when is_list(colors) do
    Jason.encode!(%{
      type: "bar",
      data: %{labels: labels, datasets: [%{label: label, data: data, backgroundColor: colors, borderRadius: 5, borderWidth: 0}]},
      options: opts(%{plugins: %{legend: %{display: false}}, scales: grids()})
    })
  end

  # ── Horizontal bar ──────────────────────────────────────────────────────────
  def hbar(labels, data, label, color) do
    Jason.encode!(%{
      type: "bar",
      data: %{labels: labels, datasets: [%{label: label, data: data, backgroundColor: color, borderRadius: 4, borderWidth: 0}]},
      options: opts(%{
        indexAxis: "y",
        plugins: %{legend: %{display: false}},
        scales: %{
          x: %{grid: %{color: "rgba(255,255,255,.04)"}, ticks: %{color: "#6e7681", font: %{size: 10}}, beginAtZero: true},
          y: %{grid: %{display: false}, ticks: %{color: "#6e7681", font: %{size: 10}}}
        }
      })
    })
  end

  # ── Stacked bar ─────────────────────────────────────────────────────────────
  def stacked(labels, datasets) do
    Jason.encode!(%{
      type: "bar", data: %{labels: labels, datasets: datasets},
      options: opts(%{
        plugins: %{legend: lgnd(true, "bottom")},
        scales: %{
          x: %{stacked: true, grid: %{display: false}, ticks: %{color: "#6e7681", font: %{size: 10}}},
          y: %{stacked: true, grid: %{color: "rgba(255,255,255,.04)"}, ticks: %{color: "#6e7681", font: %{size: 10}}, beginAtZero: true}
        }
      })
    })
  end

  # ── Doughnut ────────────────────────────────────────────────────────────────
  def doughnut(labels, data, colors, cutout \\ "68%") do
    Jason.encode!(%{
      type: "doughnut",
      data: %{labels: labels, datasets: [%{data: data, backgroundColor: colors, borderWidth: 0, hoverOffset: 6}]},
      options: opts(%{cutout: cutout, plugins: %{legend: lgnd(true, "right")}})
    })
  end

  # ── Pie ─────────────────────────────────────────────────────────────────────
  def pie(labels, data, colors) do
    Jason.encode!(%{
      type: "pie",
      data: %{labels: labels, datasets: [%{data: data, backgroundColor: colors, borderWidth: 0, hoverOffset: 6}]},
      options: opts(%{plugins: %{legend: lgnd(true, "right")}})
    })
  end

  # ── Radar / Spider ──────────────────────────────────────────────────────────
  def radar(labels, datasets) do
    Jason.encode!(%{
      type: "radar", data: %{labels: labels, datasets: datasets},
      options: opts(%{
        plugins: %{legend: %{display: false}},
        scales: %{r: %{
          angleLines: %{color: "rgba(255,255,255,.08)"},
          grid: %{color: "rgba(255,255,255,.08)"},
          pointLabels: %{color: "#8b949e", font: %{size: 10}},
          ticks: %{color: "#6e7681", font: %{size: 9}, backdropColor: "transparent", stepSize: 25},
          min: 0, max: 100
        }}
      })
    })
  end

  # ── Scatter ─────────────────────────────────────────────────────────────────
  def scatter(datasets) do
    Jason.encode!(%{
      type: "scatter", data: %{datasets: datasets},
      options: opts(%{plugins: %{legend: lgnd(true, "bottom")}, scales: grids()})
    })
  end

  # ── Gauge (half-doughnut) ────────────────────────────────────────────────────
  def gauge(pct, color) do
    pct = max(0, min(100, pct))
    Jason.encode!(%{
      type: "doughnut",
      data: %{labels: ["", ""], datasets: [%{
        data: [pct, 100 - pct],
        backgroundColor: [color, "rgba(255,255,255,.06)"],
        borderWidth: 0, circumference: 180, rotation: 270
      }]},
      options: opts(%{cutout: "78%", plugins: %{legend: %{display: false}, tooltip: %{enabled: false}}})
    })
  end
end
