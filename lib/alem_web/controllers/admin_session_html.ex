defmodule AlemWeb.AdminSessionHTML do
  use AlemWeb, :html

  def new(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8"/>
      <meta name="viewport" content="width=device-width, initial-scale=1"/>
      <title>PRZMA Admin Login</title>
      <link rel="preconnect" href="https://fonts.googleapis.com"/>
      <link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;600&family=Syne:wght@600;700;800&display=swap" rel="stylesheet"/>
      <style>
        *, *::before, *::after { margin: 0; padding: 0; box-sizing: border-box }

        :root {
          --bg: #0c0c10; --bg2: #13131a; --bg3: #1a1a24; --bg4: #21212e;
          --border: rgba(255,255,255,.07); --border2: rgba(255,255,255,.13);
          --tx: #e2e2ee; --tx2: #8888a8; --tx3: #4a4a68;
          --blue: #5b9eff; --green: #00dda0; --red: #ff5566; --purple: #a78bfa;
        }

        body {
          background: var(--bg); color: var(--tx);
          font-family: 'Syne', -apple-system, sans-serif;
          display: flex; align-items: center; justify-content: center;
          min-height: 100vh;
          background-image:
            radial-gradient(ellipse 60% 50% at 20% 20%, rgba(91,158,255,.07) 0%, transparent 60%),
            radial-gradient(ellipse 50% 40% at 80% 80%, rgba(167,139,250,.06) 0%, transparent 60%);
        }

        .login-wrap {
          width: 380px;
          animation: fade-up .5s cubic-bezier(.16,1,.3,1);
        }
        @keyframes fade-up {
          from { opacity: 0; transform: translateY(20px) }
          to   { opacity: 1; transform: translateY(0) }
        }

        /* Grid lines decoration */
        .login-wrap::before {
          content: '';
          position: fixed; inset: 0; z-index: -1;
          background-image:
            linear-gradient(var(--border) 1px, transparent 1px),
            linear-gradient(90deg, var(--border) 1px, transparent 1px);
          background-size: 60px 60px;
          mask-image: radial-gradient(ellipse 70% 70% at 50% 50%, black 20%, transparent 70%);
        }

        .brand {
          display: flex; align-items: center; gap: 12px;
          justify-content: center; margin-bottom: 36px;
        }
        .brand-mark {
          width: 38px; height: 38px;
          background: linear-gradient(135deg, var(--blue), var(--purple));
          border-radius: 10px;
          display: flex; align-items: center; justify-content: center;
          box-shadow: 0 0 28px rgba(91,158,255,.3);
        }
        .brand-name {
          font-size: 20px; font-weight: 800; letter-spacing: 4px;
          background: linear-gradient(135deg, var(--blue), var(--purple));
          -webkit-background-clip: text; -webkit-text-fill-color: transparent;
          background-clip: text;
        }

        .card {
          background: var(--bg2); border: 1px solid var(--border2);
          border-radius: 16px; padding: 36px;
          box-shadow: 0 24px 80px rgba(0,0,0,.6);
          position: relative; overflow: hidden;
        }
        .card::before {
          content: ''; position: absolute; top: 0; left: 0; right: 0; height: 1px;
          background: linear-gradient(90deg, transparent, rgba(91,158,255,.4), transparent);
        }

        .card-title { font-size: 20px; font-weight: 800; margin-bottom: 5px; text-align: center }
        .card-sub   { font-size: 12px; color: var(--tx2); text-align: center; margin-bottom: 28px; font-weight: 600 }

        .alert {
          border-radius: 8px; padding: 11px 14px;
          font-size: 12px; font-weight: 600; margin-bottom: 18px;
          display: flex; align-items: center; gap: 8px;
        }
        .alert-error { background: rgba(255,85,102,.1); border: 1px solid rgba(255,85,102,.25); color: var(--red) }
        .alert-info  { background: rgba(0,221,160,.1);  border: 1px solid rgba(0,221,160,.25);  color: var(--green) }

        .field { margin-bottom: 18px }
        label {
          display: block; font-size: 10px; font-weight: 700;
          color: var(--tx3); text-transform: uppercase;
          letter-spacing: 1px; margin-bottom: 7px;
        }
        .input-wrap { position: relative }
        input[type=email], input[type=password], input[type=text] {
          width: 100%; background: var(--bg3);
          border: 1px solid var(--border2);
          border-radius: 9px; padding: 11px 14px;
          color: var(--tx); font-size: 13px;
          font-family: 'IBM Plex Mono', monospace;
          outline: none; transition: border-color .2s, box-shadow .2s;
        }
        input:focus {
          border-color: var(--blue);
          box-shadow: 0 0 0 3px rgba(91,158,255,.12);
        }
        input::placeholder { color: var(--tx3) }

        .toggle-pw {
          position: absolute; right: 12px; top: 50%; transform: translateY(-50%);
          background: none; border: none; cursor: pointer;
          color: var(--tx3); padding: 4px; transition: color .15s;
          display: flex; align-items: center;
        }
        .toggle-pw:hover { color: var(--tx2) }

        .submit-btn {
          width: 100%; background: linear-gradient(135deg, var(--blue), var(--purple));
          color: #fff; border: none; border-radius: 9px;
          padding: 13px; font-size: 13px; font-weight: 800;
          font-family: 'Syne', sans-serif;
          cursor: pointer; margin-top: 6px;
          transition: all .2s;
          letter-spacing: .5px;
          position: relative; overflow: hidden;
        }
        .submit-btn::before {
          content: ''; position: absolute; inset: 0;
          background: rgba(255,255,255,0);
          transition: background .2s;
        }
        .submit-btn:hover::before { background: rgba(255,255,255,.08) }
        .submit-btn:active { transform: scale(.98) }

        .footer-note {
          text-align: center; margin-top: 22px;
          font-size: 10px; color: var(--tx3); letter-spacing: .5px;
        }
        .footer-note span { color: var(--tx2); font-weight: 700 }
      </style>
    </head>
    <body>
      <div class="login-wrap">
        <div class="brand">
          <div class="brand-mark">
            <svg width="18" height="18" viewBox="0 0 18 18" fill="none">
              <path d="M9 1.5L16.5 5.25V12.75L9 16.5L1.5 12.75V5.25L9 1.5Z" stroke="white" stroke-width="1.5" fill="none"/>
              <circle cx="9" cy="9" r="2.5" fill="white"/>
            </svg>
          </div>
          <span class="brand-name">PRZMA</span>
        </div>

        <div class="card">
          <div class="card-title">Admin Login</div>
          <div class="card-sub">Sign in to Control Plane</div>

          <%= if msg = Phoenix.Flash.get(@conn.assigns.flash, :error) do %>
            <div class="alert alert-error">
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"/><line x1="15" y1="9" x2="9" y2="15"/><line x1="9" y1="9" x2="15" y2="15"/></svg>
              <%= msg %>
            </div>
          <% end %>
          <%= if msg = Phoenix.Flash.get(@conn.assigns.flash, :info) do %>
            <div class="alert alert-info">
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"/><line x1="12" y1="16" x2="12" y2="12"/><line x1="12" y1="8" x2="12.01" y2="8"/></svg>
              <%= msg %>
            </div>
          <% end %>

          <form method="post" action="/admin/login" id="login-form">
            <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()}/>

            <div class="field">
              <label for="email">Email Address</label>
              <input type="email" id="email" name="email" placeholder="admin@example.com" autocomplete="email"/>
            </div>

            <div class="field">
              <label for="password">Password</label>
              <div class="input-wrap">
                <input type="password" id="password" name="password" placeholder="••••••••" autocomplete="current-password"/>
                <button type="button" class="toggle-pw" onclick="togglePw()" title="Toggle password">
                  <svg id="eye-icon" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/></svg>
                </button>
              </div>
            </div>

            <button type="submit" class="submit-btn">Sign In →</button>
          </form>
        </div>

        <div class="footer-note">
          PRZMA Control Plane &nbsp;·&nbsp; <span>Secure Access Only</span>
        </div>
      </div>

      <script>
        function togglePw() {
          const inp = document.getElementById('password');
          const ico = document.getElementById('eye-icon');
          if (inp.type === 'password') {
            inp.type = 'text';
            ico.innerHTML = '<path d="M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94"/><path d="M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19"/><line x1="1" y1="1" x2="23" y2="23"/>';
          } else {
            inp.type = 'password';
            ico.innerHTML = '<path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/>';
          }
        }
      </script>
    </body>
    </html>
    """
  end
end
