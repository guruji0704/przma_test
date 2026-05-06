defmodule Alem.Commons do
  @moduledoc """
  PRZMA Commons Vault — platform-level read index of users' public content.

  Stores ONLY references (content_hash, document_id).
  No file copies. No S3 writes.
  PRZMA platform reads commons_index for collective intelligence.

  User removes from public → removed_at set → PRZMA loses access immediately.
  User deletes account → all commons rows for that DID removed.
  """

  import Ecto.Query
  alias Alem.{Repo, DID}
  alias Alem.Schemas.Document
  require Logger

  # ── Index ─────────────────────────────────────────────────────────────────

  @doc """
  Add a public document to the commons index.
  Called automatically by Uploader when folder = "public".
  """
  def index(%Document{} = doc, cas_obj) do
    prefix    = DID.namespace_key(doc.user_id) |> then(fn _ ->
      user = Alem.Repo.get(Alem.Pleroma.User, doc.user_id)
      user && user.did_id && DID.namespace_key(user.did_id)
    end)

    ns_key = doc.tenant_id  # already {prefix}-public

    attrs = %{
      id:             Ecto.UUID.generate(),
      content_hash:   doc.content_hash || (cas_obj && cas_obj.content_hash),
      document_id:    doc.id,
      owner_did:      resolve_did(doc.user_id),
      source_ns_key:  ns_key,
      media_type:     doc.content_type,
      media_category: doc.media_category,
      filename:       doc.filename,
      indexed_at:     DateTime.utc_now() |> DateTime.truncate(:second)
    }

    case Repo.insert(Alem.Schemas.CommonsIndex.changeset(%Alem.Schemas.CommonsIndex{}, attrs)) do
      {:ok, _} ->
        Logger.info("[Commons] ✅ Indexed #{doc.filename} (#{doc.id})")
        :ok

      {:error, cs} ->
        Logger.warning("[Commons] Index failed for #{doc.id}: #{inspect(cs.errors)}")
        :ok  # non-fatal
    end
  end

  # ── Remove ────────────────────────────────────────────────────────────────

  @doc """
  Remove a document from commons index.
  Sets removed_at — PRZMA immediately loses access.
  Called when user moves file out of public or deletes it.
  """
  def remove(document_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      Repo.update_all(
        from(c in Alem.Schemas.CommonsIndex,
          where: c.document_id == ^document_id and is_nil(c.removed_at)),
        set: [removed_at: now]
      )

    if count > 0 do
      Logger.info("[Commons] Removed doc #{document_id} from commons")
    end

    :ok
  end

  @doc "Remove ALL commons entries for a user (account deletion)."
  def remove_all_for(owner_did) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      Repo.update_all(
        from(c in Alem.Schemas.CommonsIndex,
          where: c.owner_did == ^owner_did and is_nil(c.removed_at)),
        set: [removed_at: now]
      )

    Logger.info("[Commons] Removed #{count} commons entries for #{owner_did}")
    :ok
  end

  # ── Query ─────────────────────────────────────────────────────────────────

  @doc "List active commons entries (PRZMA platform use only)."
  def list_active(opts \\ []) do
    limit    = Keyword.get(opts, :limit, 100)
    category = Keyword.get(opts, :category)

    query =
      from c in Alem.Schemas.CommonsIndex,
        where: is_nil(c.removed_at),
        order_by: [desc: c.indexed_at],
        limit: ^limit

    query = if category, do: where(query, [c], c.media_category == ^category), else: query
    Repo.all(query)
  end

  @doc "Count active commons entries."
  def count_active do
    Repo.aggregate(
      from(c in Alem.Schemas.CommonsIndex, where: is_nil(c.removed_at)),
      :count
    )
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp resolve_did(user_id) do
    case Alem.Repo.get(Alem.Pleroma.User, user_id) do
      nil  -> user_id
      user -> user.did_id || user_id
    end
  end
end
