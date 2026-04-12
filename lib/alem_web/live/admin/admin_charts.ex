defmodule AlemWeb.AdminLive.Charts do
  @moduledoc "Chart.js JSON config builders for the PRZMA admin analytics pages."

  defp base_opts(extra \\ %{}) do
    Map.merge(%{
      responsive: true,
      maintainAspectRatio: false
    }, extra)
  end

  # ── Line / Area ────────────────────────────────────────────────────────────

  def line(labels, datasets) do
    Jason.encode!(%{
      type: "line",
      data: %{labels: labels, datasets: datasets},
      options: base_opts(%{
        plugins: %{legend: %{display: length(datasets) > 1, labels: %{color: "#8b949e", boxWidth: 10}}},
        scales: %{
          x: %{grid: %{color: "rgba(255,255,255,.04)"}, ticks: %{color: "#6e7681", maxRotation: 45, font: %{size: 10}}},
          y: %{grid: %{color: "rgba(255,255,255,.04)"}, ticks: %{color: "#6e7681", font: %{size: 10}}, beginAtZero: true}
        }
      })
    })
  end

  # ── Vertical bar (Column) ──────────────────────────────────────────────────

  def bar(labels, data, label, color) do
    Jason.encode!(%{
      type: "bar",
      data: %{labels: labels, datasets: [%{label: label, data: data,
        backgroundColor: color, borderRadius: 4, borderWidth: 0}]},
      options: base_opts(%{
        plugins: %{legend: %{display: false}},
        scales: %{
          x: %{grid: %{display: false}, ticks: %{color: "#6e7681", font: %{size: 10}, maxRotation: 45}},
          y: %{grid: %{color: "rgba(255,255,255,.04)"}, ticks: %{color: "#6e7681", font: %{size: 10}}, beginAtZero: true}
        }
      })
    })
  end

  # ── Stacked bar (multi-dataset) ────────────────────────────────────────────

  def stacked(labels, datasets) do
    Jason.encode!(%{
      type: "bar",
      data: %{labels: labels, datasets: datasets},
      options: base_opts(%{
        plugins: %{legend: %{display: true, position: "bottom", labels: %{color: "#8b949e", boxWidth: 10, font: %{size: 10}}}},
        scales: %{
          x: %{stacked: true, grid: %{display: false}, ticks: %{color: "#6e7681", font: %{size: 10}}},
          y: %{stacked: true, grid: %{color: "rgba(255,255,255,.04)"}, ticks: %{color: "#6e7681", font: %{size: 10}}, beginAtZero: true}
        }
      })
    })
  end

  # ── Horizontal bar ─────────────────────────────────────────────────────────

  def hbar(labels, data, label, color) do
    Jason.encode!(%{
      type: "bar",
      data: %{labels: labels, datasets: [%{label: label, data: data,
        backgroundColor: color, borderRadius: 4, borderWidth: 0}]},
      options: base_opts(%{
        indexAxis: "y",
        plugins: %{legend: %{display: false}},
        scales: %{
          x: %{grid: %{color: "rgba(255,255,255,.04)"}, ticks: %{color: "#6e7681", font: %{size: 10}}, beginAtZero: true},
          y: %{grid: %{display: false}, ticks: %{color: "#6e7681", font: %{size: 10}}}
        }
      })
    })
  end

  # ── Doughnut ───────────────────────────────────────────────────────────────

  def doughnut(labels, data, colors, cutout \\ "65%") do
    Jason.encode!(%{
      type: "doughnut",
      data: %{labels: labels, datasets: [%{data: data, backgroundColor: colors, borderWidth: 0, hoverOffset: 6}]},
      options: base_opts(%{
        cutout: cutout,
        plugins: %{legend: %{position: "right", labels: %{color: "#8b949e", boxWidth: 10, padding: 10, font: %{size: 10}}}}
      })
    })
  end

  # ── Pie ────────────────────────────────────────────────────────────────────

  def pie(labels, data, colors) do
    Jason.encode!(%{
      type: "pie",
      data: %{labels: labels, datasets: [%{data: data, backgroundColor: colors, borderWidth: 0, hoverOffset: 6}]},
      options: base_opts(%{
        plugins: %{legend: %{position: "right", labels: %{color: "#8b949e", boxWidth: 10, padding: 10, font: %{size: 10}}}}
      })
    })
  end

  # ── Radar / Spider ─────────────────────────────────────────────────────────

  def radar(labels, datasets) do
    Jason.encode!(%{
      type: "radar",
      data: %{labels: labels, datasets: datasets},
      options: base_opts(%{
        plugins: %{legend: %{display: true, position: "bottom", labels: %{color: "#8b949e", boxWidth: 10, font: %{size: 10}}}},
        scales: %{r: %{
          angleLines: %{color: "rgba(255,255,255,.08)"},
          grid: %{color: "rgba(255,255,255,.08)"},
          pointLabels: %{color: "#8b949e", font: %{size: 10}},
          ticks: %{color: "#6e7681", font: %{size: 9}, backdropColor: "transparent"}
        }}
      })
    })
  end

  # ── Scatter ────────────────────────────────────────────────────────────────

  def scatter(datasets) do
    Jason.encode!(%{
      type: "scatter",
      data: %{datasets: datasets},
      options: base_opts(%{
        plugins: %{legend: %{display: true, position: "bottom", labels: %{color: "#8b949e", boxWidth: 10, font: %{size: 10}}}},
        scales: %{
          x: %{grid: %{color: "rgba(255,255,255,.04)"}, ticks: %{color: "#6e7681", font: %{size: 10}}},
          y: %{grid: %{color: "rgba(255,255,255,.04)"}, ticks: %{color: "#6e7681", font: %{size: 10}}, beginAtZero: true}
        }
      })
    })
  end

  # ── Gauge (simulated with half-doughnut) ───────────────────────────────────

  def gauge(pct, color) do
    remaining = 100 - pct
    Jason.encode!(%{
      type: "doughnut",
      data: %{
        labels: ["", ""],
        datasets: [%{
          data: [pct, remaining],
          backgroundColor: [color, "rgba(255,255,255,.06)"],
          borderWidth: 0, circumference: 180, rotation: 270
        }]
      },
      options: base_opts(%{
        cutout: "75%",
        plugins: %{legend: %{display: false}, tooltip: %{enabled: false}}
      })
    })
  end
end
