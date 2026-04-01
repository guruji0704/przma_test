defmodule ChatAppWeb.SessionController do
  use ChatAppWeb, :controller

  def create(conn, %{"username" => name}) do
    name = String.trim(name)

    if String.length(name) < 2 do
      conn
      |> put_flash(:error, "Name must be at least 2 characters!")
      |> redirect(to: "/")
    else
      unique_id   = :rand.uniform(9999)
      unique_name = "#{name}-#{unique_id}"

      conn
      |> put_session(:username, unique_name)
      |> redirect(to: "/chat")
    end
  end

  def delete(conn, _params) do
    conn
    |> clear_session()
    |> redirect(to: "/")
  end
end
