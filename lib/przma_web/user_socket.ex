defmodule PrzmaWeb.UserSocket do
  use Phoenix.Socket

  channel "vault:personal:*",      PrzmaWeb.Channels.Vault.PersonalChannel
  channel "vault:private:*",        PrzmaWeb.Channels.Vault.PrivateChannel
  channel "vault:social:*",         PrzmaWeb.Channels.Vault.SocialChannel
  channel "chat:dm:*",              PrzmaWeb.Channels.Chat.DMChannel
  channel "chat:circle:*",          PrzmaWeb.Channels.Chat.CircleChannel
  channel "chat:shout:*",           PrzmaWeb.Channels.Chat.ShoutChannel
  channel "chat:agent:*",           PrzmaWeb.Channels.Chat.AgentChannel
  channel "chat:agent:memorial:*",  PrzmaWeb.Channels.Chat.MemorialAgentChannel

  def connect(%{"token" => token}, socket, _connect_info) do
    case Przma.Identity.JWT.verify(token) do
      {:ok, claims} ->
        {:ok, assign(socket, :did, claims["sub"])}
      {:error, reason} ->
        require Logger
        Logger.warning("[UserSocket] Auth failed: #{inspect(reason)}")
        :error
    end
  end

  def connect(%{"agent_token" => token}, socket, _connect_info) do
    case Przma.Identity.CapabilityToken.verify_agent(token) do
      {:ok, cap} ->
        {:ok, socket
              |> assign(:did,       cap.owner_did)
              |> assign(:agent_cap, cap)}
      {:error, _} ->
        :error
    end
  end

  def connect(_params, _socket, _info), do: :error

  def id(socket), do: "user_socket:#{socket.assigns.did}"
end
