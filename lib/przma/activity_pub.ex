defmodule Przma.ActivityPub do
  @moduledoc """
  STUB: ActivityPub helper utilities.
  TODO Phase 2: Full AP object builder and serializer.
  """

  @doc "Build the AP Actor URL for a DID."
  def actor_url(did) when is_binary(did) do
    base = PrzmaWeb.Endpoint.url()
    "#{base}/users/#{URI.encode(did)}"
  end

  @doc "Build the AP inbox URL for a DID."
  def inbox_url(did) do
    actor_url(did) <> "/inbox"
  end

  @doc "Build the AP outbox URL for a DID."
  def outbox_url(did) do
    actor_url(did) <> "/outbox"
  end
end
