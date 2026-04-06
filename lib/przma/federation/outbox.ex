defmodule Przma.Federation.Outbox do
  @moduledoc """
  STUB: ActivityPub outbox — enqueues activities for delivery.

  TODO Phase 2: Implement with Oban workers that:
    1. Serialize the AP activity to JSON-LD
    2. Sign with HttpSignature (ed25519 or rsa-sha256)
    3. POST to each recipient's inbox URL
    4. Store in sender's outbox (PostgreSQL for public, sqld for private)
    5. Update delivery_status on success/failure
  """

  require Logger

  @doc """
  Enqueue an AP activity for delivery.

  actor_did   - the sender's DID
  type        - activity type atom: :Create, :Delete, :Like, :Follow, etc.
  object      - the AP object map (Note, Article, etc.)
  recipients  - list of recipient DIDs or inbox URLs
  opts        - [tier: :private | :social]
  """
  def enqueue(actor_did, type, object, recipients, opts \\ []) do
    tier = Keyword.get(opts, :private, :social)

    Logger.info("[Outbox] Enqueuing #{type} from #{actor_did} to #{length(recipients)} recipients (tier: #{tier})")

    # Stub: log and return ok — no actual delivery
    :ok
  end
end
