defmodule AlemWeb.Plugs.UserAuth do
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    user_id = get_session(conn, :user_id)

    if user_id do
      case Alem.Repo.get(Alem.Pleroma.User, user_id) do
        %{is_active: true} = user ->
          assign(conn, :current_user, user)
        _ ->
          conn |> redirect(to: "/panel/login") |> halt()
      end
    else
      conn |> redirect(to: "/panel/login") |> halt()
    end
  end
end