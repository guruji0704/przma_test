defmodule AlemWeb.AdminLive.Styles do
  @moduledoc "CSS for the PRZMA Control Plane admin UI."

  def css do
    """
    <style>
    @import url('https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600&family=Syne:wght@400;600;700;800&display=swap');

    *, *::before, *::after { margin:0; padding:0; box-sizing:border-box }

    /* ── DARK THEME ─────────────────────────────────────────── */
    .theme-dark {
      --bg:       #0c0c10;
      --bg2:      #13131a;
      --bg3:      #1a1a24;
      --bg4:      #21212e;
      --bg5:      #282836;
      --border:   rgba(255,255,255,.06);
      --border2:  rgba(255,255,255,.11);
      --tx:       #e2e2ee;
      --tx2:      #8888a8;
      --tx3:      #4a4a68;
      --clr-blue:   #5b9eff;
      --clr-green:  #00dda0;
      --clr-red:    #ff5566;
      --clr-amber:  #ffbb00;
      --clr-purple: #a78bfa;
      --clr-orange: #ff8c42;
      --shadow:   0 4px 24px rgba(0,0,0,.5);
      --shadow-lg:0 12px 48px rgba(0,0,0,.7);
      --card-bg:  #13131a;
      --text:     #e2e2ee;
      --muted:    #8888a8;
      --muted2:   #4a4a68;
      --accent:   #5b9eff;
    }

    /* ── LIGHT THEME ─────────────────────────────────────────── */
    .theme-light {
      --bg:       #f0f0f7;
      --bg2:      #ffffff;
      --bg3:      #f7f7fc;
      --bg4:      #ebebf5;
      --bg5:      #e2e2ef;
      --border:   rgba(0,0,0,.07);
      --border2:  rgba(0,0,0,.13);
      --tx:       #16161e;
      --tx2:      #5a5a7a;
      --tx3:      #9898b8;
      --clr-blue:   #2563eb;
      --clr-green:  #059669;
      --clr-red:    #dc2626;
      --clr-amber:  #d97706;
      --clr-purple: #7c3aed;
      --clr-orange: #ea580c;
      --shadow:   0 2px 12px rgba(0,0,0,.08);
      --shadow-lg:0 8px 32px rgba(0,0,0,.14);
      --card-bg:  #ffffff;
      --text:     #16161e;
      --muted:    #5a5a7a;
      --muted2:   #9898b8;
      --accent:   #2563eb;
    }

    /* ── BASE ──────────────────────────────────────────────────── */
    #adm {
      height: 100vh;
      background: var(--bg);
      color: var(--tx);
      font-family: 'Syne', -apple-system, sans-serif;
      overflow: hidden;
      transition: background .2s, color .2s;
    }
    .al { display: grid; grid-template-columns: 220px 1fr; height: 100vh }
    .mono { font-family: 'IBM Plex Mono', 'SF Mono', monospace }

    /* ── SIDEBAR ────────────────────────────────────────────────── */
    .sb {
      background: var(--bg2);
      border-right: 1px solid var(--border);
      display: flex;
      flex-direction: column;
      overflow: hidden;
    }
    .sb-top {
      padding: 16px 14px 10px;
      border-bottom: 1px solid var(--border);
    }
    .sb-logo { display: flex; align-items: center; gap: 10px; margin-bottom: 3px }
    .lm {
      width: 30px; height: 30px;
      background: linear-gradient(135deg, var(--clr-blue), var(--clr-purple));
      border-radius: 8px;
      display: flex; align-items: center; justify-content: center;
      flex-shrink: 0;
    }
    .lt {
      font-size: 15px; font-weight: 800; letter-spacing: 3px;
      background: linear-gradient(135deg, var(--clr-blue), var(--clr-purple));
      -webkit-background-clip: text; -webkit-text-fill-color: transparent;
      background-clip: text;
    }
    .sb-sub { font-size: 9px; color: var(--tx3); letter-spacing: 1.8px; text-transform: uppercase; padding-left: 40px }
    .sb-nav { flex: 1; padding: 8px; overflow-y: auto }
    .nsl {
      font-size: 9px; font-weight: 700; color: var(--tx3);
      letter-spacing: 1.5px; text-transform: uppercase;
      padding: 12px 8px 4px;
    }
    .ni {
      display: flex; align-items: center; gap: 9px;
      padding: 7px 9px; border-radius: 7px;
      border: none; background: none;
      color: var(--tx2); cursor: pointer;
      width: 100%; text-align: left;
      font-size: 12px; font-weight: 600;
      font-family: 'Syne', sans-serif;
      transition: all .15s;
    }
    .ni:hover { background: var(--bg3); color: var(--tx) }
    .ni.active { background: rgba(91,158,255,.1); color: var(--clr-blue) }
    .theme-light .ni.active { background: rgba(37,99,235,.08) }
    .ni-ic { width: 16px; text-align: center; flex-shrink: 0; display: flex; align-items: center; justify-content: center }
    .ni-lb { flex: 1 }
    .ni-bd {
      background: var(--bg4); color: var(--tx3);
      font-size: 10px; padding: 1px 6px; border-radius: 8px;
      font-family: 'IBM Plex Mono', monospace;
    }
    .ni.active .ni-bd { background: rgba(91,158,255,.15); color: var(--clr-blue) }
    .sb-ft { padding: 12px; border-top: 1px solid var(--border); font-size: 11px }
    .ft-stat { display: flex; align-items: center; gap: 7px; margin-bottom: 5px; color: var(--tx2) }
    .ft-stat.accent { color: var(--clr-green) }
    .ft-stat.muted { color: var(--tx3) }
    .ft-dot { width: 6px; height: 6px; border-radius: 50%; background: var(--clr-green); flex-shrink: 0; box-shadow: 0 0 6px rgba(0,221,160,.4) }
    .ft-dot.green { background: var(--clr-green); box-shadow: 0 0 6px rgba(0,221,160,.4) }
    .ft-dot.blue  { background: var(--clr-blue);  box-shadow: 0 0 6px rgba(91,158,255,.4) }

    /* ── TOPBAR ─────────────────────────────────────────────────── */
    .am { display: flex; flex-direction: column; overflow: hidden }
    .tb {
      height: 52px; background: var(--bg2);
      border-bottom: 1px solid var(--border);
      display: flex; align-items: center;
      justify-content: space-between;
      padding: 0 20px; flex-shrink: 0;
    }
    .tb-left { display: flex; flex-direction: column; gap: 1px }
    .tb-t { font-size: 14px; font-weight: 700 }
    .tb-bc { font-size: 10px; color: var(--tx3); font-family: 'IBM Plex Mono', monospace }
    .tb-r { display: flex; align-items: center; gap: 10px }
    .tb-chips { display: flex; gap: 6px }
    .chip {
      font-size: 10px; padding: 3px 9px; border-radius: 20px;
      font-weight: 600; font-family: 'IBM Plex Mono', monospace;
    }
    .chip-users    { background: rgba(91,158,255,.1);  color: var(--clr-blue);   border: 1px solid rgba(91,158,255,.2) }
    .chip-sessions { background: rgba(0,221,160,.1);   color: var(--clr-green);  border: 1px solid rgba(0,221,160,.2) }
    .chip-brand    { background: var(--bg4);            color: var(--tx3);         border: 1px solid var(--border) }
    .theme-btn {
      width: 32px; height: 32px; border-radius: 8px;
      border: 1px solid var(--border2);
      background: var(--bg3);
      color: var(--tx2); cursor: pointer;
      display: flex; align-items: center; justify-content: center;
      transition: all .15s;
    }
    .theme-btn:hover { background: var(--bg4); color: var(--tx) }
    .logout-btn {
      display: flex; align-items: center; gap: 6px;
      font-size: 11px; font-weight: 600;
      color: var(--tx3); text-decoration: none;
      padding: 6px 10px; border-radius: 7px;
      border: 1px solid var(--border);
      background: var(--bg3);
      transition: all .15s;
      font-family: 'Syne', sans-serif;
    }
    .logout-btn:hover { color: var(--clr-red); border-color: rgba(255,85,102,.3) }
    .ac { flex: 1; overflow-y: auto; padding: 20px }

    /* ── CARDS ──────────────────────────────────────────────────── */
    .card {
      background: var(--bg2);
      border: 1px solid var(--border);
      border-radius: 12px;
      overflow: hidden;
    }
    .card-head {
      display: flex; align-items: center; justify-content: space-between;
      padding: 11px 14px;
      border-bottom: 1px solid var(--border);
      background: var(--bg3);
    }
    .card-title { font-size: 11px; font-weight: 700; text-transform: uppercase; letter-spacing: .8px; color: var(--tx2) }
    .card-meta  { font-size: 10px; color: var(--tx3); font-family: 'IBM Plex Mono', monospace }
    .card-body  { padding: 14px }

    /* ── STAT CARDS ─────────────────────────────────────────────── */
    .sg { display: grid; grid-template-columns: repeat(4, 1fr); gap: 10px; margin-bottom: 16px }
    .sc {
      background: var(--bg2); border: 1px solid var(--border);
      border-radius: 12px; padding: 14px 16px;
      display: flex; align-items: center; gap: 12px;
      transition: all .15s; cursor: default;
    }
    .sc:hover { border-color: var(--border2); transform: translateY(-1px); box-shadow: var(--shadow) }
    .sc-ic {
      width: 36px; height: 36px; border-radius: 9px;
      display: flex; align-items: center; justify-content: center;
      flex-shrink: 0;
    }
    .sc-blue   .sc-ic { background: rgba(91,158,255,.12); color: var(--clr-blue) }
    .sc-green  .sc-ic { background: rgba(0,221,160,.12);  color: var(--clr-green) }
    .sc-red    .sc-ic { background: rgba(255,85,102,.12); color: var(--clr-red) }
    .sc-amber  .sc-ic { background: rgba(255,187,0,.12);  color: var(--clr-amber) }
    .sc-purple .sc-ic { background: rgba(167,139,250,.12);color: var(--clr-purple) }
    .sc-v { font-size: 22px; font-weight: 800; line-height: 1; font-family: 'IBM Plex Mono', monospace }
    .sc-l { font-size: 10px; color: var(--tx3); margin-top: 3px; font-weight: 600; text-transform: uppercase; letter-spacing: .5px }
    .sc-click { cursor: pointer !important }
    .sc-click:hover { transform: translateY(-2px) !important; border-color: var(--accent) !important; box-shadow: 0 4px 16px rgba(0,0,0,.2) }
    .sc-arr { margin-left: auto; font-size: 13px; color: var(--accent); opacity: 0; transition: opacity .15s }
    .sc-click:hover .sc-arr { opacity: 1 }

    /* ── DASHBOARD GRID ─────────────────────────────────────────── */
    .dash-grid { display: grid; grid-template-columns: 1.2fr 1fr 1fr; gap: 12px }
    .storage-row {
      display: grid; grid-template-columns: 100px 1fr 80px;
      gap: 10px; align-items: center; margin-bottom: 12px;
      font-size: 11px;
    }
    .storage-label { color: var(--tx2) }
    .storage-bar-track { height: 4px; background: var(--bg4); border-radius: 2px; overflow: hidden }
    .storage-bar-fill { height: 100%; border-radius: 2px; transition: width .6s cubic-bezier(.4,0,.2,1) }
    .storage-bar-fill.blue   { background: var(--clr-blue) }
    .storage-bar-fill.green  { background: var(--clr-green) }
    .storage-bar-fill.red    { background: var(--clr-red) }
    .storage-val { text-align: right; font-weight: 600; font-size: 11px; font-family: 'IBM Plex Mono', monospace }
    .divider { border: none; border-top: 1px solid var(--border); margin: 12px 0 }
    .data-plane-title { font-size: 9px; font-weight: 700; color: var(--tx3); text-transform: uppercase; letter-spacing: 1px; margin-bottom: 8px }
    .kv-row {
      display: flex; justify-content: space-between; align-items: center;
      padding: 6px 14px; font-size: 12px;
      border-bottom: 1px solid var(--border);
    }
    .kv-row:last-child { border-bottom: none }
    .kv-row span { color: var(--tx2) }
    .kv-row strong { font-family: 'IBM Plex Mono', monospace; font-size: 11px }
    .svc-row {
      display: flex; align-items: center; gap: 8px;
      padding: 7px 0; font-size: 12px;
      border-bottom: 1px solid var(--border);
    }
    .svc-row:last-child { border-bottom: none }
    .svc-row > span:nth-child(2) { flex: 1; color: var(--tx2) }
    .svc-dot { width: 7px; height: 7px; border-radius: 50%; flex-shrink: 0 }
    .svc-dot.green { background: var(--clr-green); box-shadow: 0 0 6px rgba(0,221,160,.5) }
    .svc-dot.blue  { background: var(--clr-blue);  box-shadow: 0 0 6px rgba(91,158,255,.4) }
    .svc-badge { font-size: 10px; padding: 2px 8px; border-radius: 10px; font-weight: 700 }
    .svc-badge.online { background: rgba(0,221,160,.1); color: var(--clr-green) }
    .svc-tokens { display: flex; align-items: center; gap: 8px; padding: 7px 0; font-size: 12px; color: var(--tx2) }
    .svc-tokens > span:nth-child(2) { flex: 1 }
    .token-badge { background: rgba(91,158,255,.1); color: var(--clr-blue); font-size: 10px; padding: 2px 8px; border-radius: 10px; font-weight: 700 }
    .quick-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 7px }
    .quick-btn {
      display: flex; align-items: center; gap: 7px;
      background: var(--bg3); border: 1px solid var(--border);
      border-radius: 8px; padding: 8px 10px;
      color: var(--tx2); cursor: pointer;
      font-size: 11px; font-weight: 600;
      font-family: 'Syne', sans-serif;
      transition: all .15s;
    }
    .quick-btn:hover { background: var(--bg4); color: var(--tx); border-color: var(--border2) }
    .audit-row {
      display: flex; align-items: center; gap: 10px;
      padding: 9px 14px; font-size: 11px;
      border-bottom: 1px solid var(--border);
      transition: background .1s;
    }
    .audit-row:last-child { border-bottom: none }
    .audit-row:hover { background: var(--bg3) }
    .audit-dot { width: 6px; height: 6px; border-radius: 50%; background: var(--clr-blue); flex-shrink: 0 }
    .audit-info { flex: 1; display: flex; gap: 6px; align-items: center }
    .audit-action { font-weight: 600; color: var(--tx) }
    .audit-target { color: var(--tx3); font-family: 'IBM Plex Mono', monospace; font-size: 10px }
    .audit-time { color: var(--tx3); font-size: 10px; font-family: 'IBM Plex Mono', monospace; white-space: nowrap }

    /* ── TOOLBAR ────────────────────────────────────────────────── */
    .toolbar { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; margin-bottom: 12px }
    .search-box {
      display: flex; align-items: center; gap: 8px;
      background: var(--bg2); border: 1px solid var(--border);
      border-radius: 8px; padding: 7px 11px;
      flex: 1; min-width: 160px; color: var(--tx2);
      transition: border-color .15s;
    }
    .search-box:focus-within { border-color: var(--clr-blue) }
    .search-input {
      background: none; border: none; outline: none;
      color: var(--tx); font-size: 12px; width: 100%;
      font-family: 'Syne', sans-serif;
    }
    .search-input::placeholder { color: var(--tx3) }
    .filter-pills { display: flex; gap: 5px; flex-wrap: wrap }
    .pill {
      background: var(--bg3); border: 1px solid var(--border);
      border-radius: 20px; padding: 4px 11px;
      color: var(--tx2); cursor: pointer;
      font-size: 11px; font-weight: 600;
      font-family: 'Syne', sans-serif;
      transition: all .15s;
    }
    .pill:hover { border-color: var(--border2); color: var(--tx) }
    .pill.active { background: rgba(91,158,255,.1); border-color: rgba(91,158,255,.3); color: var(--clr-blue) }
    .theme-light .pill.active { background: rgba(37,99,235,.08); border-color: rgba(37,99,235,.25) }
    .select-box {
      background: var(--bg2); border: 1px solid var(--border);
      border-radius: 8px; padding: 7px 10px;
      color: var(--tx); font-size: 12px;
      font-family: 'Syne', sans-serif;
      cursor: pointer; outline: none;
    }

    /* ── TABLES ─────────────────────────────────────────────────── */
    .table-wrap { background: var(--bg2); border: 1px solid var(--border); border-radius: 12px; overflow: hidden }
    .data-table { width: 100%; border-collapse: collapse }
    .data-table thead th {
      background: var(--bg3); padding: 9px 12px;
      font-size: 10px; font-weight: 700; color: var(--tx3);
      text-align: left; letter-spacing: .7px; text-transform: uppercase;
      border-bottom: 1px solid var(--border);
    }
    .data-table tbody tr { border-bottom: 1px solid var(--border); transition: background .1s }
    .data-table tbody tr:last-child { border-bottom: none }
    .data-row:hover { background: var(--bg3) }
    .data-table td { padding: 9px 12px; font-size: 12px }
    .empty-row { text-align: center; color: var(--tx3); padding: 36px; font-size: 13px }
    .cell-sm  { font-size: 11px; color: var(--tx2) }
    .cell-num { text-align: right; font-weight: 600; font-family: 'IBM Plex Mono', monospace }

    /* ── BADGES ─────────────────────────────────────────────────── */
    .badge { font-size: 9px; font-weight: 700; padding: 2px 7px; border-radius: 10px }
    .badge.green  { background: rgba(0,221,160,.1);  color: var(--clr-green);  border: 1px solid rgba(0,221,160,.2) }
    .badge.red    { background: rgba(255,85,102,.1); color: var(--clr-red);    border: 1px solid rgba(255,85,102,.2) }
    .badge.blue   { background: rgba(91,158,255,.1); color: var(--clr-blue);   border: 1px solid rgba(91,158,255,.2) }
    .badge.amber  { background: rgba(255,187,0,.1);  color: var(--clr-amber);  border: 1px solid rgba(255,187,0,.2) }
    .badge.purple { background: rgba(167,139,250,.1);color: var(--clr-purple); border: 1px solid rgba(167,139,250,.2) }
    .badge.gray   { background: var(--bg4);           color: var(--tx3);         border: 1px solid var(--border) }
    .badge-row { display: flex; gap: 4px; flex-wrap: wrap }

    /* ── USER CELLS ─────────────────────────────────────────────── */
    .user-cell { display: flex; align-items: center; gap: 9px }
    .user-avatar {
      width: 28px; height: 28px; border-radius: 50%;
      background: linear-gradient(135deg, var(--clr-blue), var(--clr-purple));
      display: flex; align-items: center; justify-content: center;
      font-size: 11px; font-weight: 700; color: #fff; flex-shrink: 0;
    }
    .user-name { font-size: 12px; font-weight: 600 }
    .user-id { color: var(--tx3); font-size: 10px }
    .action-btns { display: flex; gap: 5px }
    .btn-sm {
      background: var(--bg4); border: 1px solid var(--border);
      border-radius: 6px; padding: 4px 10px;
      color: var(--tx2); cursor: pointer; font-size: 10px; font-weight: 600;
      font-family: 'Syne', sans-serif; transition: all .15s;
    }
    .btn-sm:hover { background: var(--bg5); color: var(--tx) }
    .btn-sm.accent { background: rgba(91,158,255,.1); color: var(--clr-blue); border-color: rgba(91,158,255,.25) }
    .btn-sm.accent:hover { background: rgba(91,158,255,.18) }
    .back-btn {
      display: inline-flex; align-items: center; gap: 6px;
      background: none; border: none; color: var(--tx2);
      cursor: pointer; font-size: 12px; font-weight: 600;
      font-family: 'Syne', sans-serif; margin-bottom: 16px; padding: 0;
      transition: color .15s;
    }
    .back-btn:hover { color: var(--tx) }

    /* ── PROFILE CARD ───────────────────────────────────────────── */
    .profile-card {
      background: var(--bg2); border: 1px solid var(--border);
      border-radius: 14px; padding: 20px;
      display: flex; align-items: flex-start; gap: 16px;
      margin-bottom: 16px;
    }
    .profile-avatar-lg {
      width: 52px; height: 52px; border-radius: 50%;
      background: linear-gradient(135deg, var(--clr-blue), var(--clr-purple));
      display: flex; align-items: center; justify-content: center;
      font-size: 20px; font-weight: 800; color: #fff; flex-shrink: 0;
    }
    .profile-info { flex: 1 }
    .profile-name  { font-size: 17px; font-weight: 800; margin-bottom: 3px }
    .profile-email { font-size: 12px; color: var(--tx2); margin-bottom: 2px }
    .profile-id    { font-size: 10px; color: var(--tx3); margin-bottom: 8px; font-family: 'IBM Plex Mono', monospace }
    .profile-actions { display: flex; flex-direction: column; gap: 6px }
    .action-btn {
      padding: 6px 13px; border-radius: 7px; border: none;
      cursor: pointer; font-size: 11px; font-weight: 700;
      font-family: 'Syne', sans-serif; transition: all .15s; white-space: nowrap;
    }
    .action-btn.purple { background: rgba(167,139,250,.12); color: var(--clr-purple); border: 1px solid rgba(167,139,250,.25) }
    .action-btn.red    { background: rgba(255,85,102,.12);  color: var(--clr-red);    border: 1px solid rgba(255,85,102,.25) }
    .action-btn.green  { background: rgba(0,221,160,.12);   color: var(--clr-green);  border: 1px solid rgba(0,221,160,.25) }
    .action-btn.amber  { background: rgba(255,187,0,.12);   color: var(--clr-amber);  border: 1px solid rgba(255,187,0,.25) }
    .action-btn.gray   { background: var(--bg4);             color: var(--tx2);         border: 1px solid var(--border) }
    .action-btn.orange { background: rgba(255,140,66,.12);  color: var(--clr-orange); border: 1px solid rgba(255,140,66,.25) }
    .action-btn:hover  { opacity: .85; transform: translateY(-1px) }

    /* ── STAT STRIP ─────────────────────────────────────────────── */
    .stat-strip { display: grid; grid-template-columns: repeat(6, 1fr); gap: 10px; margin-bottom: 14px }
    .strip-stat { background: var(--bg2); border: 1px solid var(--border); border-radius: 10px; padding: 12px; text-align: center }
    .strip-stat.green .strip-val { color: var(--clr-green) }
    .strip-val { font-size: 16px; font-weight: 800; margin-bottom: 3px }
    .strip-lbl { font-size: 9px; font-weight: 700; color: var(--tx3); text-transform: uppercase; letter-spacing: .5px }

    /* ── THREE COLUMN ───────────────────────────────────────────── */
    .three-col { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 12px }
    .scroll-list { max-height: 280px; overflow-y: auto }
    .list-row {
      display: flex; align-items: center; gap: 9px;
      padding: 8px 14px; border-bottom: 1px solid var(--border);
      font-size: 12px; transition: background .1s;
    }
    .list-row:last-child { border-bottom: none }
    .list-row:hover { background: var(--bg3) }
    .file-icon { font-size: 14px }
    .row-name { font-size: 12px; font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis }
    .row-meta { font-size: 10px; color: var(--tx3) }
    .did-block {
      background: var(--bg3); padding: 9px 14px;
      font-size: 10px; color: var(--clr-blue);
      font-family: 'IBM Plex Mono', monospace;
      word-break: break-all; border-bottom: 1px solid var(--border);
    }
    .empty-state { text-align: center; color: var(--tx3); padding: 40px; font-size: 13px }
    .empty-page  { display: flex; align-items: center; justify-content: center; height: 200px; color: var(--tx3); font-size: 14px }

    /* ── PERMISSIONS ────────────────────────────────────────────── */
    .perm-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 14px }
    .perm-row {
      display: flex; justify-content: space-between; align-items: center;
      padding: 12px 14px; border-bottom: 1px solid var(--border);
    }
    .perm-row:last-child { border-bottom: none }
    .perm-name { font-size: 13px; font-weight: 600; margin-bottom: 2px }
    .perm-desc { font-size: 10px; color: var(--tx3) }
    .perm-ctrl { display: flex; align-items: center; gap: 7px }
    .perm-badge {
      font-size: 9px; padding: 3px 8px; border-radius: 10px;
      font-weight: 700; letter-spacing: .3px; white-space: nowrap;
    }
    .perm-badge.on  { background: rgba(0,221,160,.12); color: var(--clr-green); border: 1px solid rgba(0,221,160,.25) }
    .perm-badge.off { background: var(--bg4); color: var(--tx3); border: 1px solid var(--border) }
    .perm-btn {
      font-size: 10px; padding: 4px 10px; border-radius: 6px;
      border: none; cursor: pointer; font-weight: 700;
      font-family: 'Syne', sans-serif; transition: all .15s; white-space: nowrap;
    }
    .perm-btn.red    { background: rgba(255,85,102,.12); color: var(--clr-red);    border: 1px solid rgba(255,85,102,.25) }
    .perm-btn.green  { background: rgba(0,221,160,.12);  color: var(--clr-green);  border: 1px solid rgba(0,221,160,.25) }
    .perm-btn.amber  { background: rgba(255,187,0,.12);  color: var(--clr-amber);  border: 1px solid rgba(255,187,0,.25) }
    .perm-btn.purple { background: rgba(167,139,250,.12);color: var(--clr-purple); border: 1px solid rgba(167,139,250,.25) }
    .perm-btn.gray   { background: var(--bg4);            color: var(--tx2);         border: 1px solid var(--border) }
    .perm-btn:hover  { opacity: .8; transform: translateY(-1px) }

    /* ── VAULT ──────────────────────────────────────────────────── */
    .vault-layout { display: grid; grid-template-columns: 190px 1fr; gap: 14px }
    .vault-sidebar { background: var(--bg2); border: 1px solid var(--border); border-radius: 12px; overflow: hidden }
    .vault-all-btn {
      display: block; width: 100%; text-align: left;
      padding: 9px 13px; cursor: pointer;
      border: none; border-bottom: 1px solid var(--border);
      background: none; font-size: 12px; font-weight: 600;
      font-family: 'Syne', sans-serif; color: var(--clr-blue);
      transition: background .1s;
    }
    .vault-all-btn:hover { background: var(--bg3) }
    .vault-ns { padding: 9px 13px; border-bottom: 1px solid var(--border) }
    .ref-badge {
      background: var(--bg4); color: var(--tx3);
      font-size: 10px; padding: 2px 7px; border-radius: 10px;
      font-weight: 700; font-family: 'IBM Plex Mono', monospace;
    }
    .ref-badge.dup { background: rgba(255,187,0,.1); color: var(--clr-amber); border: 1px solid rgba(255,187,0,.2) }

    /* ── SQL ─────────────────────────────────────────────────────── */
    .sql-layout { display: grid; grid-template-columns: 260px 1fr; gap: 14px; height: calc(100vh - 92px) }
    .sql-left  { display: flex; flex-direction: column; gap: 12px; overflow-y: auto }
    .sql-right { overflow-y: auto }
    .preset-btn {
      display: block; width: 100%; text-align: left;
      background: none; border: none; border-bottom: 1px solid var(--border);
      padding: 9px 14px; color: var(--tx2); cursor: pointer;
      font-size: 11px; font-weight: 600;
      font-family: 'Syne', sans-serif; transition: all .15s;
    }
    .preset-btn:last-child { border-bottom: none }
    .preset-btn:hover { background: var(--bg3); color: var(--tx) }
    .sql-editor {
      width: 100%; background: var(--bg3); border: none;
      border-top: 1px solid var(--border);
      padding: 11px 14px; color: var(--tx);
      font-family: 'IBM Plex Mono', monospace; font-size: 12px;
      line-height: 1.6; resize: vertical; outline: none; min-height: 140px;
    }
    .sql-editor:focus { border-top-color: var(--clr-blue) }
    .sql-toolbar {
      display: flex; align-items: center; gap: 9px;
      padding: 9px 14px; background: var(--bg3);
      border-top: 1px solid var(--border);
    }
    .btn-run {
      background: var(--clr-blue); color: #fff; border: none;
      border-radius: 7px; padding: 7px 14px;
      font-size: 12px; font-weight: 700; cursor: pointer;
      font-family: 'Syne', sans-serif; transition: all .15s;
    }
    .btn-run:hover { opacity: .87 }
    .btn-clear {
      background: var(--bg4); border: 1px solid var(--border);
      border-radius: 7px; padding: 7px 12px;
      color: var(--tx2); cursor: pointer;
      font-size: 12px; font-family: 'Syne', sans-serif; transition: all .15s;
    }
    .btn-clear:hover { background: var(--bg5); color: var(--tx) }
    .sql-hint { font-size: 10px; color: var(--tx3); margin-left: auto; font-family: 'IBM Plex Mono', monospace }
    .error-block { background: rgba(255,85,102,.07); border: 1px solid rgba(255,85,102,.2); border-radius: 10px; padding: 14px; margin-bottom: 12px }
    .error-title { font-size: 12px; font-weight: 700; color: var(--clr-red); margin-bottom: 7px }
    .error-body { font-size: 11px; color: var(--clr-red); font-family: 'IBM Plex Mono', monospace; white-space: pre-wrap }
    .sql-scroll { overflow-x: auto; max-height: 60vh }
    .sql-cell { font-size: 11px; font-family: 'IBM Plex Mono', monospace; max-width: 220px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap }
    .sql-placeholder { text-align: center; color: var(--tx3); padding: 60px; font-size: 13px }

    /* ── S3 ─────────────────────────────────────────────────────── */
    .s3-root-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 16px; max-width: 600px }
    .s3-card {
      background: var(--bg2); border: 1px solid var(--border2);
      border-radius: 14px; padding: 24px; cursor: pointer;
      text-align: left; transition: all .2s;
      display: flex; flex-direction: column; gap: 6px;
      position: relative; overflow: hidden;
    }
    .s3-card::before { content:''; position: absolute; top: 0; left: 0; right: 0; height: 2px; background: linear-gradient(90deg, var(--clr-blue), var(--clr-purple)) }
    .s3-card:hover { border-color: rgba(91,158,255,.3); transform: translateY(-2px); box-shadow: var(--shadow-lg) }
    .s3-card-icon { font-size: 28px; color: var(--clr-blue); margin-bottom: 4px }
    .s3-card-name { font-size: 16px; font-weight: 700; color: var(--tx) }
    .s3-card-meta { font-size: 12px; color: var(--tx2) }
    .s3-card-cta  { font-size: 11px; color: var(--clr-blue); font-weight: 700; margin-top: 4px }
    .s3-breadcrumb { display: flex; align-items: center; gap: 8px; margin-bottom: 16px; font-size: 12px; flex-wrap: wrap }
    .breadcrumb-sep  { color: var(--tx3) }
    .breadcrumb-path { color: var(--clr-blue); font-family: 'IBM Plex Mono', monospace }
    .s3-folder-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(170px, 1fr)); gap: 7px }
    .s3-folder {
      background: var(--bg2); border: 1px solid var(--border);
      border-radius: 8px; padding: 10px 12px; cursor: pointer;
      display: flex; align-items: center; gap: 8px;
      font-size: 12px; color: var(--tx);
      font-family: 'Syne', sans-serif; transition: all .15s;
    }
    .s3-folder:hover { background: var(--bg3); border-color: var(--border2) }
    .section-label { font-size: 10px; font-weight: 700; color: var(--tx3); text-transform: uppercase; letter-spacing: .8px; margin-bottom: 8px }

    /* ── MODALS / OVERLAY ───────────────────────────────────────── */
    .overlay {
      position: fixed; inset: 0;
      background: rgba(0,0,0,.65);
      z-index: 1000;
      display: flex; align-items: center; justify-content: center;
      backdrop-filter: blur(6px);
    }
    .modal {
      background: var(--bg2); border: 1px solid var(--border2);
      border-radius: 16px; padding: 28px; width: 350px;
      text-align: center; box-shadow: var(--shadow-lg);
      animation: modal-in .2s ease;
    }
    @keyframes modal-in { from { transform: scale(.94) translateY(10px); opacity: 0 } to { transform: scale(1) translateY(0); opacity: 1 } }
    .modal-icon  { font-size: 28px; margin-bottom: 12px }
    .modal-title { font-size: 16px; font-weight: 800; margin-bottom: 8px }
    .modal-body  { font-size: 13px; color: var(--tx2); margin-bottom: 22px; line-height: 1.5 }
    .modal-btns  { display: flex; gap: 10px; justify-content: center }
    .btn-cancel {
      background: var(--bg4); border: 1px solid var(--border);
      border-radius: 7px; padding: 8px 18px;
      color: var(--tx2); cursor: pointer; font-size: 12px; font-weight: 700;
      font-family: 'Syne', sans-serif; transition: all .15s;
    }
    .btn-cancel:hover { background: var(--bg5); color: var(--tx) }
    .btn-danger {
      background: rgba(255,85,102,.15); border: 1px solid rgba(255,85,102,.3);
      border-radius: 7px; padding: 8px 18px;
      color: var(--clr-red); cursor: pointer; font-size: 12px; font-weight: 700;
      font-family: 'Syne', sans-serif; transition: all .15s;
    }
    .btn-danger:hover { background: rgba(255,85,102,.25) }

    /* ── TOAST ──────────────────────────────────────────────────── */
    .toast {
      position: fixed; top: 16px; right: 16px; z-index: 2000;
      background: var(--bg2); border: 1px solid var(--border2);
      border-radius: 10px; padding: 11px 16px;
      display: flex; align-items: center;
      font-size: 12px; font-weight: 600;
      box-shadow: var(--shadow-lg);
      animation: toast-in .3s cubic-bezier(.16,1,.3,1);
    }
    .toast-success { border-color: rgba(0,221,160,.3); color: var(--clr-green) }
    .toast-error   { border-color: rgba(255,85,102,.3); color: var(--clr-red) }
    @keyframes toast-in { from { transform: translateX(50px); opacity: 0 } to { transform: translateX(0); opacity: 1 } }

    /* ── PAGINATION ─────────────────────────────────────────────── */
    .pagination { display: flex; align-items: center; gap: 10px; padding: 14px; justify-content: center }
    .page-btn {
      background: var(--bg3); border: 1px solid var(--border);
      border-radius: 7px; padding: 5px 14px;
      color: var(--tx2); cursor: pointer; font-size: 12px; font-weight: 600;
      font-family: 'Syne', sans-serif; transition: all .15s;
    }
    .page-btn:hover { background: var(--bg4); color: var(--tx) }
    .page-info { font-size: 11px; color: var(--tx3); font-family: 'IBM Plex Mono', monospace }

    /* ── ANALYTICS ──────────────────────────────────────────────── */
    .chart-r3 { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 12px }
    .chart-r3 .span2 { grid-column: span 2 }
    .chart-card { background: var(--card-bg); border: 1px solid var(--border); border-radius: 10px; padding: 14px }
    .chart-title { font-size: 10px; font-weight: 700; color: var(--muted); text-transform: uppercase; letter-spacing: .6px; margin-bottom: 10px }
    .ct-sub { font-size: 9px; font-weight: 400; color: var(--muted2); text-transform: none; letter-spacing: 0; margin-left: 4px }
    .chart-h200 { height: 200px; position: relative }
    .chart-h180 { height: 180px; position: relative }
    .chart-empty { height: 150px; display: flex; align-items: center; justify-content: center; color: var(--muted2); font-size: 11px }
    .gauge-wrap { position: relative; height: 150px; display: flex; align-items: center; justify-content: center }
    .gauge-label { position: absolute; bottom: 16px; text-align: center; font-size: 20px; font-weight: 800; color: var(--text); line-height: 1.2 }
    .gauge-label span { font-size: 10px; font-weight: 500; color: var(--muted) }
    .a-strip { display: grid; grid-template-columns: repeat(6, 1fr); gap: 8px; margin-bottom: 14px }
    .a-stat { background: var(--card-bg); border: 1px solid var(--border); border-radius: 8px; padding: 12px; text-align: center }
    .a-val { font-size: 17px; font-weight: 800; line-height: 1; margin-bottom: 3px }
    .a-lbl { font-size: 9px; font-weight: 600; color: var(--muted); text-transform: uppercase; letter-spacing: .4px }
    .dup-badge { background: rgba(245,158,11,.1); color: #e3b341; border: 1px solid rgba(245,158,11,.2); border-radius: 10px; padding: 2px 6px; font-size: 9px; font-weight: 700 }
    .ok { color: #3fb950 }
    .ta-r { text-align: right }
    </style>
    """
  end
end
