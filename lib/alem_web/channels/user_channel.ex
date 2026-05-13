defmodule AlemWeb.UserChannel do
  use AlemWeb, :channel

  # Topic: "user:{user_id}"
  # Each user subscribes to their own personal channel for invite notifications.
  @impl true
  def join("user:" <> topic_id, _params, socket) do
    uid     = socket.assigns.user_id
    did_key = Map.get(socket.assigns, :user_did_key)
    if topic_id == uid or (did_key != nil and topic_id == did_key) do
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  def join(_, _, _), do: {:error, %{reason: "invalid_topic"}}
end
