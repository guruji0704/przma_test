import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

// Chart.js loaded from CDN in admin layout - hooks below use it

const Hooks = {}

// ChartHook: reads JSON from data-chart attribute and renders Chart.js
Hooks.Chart = {
  mounted() { this.initChart() },
  updated() {
    if (this.chartInstance) { this.chartInstance.destroy() }
    this.initChart()
  },
  destroyed() {
    if (this.chartInstance) { this.chartInstance.destroy() }
  },
  initChart() {
    const el = this.el
    const cfg = JSON.parse(el.dataset.chart || '{}')
    if (!cfg.type) return
    if (typeof window.Chart === 'undefined') {
      // Chart.js not loaded yet, retry
      setTimeout(() => this.initChart(), 200)
      return
    }
    this.chartInstance = new window.Chart(el, cfg)
  }
}

// ThemePersist: zero-flicker theme persistence
Hooks.ThemePersist = {
  mounted() {
    const saved = localStorage.getItem("przma_theme") || "dark"
    this.applyTheme(saved)
    const serverTheme = this.el.dataset.theme || "dark"
    if (saved !== serverTheme) {
      this.pushEvent("restore_theme", { theme: saved })
    }
    this.handleEvent("theme_changed", ({ theme }) => {
      localStorage.setItem("przma_theme", theme)
      this.applyTheme(theme)
    })
  },
  applyTheme(theme) {
    const el = this.el
    el.classList.remove("theme-dark", "theme-light")
    el.classList.add(theme === "light" ? "theme-light" : "theme-dark")
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", () => topbar.show(300))
window.addEventListener("phx:page-loading-stop",  () => topbar.hide())

liveSocket.connect()
window.liveSocket = liveSocket