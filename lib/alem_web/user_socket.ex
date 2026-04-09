defmodule AlemWeb.UserSocket do
  use Phoenix.Socket
  use Absinthe.Phoenix.Socket, schema: AlemWeb.Schema

  @impl true
  def connect(_params, socket, _connect_info) do
    # For now accept all connections.
    # To restrict: verify token here and return {:error, :unauthorized}
    {:ok, socket}
  end

  @impl true
  def id(_socket), do: nil
end
