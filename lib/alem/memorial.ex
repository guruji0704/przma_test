defmodule Alem.Memorial do
  @moduledoc """
  Memorial Token System — sovereign digital legacy.

  User sets up trusted contacts during their lifetime.
  When quorum of trusted contacts vote to activate:
    → read-only share token generated for personal namespace
    → token valid for configured expiry_days
    → private folder NEVER opened — by design
    → public folder already accessible — no token needed

  No government ID. No death certificate. Purely sovereign:
  trusted people who knew you vote to unlock your memory.
  """

  import Ecto.Query
  alias Alem.{Repo, Share}
  alias Alem.Schemas.{MemorialToken, ShareToken}
  alias Alem.DID
  require Logger

  # ── Setup ─────────────────────────────────────────────────────────────────

  @doc """
  Create or update memorial token config for a user.

  opts:
    owner_did    — DID of the user setting this up
    trusted_dids — list of DIDs who can activate
    quorum       — how many trusted_dids must vote (default 1)
    expiry_days  — how long the memorial token lives (default 365)
  """
  def setup(opts) do
    owner_did    = Keyword.fetch!(opts, :owner_did)
    trusted_dids = Keyword.fetch!(opts, :trusted_dids)
    quorum       = Keyword.get(opts, :quorum, 1)
    expiry_days  = Keyword.get(opts, :expiry_days, 365)

    # Enforce: private NEVER included in scope
    # Only personal namespace is ever opened via memorial
    attrs = %{
      owner_did:    owner_did,
      trusted_dids: trusted_dids,
      quorum:       quorum,
      scope_folders: ["personal"],  # hardcoded — private is NEVER openable
      expiry_days:  expiry_days
    }

    # Upsert — user can update their memorial config
    case Repo.get_by(MemorialToken, owner_did: owner_did) do
      nil ->
        Repo.insert(%MemorialToken{} |> MemorialToken.changeset(attrs))

      existing ->
        Repo.update(MemorialToken.changeset(existing, attrs))
    end
  end

  @doc "Get memorial config for a user."
  def get(owner_did) do
    case Repo.get_by(MemorialToken, owner_did: owner_did) do
      nil -> {:error, :not_configured}
      m   -> {:ok, m}
    end
  end

  # ── Activation ────────────────────────────────────────────────────────────

  @doc """
  A trusted contact votes to activate a memorial.
  voter_did must be in memorial.trusted_dids.

  When quorum is reached → generates read-only share token for personal namespace.
  Returns {:ok, :vote_recorded} or {:ok, :activated, token} or {:error, reason}
  """
  def vote(owner_did, voter_did) do
    case Repo.get_by(MemorialToken, owner_did: owner_did) do
      nil ->
        {:error, :not_configured}

      %{is_activated: true} ->
        {:error, :already_activated}

      %{revoked_at: r} when not is_nil(r) ->
        {:error, :revoked}

      memorial ->
        unless voter_did in memorial.trusted_dids do
          Logger.warning("[Memorial] #{voter_did} tried to vote but is not trusted contact of #{owner_did}")
          {:error, :not_a_trusted_contact}
        else
          current_votes = Enum.uniq(memorial.activated_by ++ [voter_did])

          Repo.update_all(
            from(m in MemorialToken, where: m.owner_did == ^owner_did),
            set: [activated_by: current_votes]
          )

          if MemorialToken.quorum_reached?(memorial, current_votes) do
            activate(memorial)
          else
            needed = memorial.quorum - length(current_votes)
            Logger.info("[Memorial] Vote recorded for #{owner_did}. #{needed} more needed.")
            {:ok, :vote_recorded, %{votes: length(current_votes), quorum: memorial.quorum}}
          end
        end
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp activate(memorial) do
    Logger.info("[Memorial] Quorum reached for #{memorial.owner_did} — generating read-only token")

    # Find the personal namespace for this user
    prefix = DID.namespace_key(memorial.owner_did)
    ns_key = "#{prefix}-personal"

    expires_in = memorial.expiry_days * 86_400

    case Share.create(
      issuer_did:    memorial.owner_did,
      namespace_key: ns_key,
      document_id:   nil,               # entire personal namespace
      target_did:    nil,               # any trusted contact can use
      scope:         "read",
      expires_in:    expires_in,
      is_memorial:   true,
      note:          "Memorial token — read-only access to personal namespace"
    ) do
      {:ok, token} ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        Repo.update_all(
          from(m in MemorialToken, where: m.owner_did == ^memorial.owner_did),
          set: [
            is_activated:       true,
            activated_at:       now,
            generated_token_id: token.id
          ]
        )

        Logger.info("[Memorial] ✅ Memorial activated for #{memorial.owner_did}. Token: #{token.id}")
        {:ok, :activated, token}

      {:error, reason} ->
        Logger.error("[Memorial] ❌ Failed to generate token for #{memorial.owner_did}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
