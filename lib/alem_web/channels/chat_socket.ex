defmodule AlemWeb.ChatSocket do
  use Phoenix.Socket

  channel "vault_chat:*", AlemWeb.ChatChannel
  channel "user:*",       AlemWeb.UserChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case Alem.Auth.verify_token(token) do
      {:ok, user} ->
        socket =
          socket
          |> assign(:user_id, user.id)
          |> assign(:username, user.nickname)
          |> assign(:user_did_key, extract_did_key(user.did_id))
        {:ok, socket}

      {:error, _} ->
        :error
    end
  end

  def connect(_, _socket, _), do: :error

  @impl true
  def id(socket), do: "chat_socket:#{socket.assigns.user_id}"

  defp extract_did_key(nil), do: nil
  defp extract_did_key("did:przma:" <> key), do: key
  defp extract_did_key(did), do: did
end
