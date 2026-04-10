# lib/alem_web/controllers/page_controller.ex
defmodule AlemWeb.PageController do
  use AlemWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end

  # Add this:
  def redirect_to_admin(conn, _params) do
    redirect(conn, to: "/admin")
  end
end
