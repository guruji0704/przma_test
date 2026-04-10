defmodule AlemWeb.Plugs.AdminAuth do
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    user_id = get_session(conn, :admin_user_id)

    if user_id && admin_user?(user_id) do
      conn
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
end
