defmodule Alem.Cas do
  @moduledoc """
  CAS context — the ONLY place that talks to CAS tables via Repo.
  All CAS DB operations go through here.
  No other module should call Repo directly for CAS tables.
  """

  import Ecto.Query
  alias Alem.Repo
  alias Alem.Cas.{CasObject, CasActivity, CasEvent, CasDedupRef}

  # ── CasObject ─────────────────────────────────────────────────────────────

  def get_object(content_hash),
    do: Repo.get(CasObject, content_hash)

  def object_exists?(content_hash) do
    Repo.exists?(from o in CasObject, where: o.content_hash == ^content_hash)
  end

  def create_object(attrs) do
    %CasObject{}
    |> CasObject.ingest_changeset(attrs)
    |> Repo.insert()
  end

  def increment_ref_count(content_hash) do
    Repo.update_all(
      from(o in CasObject, where: o.content_hash == ^content_hash),
      inc: [ref_count: 1]
    )
  end

  def decrement_ref_count(content_hash) do
    Repo.update_all(
      from(o in CasObject, where: o.content_hash == ^content_hash),
      inc: [ref_count: -1]
    )
  end

  def list_objects(namespace_key) do
    Repo.all(
      from o in CasObject,
      where: o.namespace_key == ^namespace_key and o.is_current == true,
      order_by: [desc: o.inserted_at]
    )
  end

  # Find or register: core dedup logic
  # If hash exists → increment ref_count, return existing
  # If new → caller must upload to S3, then call create_object/1
  def find_or_register_object(content_hash, object_attrs) do
    case get_object(content_hash) do
      nil ->
        create_object(Map.put(object_attrs, :content_hash, content_hash))

      existing ->
        increment_ref_count(content_hash)
        {:ok, existing}
    end
  end

  # ── CasActivity ───────────────────────────────────────────────────────────

  def create_activity(attrs) do
    %CasActivity{}
    |> CasActivity.create_changeset(attrs)
    |> Repo.insert()
  end

  def list_activities(namespace_key, opts \\ []) do
    limit   = Keyword.get(opts, :limit, 50)
    from_dt = Keyword.get(opts, :from)

    query =
      from a in CasActivity,
      where: a.namespace_key == ^namespace_key and a.is_active == true,
      order_by: [desc: a.published_at],
      limit: ^limit

    query = if from_dt, do: where(query, [a], a.published_at > ^from_dt), else: query
    Repo.all(query)
  end

  def void_activity(%CasActivity{} = activity, voided_by_did, reason) do
    activity
    |> CasActivity.void_changeset(voided_by_did, reason)
    |> Repo.update()
  end

  # ── CasEvent ─────────────────────────────────────────────────────────────

  def create_event(attrs) do
    %CasEvent{}
    |> CasEvent.create_changeset(attrs)
    |> Repo.insert()
  end

  def list_events(namespace_key, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    Repo.all(
      from e in CasEvent,
      where: e.namespace_key == ^namespace_key,
      order_by: [desc: e.occurred_at],
      limit: ^limit
    )
  end

  # ── CasDedupRef ───────────────────────────────────────────────────────────

  def create_dedup_ref(attrs) do
    %CasDedupRef{}
    |> CasDedupRef.create_changeset(attrs)
    |> Repo.insert()
  end

  def get_dedup_ref(namespace_key, document_id) do
    Repo.one(
      from r in CasDedupRef,
      where: r.namespace_key == ^namespace_key
         and r.document_id   == ^document_id
         and r.is_active     == true
    )
  end

  def deactivate_ref(%CasDedupRef{} = ref, deactivated_by_did) do
    Repo.transaction(fn ->
      {:ok, updated_ref} =
        ref
        |> CasDedupRef.deactivate_changeset(deactivated_by_did)
        |> Repo.update()

      decrement_ref_count(ref.content_hash)

      obj = Repo.get(CasObject, ref.content_hash)
      if obj && obj.ref_count <= 1 do
        # Last reference gone — caller should also delete from S3
        Repo.delete!(obj)
        {:deactivated, updated_ref, :cas_object_deleted, ref.content_hash}
      else
        {:deactivated, updated_ref, :ref_count_decremented}
      end
    end)
  end
end
