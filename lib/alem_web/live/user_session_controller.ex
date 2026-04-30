defmodule AlemWeb.UserSessionController do
  use AlemWeb, :controller
  alias Alem.Pleroma.User
  alias Alem.Repo

  def new(conn, _params) do
    flash_error = Phoenix.Flash.get(conn.assigns.flash, :error)
    flash_info  = Phoenix.Flash.get(conn.assigns.flash, :info)
    csrf = Plug.CSRFProtection.get_csrf_token()
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, login_html(flash_error, flash_info, csrf))
  end

  def create(conn, %{"email" => email, "password" => password}) do
    case Repo.get_by(User, email: String.trim(email)) do
      %User{is_active: true} = user ->
        if User.verify_password(user, password) do
          conn
          |> configure_session(renew: true)
          |> put_session(:user_id, user.id)
          |> put_session(:user_login_at, System.system_time(:second))
          |> redirect(to: "/panel")
        else
          conn |> put_flash(:error, "Invalid email or password.") |> redirect(to: "/panel/login")
        end
      %User{is_active: false} ->
        conn |> put_flash(:error, "Account is disabled.") |> redirect(to: "/panel/login")
      nil ->
        Pbkdf2.no_user_verify()
        conn |> put_flash(:error, "Invalid email or password.") |> redirect(to: "/panel/login")
    end
  end

  def delete(conn, _params) do
    conn
    |> delete_session(:user_id)
    |> delete_session(:user_login_at)
    |> redirect(to: "/panel/login")
  end

  defp login_html(flash_error, flash_info, csrf) do
    err = if flash_error, do: "<div class=\"err\">#{flash_error}</div>", else: ""
    inf = if flash_info,  do: "<div class=\"inf\">#{flash_info}</div>",  else: ""
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8"/>
      <meta name="viewport" content="width=device-width, initial-scale=1"/>
      <title>PRZMA · Sign In</title>
      <style>
        *{margin:0;padding:0;box-sizing:border-box}
        body{background:#f8fafc;font-family:'Segoe UI',system-ui,sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh}
        .card{background:#fff;border:1px solid #e2e8f0;border-radius:14px;padding:40px;width:100%;max-width:400px;box-shadow:0 4px 24px rgba(0,0,0,.08)}
        .logo{text-align:center;margin-bottom:28px}
        .logo .brand{font-size:20px;font-weight:800;color:#0f172a;letter-spacing:-0.3px}
        .logo .sub{font-size:12px;color:#94a3b8;margin-top:4px}
        h2{font-size:17px;font-weight:700;color:#0f172a;margin-bottom:4px;text-align:center}
        .desc{font-size:12px;color:#94a3b8;text-align:center;margin-bottom:24px}
        label{display:block;font-size:12px;font-weight:600;color:#475569;margin-bottom:5px}
        .fg{margin-bottom:14px}
        input{width:100%;background:#f8fafc;border:1px solid #cbd5e1;border-radius:7px;padding:10px 12px;color:#0f172a;font-size:13px;outline:none;font-family:inherit;transition:.15s}
        input:focus{border-color:#2563eb;box-shadow:0 0 0 3px rgba(37,99,235,.1);background:#fff}
        .btn{width:100%;background:#2563eb;color:#fff;border:none;border-radius:7px;padding:11px;font-size:13px;font-weight:700;cursor:pointer;transition:.15s;margin-top:8px}
        .btn:hover{background:#1d4ed8}
        .err{background:#fef2f2;border:1px solid #fecaca;border-radius:7px;padding:10px 12px;font-size:12px;color:#dc2626;margin-bottom:14px}
        .inf{background:#ecfdf5;border:1px solid #a7f3d0;border-radius:7px;padding:10px 12px;font-size:12px;color:#059669;margin-bottom:14px}
        .footer{text-align:center;font-size:11px;color:#94a3b8;margin-top:20px}
      </style>
    </head>
    <body>
      <div class="card">
        <div class="logo">
          <div class="brand">⬡ PRZMA</div>
          <div class="sub">Sovereign File Platform</div>
        </div>
        <h2>Sign In</h2>
        <p class="desc">Enter your email and password to continue</p>
        #{err}#{inf}
        <form method="post" action="/panel/login">
          <input type="hidden" name="_csrf_token" value="#{csrf}"/>
          <div class="fg">
            <label>Email</label>
            <input type="email" name="email" placeholder="you@example.com" required autofocus/>
          </div>
          <div class="fg">
            <label>Password</label>
            <input type="password" name="password" placeholder="••••••••" required/>
          </div>
          <button class="btn" type="submit">Sign In →</button>
        </form>
        <div class="footer">PRZMA Platform</div>
      </div>
    </body>
    </html>
    """
  end
end