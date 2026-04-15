defmodule AlemWeb.Plugs.AdminAuth do
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    user_id = get_session(conn, :admin_user_id)
    login_ip = get_session(conn, :admin_ip)
    current_ip = get_client_ip(conn)

    if user_id && admin_user?(user_id) do
      # Verify IP hasn't changed (basic session hijacking prevention)
      if login_ip && login_ip != current_ip do
        conn
        |> delete_session(:admin_user_id)
        |> delete_session(:admin_ip)
        |> delete_session(:remember_me)
        |> redirect(to: "/admin/login?session_expired=1")
        |> halt()
      else
        assign(conn, :admin_user_id, user_id)
      end
    else
      conn
      |> redirect(to: "/admin/login")
      |> halt()
    end
  end

  defp admin_user?(user_id) do
    case Alem.Repo.get(Alem.Pleroma.User, user_id) do
      %{is_admin: true} -> true
      _ -> false
    end
  end

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
end
