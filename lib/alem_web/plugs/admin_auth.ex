defmodule AlemWeb.Plugs.AdminAuth do
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    # Check session for a logged-in admin user
    user_id = get_session(conn, :user_id)

    if user_id && admin_user?(user_id) do
      conn
    else
      conn
      |> put_flash(:error, "You must be an admin to access this page.")
      |> redirect(to: "/")
      |> halt()
    end
  end

  defp admin_user?(user_id) do
    case Alem.Repo.get(Alem.Schemas.LocalUser, user_id) do
      %{is_admin: true} -> true
      _ -> false
    end
  end
end
