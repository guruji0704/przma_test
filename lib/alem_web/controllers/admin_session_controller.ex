defmodule AlemWeb.AdminSessionController do
  use AlemWeb, :controller
  alias Alem.Pleroma.User
  alias Alem.Repo

  def new(conn, _params) do
    render(conn, :new)
  end

  def create(conn, %{"email" => email, "password" => password}) do
    case Repo.get_by(User, email: email) do
      %User{is_admin: true} = user ->
        if User.verify_password(user, password) do
          conn
          |> put_session(:admin_user_id, user.id)
          |> put_flash(:info, "Welcome, #{user.nickname}!")
          |> redirect(to: "/admin")
        else
          conn
          |> put_flash(:error, "Invalid email or password.")
          |> render(:new)
        end

      %User{is_admin: false} ->
        conn
        |> put_flash(:error, "This account does not have admin access.")
        |> render(:new)

      nil ->
        # Prevent timing attacks — still run a dummy check
        Pbkdf2.no_user_verify()
        conn
        |> put_flash(:error, "Invalid email or password.")
        |> render(:new)
    end
  end

  def delete(conn, _params) do
    conn
    |> delete_session(:admin_user_id)
    |> put_flash(:info, "Logged out.")
    |> redirect(to: "/admin/login")
  end
end
