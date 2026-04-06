defmodule PrzmaWeb.Channels.Vault.PersonalChannel do
  use Phoenix.Channel
  def join("vault:personal:" <> did, _params, socket) do
    if socket.assigns.did == did, do: {:ok, socket}, else: {:error, %{reason: "unauthorized"}}
  end
  def handle_in(_event, _params, socket), do: {:reply, {:ok, %{status: "stub"}}, socket}
end

defmodule PrzmaWeb.Channels.Vault.PrivateChannel do
  use Phoenix.Channel
  def join("vault:private:" <> did, _params, socket) do
    if socket.assigns.did == did, do: {:ok, socket}, else: {:error, %{reason: "unauthorized"}}
  end
  def handle_in(_event, _params, socket), do: {:reply, {:ok, %{status: "stub"}}, socket}
end

defmodule PrzmaWeb.Channels.Vault.SocialChannel do
  use Phoenix.Channel
  def join("vault:social:" <> did, _params, socket) do
    if socket.assigns.did == did, do: {:ok, socket}, else: {:error, %{reason: "unauthorized"}}
  end
  def handle_in(_event, _params, socket), do: {:reply, {:ok, %{status: "stub"}}, socket}
end

defmodule PrzmaWeb.Channels.Chat.CircleChannel do
  use Phoenix.Channel
  def join("chat:circle:" <> _circle_did, _params, socket), do: {:ok, socket}
  def handle_in(_event, _params, socket), do: {:reply, {:ok, %{status: "stub"}}, socket}
end

defmodule PrzmaWeb.Channels.Chat.ShoutChannel do
  use Phoenix.Channel
  def join("chat:shout:" <> _author_did, _params, socket), do: {:ok, socket}
  def handle_in(_event, _params, socket), do: {:reply, {:ok, %{status: "stub"}}, socket}
end

defmodule PrzmaWeb.Channels.Chat.AgentChannel do
  use Phoenix.Channel
  def join("chat:agent:" <> _user_did, _params, socket), do: {:ok, socket}
  def handle_in(_event, _params, socket), do: {:reply, {:ok, %{status: "stub"}}, socket}
end

defmodule PrzmaWeb.Channels.Chat.MemorialAgentChannel do
  use Phoenix.Channel
  def join("chat:agent:memorial:" <> _did, _params, socket), do: {:ok, socket}
  def handle_in(_event, _params, socket), do: {:reply, {:ok, %{status: "stub"}}, socket}
end

defmodule PrzmaWeb.Channels.Sync.CRSQLChannel do
  use Phoenix.Channel
  def join("crsql:" <> _did, _params, socket), do: {:ok, socket}
  def handle_in(_event, _params, socket), do: {:reply, {:ok, %{status: "stub"}}, socket}
end

defmodule PrzmaWeb.Channels.Sync.DocChannel do
  use Phoenix.Channel
  def join("doc:" <> _path, _params, socket), do: {:ok, socket}
  def handle_in(_event, _params, socket), do: {:reply, {:ok, %{status: "stub"}}, socket}
end

defmodule PrzmaWeb.Channels.Sync.CASChannel do
  use Phoenix.Channel
  def join("cas_sync:" <> _did, _params, socket), do: {:ok, socket}
  def handle_in(_event, _params, socket), do: {:reply, {:ok, %{status: "stub"}}, socket}
end

defmodule PrzmaWeb.Channels.Sync.NotifyChannel do
  use Phoenix.Channel
  def join("sync_notify:" <> _did, _params, socket), do: {:ok, socket}
  def handle_in(_event, _params, socket), do: {:reply, {:ok, %{status: "stub"}}, socket}
end
