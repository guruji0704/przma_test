defmodule AlemWeb.AdminSessionController do
  use AlemWeb, :controller
  alias Alem.Pleroma.User
  alias Alem.Repo

  # Track login attempts per user+IP (in-memory, resets on restart)
  # For production use a proper rate limiter like Hammer
  @max_attempts 5
  @lockout_seconds 300

  def new(conn, _params) do
    flash_error = Phoenix.Flash.get(conn.assigns.flash, :error)
    flash_info  = Phoenix.Flash.get(conn.assigns.flash, :info)
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, login_page_html(flash_error, flash_info, get_csrf_token(conn)))
  end

  def create(conn, %{"email" => email, "password" => password} = params) do
    ip = get_client_ip(conn)
    email_trimmed = String.trim(email)

    # Rate limit by email + IP
    rate_limit_key = "#{email_trimmed}:#{ip}"

    if rate_limited?(rate_limit_key) do
      redirect_login_with_error(conn, "Too many attempts. Try again in 5 minutes.")
    else
      case Repo.get_by(User, email: email_trimmed) do
        %User{is_admin: true} = user ->
          if User.verify_password(user, password) do
            clear_attempts(rate_limit_key)
            remember_me = params["remember_me"] == "1"

            conn
            |> configure_session(renew: true)
            |> put_session(:admin_user_id, user.id)
            |> put_session(:admin_login_at, System.system_time(:second))
            |> put_session(:admin_ip, ip)
            |> put_session(:remember_me, remember_me)
            |> redirect(to: "/admin")
          else
            record_attempt(rate_limit_key)
            redirect_login_with_error(conn, "Invalid email or password.")
          end

        %User{is_admin: false} ->
          record_attempt(rate_limit_key)
          redirect_login_with_error(conn, "This account does not have admin access.")

        nil ->
          Pbkdf2.no_user_verify()
          record_attempt(rate_limit_key)
          redirect_login_with_error(conn, "Invalid email or password.")
      end
    end
  end

  def delete(conn, _params) do
    conn
    |> delete_session(:admin_user_id)
    |> delete_session(:admin_login_at)
    |> delete_session(:admin_ip)
    |> delete_session(:remember_me)
    |> redirect(to: "/admin/login")
  end

  # ── Rate limiting (simple ETS-based) ─────────────────────────────────────

  defp rate_limited?(key) do
    case :ets.whereis(:admin_login_attempts) do
      :undefined ->
        :ets.new(:admin_login_attempts, [:named_table, :public, :set])
        false

      _ ->
        case :ets.lookup(:admin_login_attempts, key) do
          [{^key, count, ts}] ->
            now = System.system_time(:second)
            if now - ts < @lockout_seconds && count >= @max_attempts, do: true, else: false

          _ ->
            false
        end
    end
  rescue
    _ -> false
  end

  defp record_attempt(key) do
    ensure_ets()
    now = System.system_time(:second)

    case :ets.lookup(:admin_login_attempts, key) do
      [{^key, count, _ts}] -> :ets.insert(:admin_login_attempts, {key, count + 1, now})
      _ -> :ets.insert(:admin_login_attempts, {key, 1, now})
    end
  rescue
    _ -> :ok
  end

  defp clear_attempts(key) do
    ensure_ets()
    :ets.delete(:admin_login_attempts, key)
  rescue
    _ -> :ok
  end

  defp ensure_ets do
    if :ets.whereis(:admin_login_attempts) == :undefined do
      :ets.new(:admin_login_attempts, [:named_table, :public, :set])
    end
  rescue
    _ -> :ok
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp get_client_ip(conn) do
    conn
    |> Plug.Conn.get_req_header("x-forwarded-for")
    |> case do
      [ip | _] -> String.trim(ip)
      [] ->
        case conn.remote_ip do
          {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
          _ -> "unknown"
        end
    end
  end

  defp redirect_login_with_error(conn, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: "/admin/login")
  end

  defp get_csrf_token(conn) do
    conn
    |> Plug.Conn.fetch_session()
    |> Plug.CSRFProtection.get_csrf_token()
  rescue
    _ -> Plug.CSRFProtection.get_csrf_token()
  end

  defp login_page_html(flash_error, flash_info, csrf_token) do
    error_html =
      if flash_error do
        "<div class=\"err\">#{Phoenix.HTML.html_escape(flash_error) |> Phoenix.HTML.safe_to_string()}</div>"
      else
        ""
      end

    info_html =
      if flash_info do
        "<div class=\"inf\">#{Phoenix.HTML.html_escape(flash_info) |> Phoenix.HTML.safe_to_string()}</div>"
      else
        ""
      end

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8"/>
      <meta name="viewport" content="width=device-width, initial-scale=1"/>
      <meta http-equiv="X-UA-Compatible" content="IE=edge"/>
      <title>PRZMA Control Plane</title>
      <style>
        *{margin:0;padding:0;box-sizing:border-box}
        html{-webkit-font-smoothing:antialiased;-moz-osx-font-smoothing:grayscale}
        body{
          background:#080b12;
          color:#cdd9e5;
          font-family:-apple-system,BlinkMacSystemFont,'Segoe UI','Inter',sans-serif;
          display:flex;align-items:center;justify-content:center;min-height:100vh;
          padding:16px
        }
        .bg{position:fixed;inset:0;background:radial-gradient(ellipse at 20% 50%,rgba(88,166,255,.04) 0%,transparent 60%),radial-gradient(ellipse at 80% 20%,rgba(188,140,255,.03) 0%,transparent 60%)}
        .wrap{position:relative;z-index:1;width:100%;max-width:400px}
        .card{background:#0d1117;border:1px solid rgba(255,255,255,.08);border-radius:14px;padding:40px;box-shadow:0 20px 60px rgba(0,0,0,.5)}
        @media(max-width:480px){.card{padding:24px}}
        .logo{display:flex;align-items:center;justify-content:center;gap:10px;margin-bottom:8px}
        .logo-hex{font-size:26px;background:linear-gradient(135deg,#58a6ff,#bc8cff);-webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text}
        .logo-name{font-size:16px;font-weight:800;letter-spacing:3px;background:linear-gradient(135deg,#58a6ff,#bc8cff);-webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text}
        .logo-sub{text-align:center;font-size:10px;color:#484f58;letter-spacing:1.5px;text-transform:uppercase;margin-bottom:32px}
        h2{font-size:17px;font-weight:700;text-align:center;margin-bottom:4px;color:#e6edf3}
        .sub{font-size:12px;color:#8b949e;text-align:center;margin-bottom:24px}
        label{display:block;font-size:11px;font-weight:600;color:#8b949e;text-transform:uppercase;letter-spacing:.5px;margin-bottom:5px}
        .field{position:relative;margin-bottom:14px}
        input{width:100%;background:#161b22;border:1px solid rgba(255,255,255,.08);border-radius:7px;padding:10px 12px;color:#e6edf3;font-size:13px;outline:none;transition:border-color .15s,background-color .15s;font-family:inherit}
        input:focus{border-color:#58a6ff;background:#1c2128}
        input::placeholder{color:#484f58}
        input:disabled{opacity:.5;cursor:not-allowed}
        .pw-wrap{position:relative}
        .pw-wrap input{padding-right:40px}
        .eye{position:absolute;right:12px;top:50%;transform:translateY(-50%);background:none;border:none;cursor:pointer;color:#484f58;font-size:15px;padding:0;line-height:1;transition:color .15s}
        .eye:hover{color:#8b949e}
        .eye:active{color:#58a6ff}
        .remember{display:flex;align-items:center;gap:8px;margin-bottom:20px;cursor:pointer;font-size:12px;color:#8b949e}
        .remember input[type=checkbox]{width:auto;margin-bottom:0;accent-color:#58a6ff;cursor:pointer}
        .submit{width:100%;background:linear-gradient(135deg,#58a6ff,#bc8cff);color:#fff;border:none;border-radius:7px;padding:11px;font-size:13px;font-weight:700;cursor:pointer;transition:opacity .15s;letter-spacing:.3px;position:relative}
        .submit:hover:not(:disabled){opacity:.9}
        .submit:active:not(:disabled){opacity:.8}
        .submit:disabled{opacity:.7;cursor:not-allowed}
        .err{background:rgba(248,81,73,.08);border:1px solid rgba(248,81,73,.2);border-radius:7px;padding:10px 12px;font-size:12px;color:#f85149;margin-bottom:14px;word-break:break-word}
        .inf{background:rgba(63,185,80,.08);border:1px solid rgba(63,185,80,.2);border-radius:7px;padding:10px 12px;font-size:12px;color:#3fb950;margin-bottom:14px}
        .divider{display:flex;align-items:center;gap:10px;margin:20px 0;color:#484f58;font-size:11px}
        .divider::before,.divider::after{content:'';flex:1;height:1px;background:rgba(255,255,255,.06)}
        .footer{text-align:center;font-size:11px;color:#484f58;margin-top:24px}
      </style>
    </head>
    <body>
      <div class="bg"></div>
      <div class="wrap">
        <div class="card">
          <div class="logo">
            <span class="logo-hex">&#11041;</span>
            <span class="logo-name">PRZMA</span>
          </div>
          <div class="logo-sub">Control Plane</div>

          <h2>Administrator Sign In</h2>
          <p class="sub">Restricted access &mdash; authorised personnel only</p>

          #{error_html}
          #{info_html}

          <form method="post" action="/admin/login" id="loginForm" onsubmit="handleSubmit(event)">
            <input type="hidden" name="_csrf_token" value="#{csrf_token}"/>

            <div class="field">
              <label for="email">Email Address</label>
              <input type="email" id="email" name="email"
                placeholder="admin@przma.com"
                autocomplete="email" required autofocus/>
            </div>

            <div class="field">
              <label for="password">Password</label>
              <div class="pw-wrap">
                <input type="password" id="password" name="password"
                  placeholder="&bull;&bull;&bull;&bull;&bull;&bull;&bull;&bull;"
                  autocomplete="current-password" required/>
                <button type="button" class="eye" id="eyeBtn"
                  onclick="togglePw()" title="Show/hide password">&#9679;</button>
              </div>
            </div>

            <label class="remember">
              <input type="checkbox" name="remember_me" id="remember_me" value="1"/>
              Keep me signed in for 7 days
            </label>

            <button type="submit" class="submit" id="submitBtn">
              Sign In &rarr;
            </button>
          </form>

          <div class="footer">PRZMA Platform &mdash; Admin Access Only</div>
        </div>
      </div>

      <script>
        function togglePw() {
          var inp = document.getElementById('password');
          var btn = document.getElementById('eyeBtn');
          if (inp.type === 'password') {
            inp.type = 'text';
            btn.innerHTML = '&#9673;';
            btn.title = 'Hide password';
          } else {
            inp.type = 'password';
            btn.innerHTML = '&#9679;';
            btn.title = 'Show password';
          }
        }

        function handleSubmit(e) {
          var btn = document.getElementById('submitBtn');
          btn.classList.add('loading');
          btn.innerHTML = 'Signing in&hellip;';
          btn.disabled = true;
          return true;
        }

        // Restore password visibility state if user tabs back
        document.getElementById('password').addEventListener('blur', function() {
          if (this.type === 'text') {
            this.type = 'password';
            document.getElementById('eyeBtn').innerHTML = '&#9679;';
          }
        });
      </script>
    </body>
    </html>
    """
  end
end
