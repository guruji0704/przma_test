defmodule AlemWeb.AdminSessionController do
  use AlemWeb, :controller
  alias Alem.Pleroma.User
  alias Alem.Repo

  def new(conn, _params) do
    flash_error = Phoenix.Flash.get(conn.assigns.flash, :error)
    flash_info  = Phoenix.Flash.get(conn.assigns.flash, :info)
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, login_page_html(flash_error, flash_info, get_csrf_token(conn)))
  end

  def create(conn, %{"email" => email, "password" => password}) do
    case Repo.get_by(User, email: email) do
      %User{is_admin: true} = user ->
        if User.verify_password(user, password) do
          conn
          |> put_session(:admin_user_id, user.id)
          |> redirect(to: "/admin")
        else
          redirect_login_with_error(conn, "Invalid email or password.")
        end

      %User{is_admin: false} ->
        redirect_login_with_error(conn, "This account does not have admin access.")

      nil ->
        # Prevent timing attacks — still run a dummy check
        Pbkdf2.no_user_verify()
        redirect_login_with_error(conn, "Invalid email or password.")
    end
  end

  def delete(conn, _params) do
    conn
    |> delete_session(:admin_user_id)
    |> redirect(to: "/admin/login")
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

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
    <html>
    <head>
      <meta charset="utf-8"/>
      <meta name="viewport" content="width=device-width, initial-scale=1"/>
      <title>PRZMA Admin Login</title>
      <style>
        *{margin:0;padding:0;box-sizing:border-box}
        body{background:#0a0a0f;color:#e8e8f0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
             display:flex;align-items:center;justify-content:center;height:100vh}
        .card{background:#111118;border:1px solid rgba(255,255,255,.07);border-radius:14px;
              padding:40px;width:360px}
        .logo{display:flex;align-items:center;gap:10px;margin-bottom:32px;justify-content:center}
        .lm{width:32px;height:32px;background:linear-gradient(135deg,#4a9eff,#a78bfa);
            border-radius:8px;display:flex;align-items:center;justify-content:center;
            font-weight:800;color:#fff;font-size:15px}
        .lt{font-size:15px;font-weight:700;letter-spacing:2px;
            background:linear-gradient(135deg,#4a9eff,#a78bfa);
            -webkit-background-clip:text;-webkit-text-fill-color:transparent}
        h2{font-size:18px;font-weight:700;margin-bottom:6px;text-align:center}
        p{font-size:12px;color:#9898b0;text-align:center;margin-bottom:28px}
        label{display:block;font-size:11px;font-weight:600;color:#9898b0;
              text-transform:uppercase;letter-spacing:.5px;margin-bottom:5px}
        input{width:100%;background:#18181f;border:1px solid rgba(255,255,255,.07);
              border-radius:7px;padding:10px 12px;color:#e8e8f0;font-size:13px;
              outline:none;margin-bottom:16px;transition:border-color .15s}
        input:focus{border-color:#4a9eff}
        button{width:100%;background:#4a9eff;color:#fff;border:none;border-radius:7px;
               padding:11px;font-size:13px;font-weight:700;cursor:pointer;margin-top:4px;
               transition:background .15s}
        button:hover{background:#3a8eef}
        .err{background:rgba(255,90,90,.1);border:1px solid rgba(255,90,90,.2);
             border-radius:7px;padding:10px 12px;font-size:12px;color:#ff5a5a;margin-bottom:16px}
        .inf{background:rgba(0,224,160,.1);border:1px solid rgba(0,224,160,.2);
             border-radius:7px;padding:10px 12px;font-size:12px;color:#00e0a0;margin-bottom:16px}
      </style>
    </head>
    <body>
      <div class="card">
        <div class="logo">
          <div class="lm">P</div>
          <span class="lt">PRZMA</span>
        </div>
        <h2>Admin Login</h2>
        <p>Sign in with your admin account</p>

        #{error_html}
        #{info_html}

        <form method="post" action="/admin/login">
          <input type="hidden" name="_csrf_token" value="#{csrf_token}"/>
          <label>Email</label>
          <input type="email" name="email" placeholder="admin@przma.com" autocomplete="email" required/>
          <label>Password</label>
          <input type="password" name="password" placeholder="••••••••" autocomplete="current-password" required/>
          <button type="submit">Sign In →</button>
        </form>
      </div>
    </body>
    </html>
    """
  end
end
