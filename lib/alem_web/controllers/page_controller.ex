defmodule AlemWeb.PageController do
  use AlemWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
