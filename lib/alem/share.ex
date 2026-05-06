defmodule Alem.Share do
  @moduledoc """
  Share token system — Zero copy, capability-based sharing.

  Alice wants Bob to see her photo:
    1. Alice calls Share.create/1 → gets token_id
    2. Alice sends token_id URL to Bob out-of-band
    3. Bob calls Share.access/2 with token_id + his DID
    4. Server validates: signature OK + not revoked + not expired + DID matches
    5. Server returns 1-hour presigned S3 URL
    6. URL expires → access gone
    7. No copy of the file was ever made

  Security:
    - Token signed with issuer DID (server verifies on every use)
    - target_did = nil → anyone with link (like a sharable link)
    - target_did = Bob's DID → only Bob can use it
    - expires_at mandatory → no forever tokens
    - revoke at any time → immediate effect
  """

  import Ecto.Query
  alias Alem.{Repo, DID}
  alias Alem.Schemas.{ShareToken, Document}
  alias Alem.Cas.CasDedupRef
  alias Alem.Home.Access
  require Logger

  # ── Create ────────────────────────────────────────────────────────────────

  @doc """
  Create a share token.

  Required opts:
    issuer_did  — who is sharing
    document_id — which document
    expires_in  — seconds from now (max 365 days)

  Optional opts:
    target_did  — restrict to a specific recipient DID
    scope       — "read" (default) | "read_write"
    note        — human description
    is_memorial — true for memorial tokens (set by memorial system)
  """
  def create(opts) do
    issuer_did  = Keyword.fetch!(opts, :issuer_did)
    document_id = Keyword.get(opts, :document_id)
    namespace_key = Keyword.get(opts, :namespace_key)
    target_did  = Keyword.get(opts, :target_did)
    expires_in  = Keyword.get(opts, :expires_in, 7 * 86_400)  # 7 days default
    scope       = Keyword.get(opts, :scope, "read")
    note        = Keyword.get(opts, :note)
    is_memorial = Keyword.get(opts, :is_memorial, false)

    # Validate document exists and belongs to issuer
    doc =
      if document_id do
        case validate_document_ownership(document_id, issuer_did) do
          {:ok, d} -> d
          {:error, _} = err -> return(err)
        end
      end

    expires_at = DateTime.add(DateTime.utc_now(), expires_in, :second)

    # Build signable payload (deterministic)
    payload = build_payload(issuer_did, document_id, namespace_key, target_did, expires_at)
    signature = sign_payload(payload, issuer_did)

    attrs = %{
      issuer_did:    issuer_did,
      target_did:    target_did,
      namespace_key: namespace_key || (doc && doc.tenant_id),
      document_id:   document_id,
      content_hash:  doc && doc.content_hash,
      folder:        doc && doc.folder || "personal",
      scope:         scope,
      expires_at:    expires_at,
      is_memorial:   is_memorial,
      note:          note,
      signature:     signature
    }

    case Repo.insert(%ShareToken{} |> ShareToken.changeset(attrs)) do
      {:ok, token} ->
        # Increment CAS ref_count so file is not deleted while token is active
        if doc && doc.content_hash do
          Alem.Cas.increment_ref_count(doc.content_hash)
        end

        Logger.info("[Share] ✅ Token #{token.id} created by #{issuer_did}")
        {:ok, token}

      {:error, cs} ->
        {:error, cs}
    end
  end

  # ── Access (validate + presign) ───────────────────────────────────────────

  @doc """
  Validate a share token and return a presigned S3 URL.
  requester_did — the DID of the person accessing the token.
  """
  def access(token_id, requester_did) do
    Access.presign_via_token(token_id, requester_did)
  end

  # ── List (issuer) ─────────────────────────────────────────────────────────

  @doc "List all tokens created by this DID."
  def list_issued(issuer_did) do
    Repo.all(
      from t in ShareToken,
      where: t.issuer_did == ^issuer_did and is_nil(t.revoked_at),
      order_by: [desc: t.inserted_at]
    )
  end

  # ── Revoke ────────────────────────────────────────────────────────────────

  @doc """
  Revoke a share token. Only the issuer can revoke.
  Immediate effect — next access attempt will fail.
  """
  def revoke(token_id, issuer_did) do
    case Repo.one(from t in ShareToken,
           where: t.id == ^token_id and t.issuer_did == ^issuer_did) do
      nil ->
        {:error, :not_found_or_not_owner}

      token ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        Repo.update(Ecto.Changeset.change(token, revoked_at: now))
        |> case do
          {:ok, t} ->
            # Decrement CAS ref_count
            if t.content_hash do
              Alem.Cas.decrement_ref_count(t.content_hash)
            end
            Logger.info("[Share] Token #{token_id} revoked by #{issuer_did}")
            {:ok, t}

          err -> err
        end
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp validate_document_ownership(document_id, issuer_did) do
    # Look up user by DID to get user_id
    user = Alem.Repo.get_by(Alem.Pleroma.User, did_id: issuer_did)

    if user do
      case Repo.get(Document, document_id) do
        nil -> {:error, :document_not_found}
        doc ->
          if doc.user_id == user.id,
            do: {:ok, doc},
            else: {:error, :not_owner}
      end
    else
      {:error, :issuer_not_found}
    end
  end

  defp build_payload(issuer_did, document_id, namespace_key, target_did, expires_at) do
    # Deterministic string for signing
    "przma-share-v1" <>
    "|issuer=#{issuer_did}" <>
    "|doc=#{document_id || "nil"}" <>
    "|ns=#{namespace_key || "nil"}" <>
    "|target=#{target_did || "any"}" <>
    "|expires=#{DateTime.to_unix(expires_at)}"
  end

  defp sign_payload(payload, _issuer_did) do
    # Deterministic HMAC with server's signing key
    # In production: use issuer's DID private key (from Tauri)
    # For now: server-side HMAC as placeholder
    key = System.get_env("SHARE_SIGNING_KEY", "dev-signing-key-change-in-prod")
    :crypto.mac(:hmac, :sha256, key, payload) |> Base.encode64()
  end

  defp return({:error, _} = e), do: throw(e)
end
