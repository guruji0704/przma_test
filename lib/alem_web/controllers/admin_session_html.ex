defmodule AlemWeb.AdminSessionHTML do
  use AlemWeb, :html

  def new(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8"/>
      <title>PRZMA Admin Login</title>
      <style>
        *{margin:0;padding:0;box-sizing:border-box}
        body{background:#0a0a0f;color:#e8e8f0;font-family:-apple-system,sans-serif;
             display:flex;align-items:center;justify-content:center;height:100vh}
        .card{background:#111118;border:1px solid rgba(255,255,255,.07);border-radius:14px;
              padding:40px;width:360px}
        .logo{display:flex;align-items:center;gap:10px;margin-bottom:32px;justify-content:center}
        .lm{width:32px;height:32px;background:linear-gradient(135deg,#4a9eff,#a78bfa);
            border-radius:8px;display:flex;align-items:center;justify-content:center;
            font-weight:800;color:#fff}
        .lt{font-size:15px;font-weight:700;letter-spacing:2px;
            background:linear-gradient(135deg,#4a9eff,#a78bfa);
            -webkit-background-clip:text;-webkit-text-fill-color:transparent}
        h2{font-size:18px;font-weight:700;margin-bottom:6px;text-align:center}
        p{font-size:12px;color:#9898b0;text-align:center;margin-bottom:28px}
        label{display:block;font-size:11px;font-weight:600;color:#9898b0;
              text-transform:uppercase;letter-spacing:.5px;margin-bottom:5px}
        input{width:100%;background:#18181f;border:1px solid rgba(255,255,255,.07);
              border-radius:7px;padding:10px 12px;color:#e8e8f0;font-size:13px;
              outline:none;margin-bottom:16px}
        input:focus{border-color:#4a9eff}
        button{width:100%;background:#4a9eff;color:#fff;border:none;border-radius:7px;
               padding:11px;font-size:13px;font-weight:700;cursor:pointer;margin-top:4px}
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

        <%= if msg = Phoenix.Flash.get(@conn.assigns.flash, :error) do %>
          <div class="err"><%= msg %></div>
        <% end %>
        <%= if msg = Phoenix.Flash.get(@conn.assigns.flash, :info) do %>
          <div class="inf"><%= msg %></div>
        <% end %>

        <form method="post" action="/admin/login">
          <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()}/>
          <label>Email</label>
          <input type="email" name="email" placeholder="admin@example.com" autocomplete="email"/>
          <label>Password</label>
          <input type="password" name="password" placeholder="••••••••" autocomplete="current-password"/>
          <button type="submit">Sign In →</button>
        </form>
      </div>
    </body>
    </html>
    """
  end
end
