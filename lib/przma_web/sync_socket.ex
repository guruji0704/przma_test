defmodule PrzmaWeb.SyncSocket do
  use Phoenix.Socket

  channel "crsql:*",       PrzmaWeb.Channels.Sync.CRSQLChannel
  channel "doc:*",         PrzmaWeb.Channels.Sync.DocChannel
  channel "cas_sync:*",    PrzmaWeb.Channels.Sync.CASChannel
  channel "sync_notify:*", PrzmaWeb.Channels.Sync.NotifyChannel

  def connect(%{"token" => token}, socket, _info) do
    case Przma.Identity.JWT.verify(token) do
      {:ok, claims} -> {:ok, assign(socket, :did, claims["sub"])}
      {:error, _}   -> :error
    end
  end

  def connect(_params, _socket, _info), do: :error

  def id(socket), do: "sync_socket:#{socket.assigns.did}"
end
