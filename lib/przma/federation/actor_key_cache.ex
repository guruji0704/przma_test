defmodule Przma.Federation.ActorKeyCache do
  @moduledoc """
  STUB: Fetches and caches remote actor public keys for HTTP Signature verification.

  TODO Phase 2: Implement with ETS cache + background refresh.
  Fetches the actor's AP profile (keyId URL), extracts publicKeyPem,
  and caches it with a TTL of 1 hour.
  """
  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state), do: {:ok, state}

  @doc """
  Get a public key by keyId, fetching from remote if not cached.
  keyId is the URL from the HTTP Signature header, e.g.:
    https://mastodon.social/users/alice#main-key
  """
  def get_or_fetch(key_id) when is_binary(key_id) do
    # Stub: reject all remote keys (no real federation in dev)
    {:error, {:key_not_found, key_id}}
  end
end
