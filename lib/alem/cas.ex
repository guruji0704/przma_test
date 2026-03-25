defmodule Alem.Cas do
  @moduledoc """
  CAS context — Content Addressable Storage.

  All public functions go through this module.
  No other module should call Repo directly for CAS tables.
  """

  import Ecto.Query
  alias Alem.Repo
  alias Alem.Cas.{CasObject, CasActivity, CasEvent, CasDedupRef}

  # ── CasObject ────────────────────────────────────────────────────────────

  def get_object(content_hash),
    do: Repo.get(CasObject, content_hash)

  def get_current_object(namespace_key, storage_key) do
    Repo.one(
      from o in CasObject,
      where: o.namespace_key == ^namespace_key
         and o.storage_key == ^storage_key
         and o.is_current == true
    )
  end

  def list_objects(namespace_key) do
    Repo.all(
      from o in CasObject,
      where: o.namespace_key == ^namespace_key
         and o.is_current == true,
      order_by: [desc: o.inserted_at]
    )
  end

  def create_object(attrs) do
    %CasObject{}
    |> CasObject.ingest_changeset(attrs)
    |> Repo.insert()
  end

  def object_exists?(content_hash) do
    Repo.exists?(from o in CasObject, where: o.content_hash == ^content_hash)
  end

  # ── CasActivity ─────────────────────────────────────────────────────────

  def list_activities(namespace_key, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    from_dt = Keyword.get(opts, :from)

    query =
      from a in CasActivity,
      where: a.namespace_key == ^namespace_key
         and a.is_active == true,
      order_by: [desc: a.published_at],
      limit: ^limit

    query =
      if from_dt do
        where(query, [a], a.published_at > ^from_dt)
      else
        query
      end

    Repo.all(query)
  end

  def create_activity(attrs) do
    %CasActivity{}
    |> CasActivity.create_changeset(attrs)
    |> Repo.insert()
  end

  def void_activity(%CasActivity{} = activity, voided_by_did, reason) do
    activity
    |> CasActivity.void_changeset(voided_by_did, reason)
    |> Repo.update()
  end

  # ── CasEvent ────────────────────────────────────────────────────────────

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

  def events_for_request(request_id) do
    Repo.all(
      from e in CasEvent,
      where: e.request_id == ^request_id,
      order_by: [asc: e.event_seq]
    )
  end

  # ── CasDedupRef ──────────────────────────────────────────────────────────

  def create_dedup_ref(attrs) do
    %CasDedupRef{}
    |> CasDedupRef.create_changeset(attrs)
    |> Repo.insert()
  end

  def list_active_refs(namespace_key) do
    Repo.all(
      from r in CasDedupRef,
      where: r.namespace_key == ^namespace_key
         and r.is_active == true,
      order_by: [desc: r.inserted_at]
    )
  end

  def deactivate_ref(%CasDedupRef{} = ref, deactivated_by_did) do
    Repo.transaction(fn ->
      # 1. Deactivate the ref
      {:ok, updated_ref} =
        ref
        |> CasDedupRef.deactivate_changeset(deactivated_by_did)
        |> Repo.update()

      # 2. Decrement ref_count on cas_objects
      {1, _} =
        Repo.update_all(
          from(o in CasObject, where: o.content_hash == ^ref.content_hash),
          inc: [ref_count: -1]
        )

      # 3. Fetch updated ref_count
      obj = Repo.get!(CasObject, ref.content_hash)

      # 4. If ref_count = 0, delete the CAS object row
      # Application must also delete S3 bytes after this
      if obj.ref_count == 0 do
        Repo.delete!(obj)
        {:deactivated, updated_ref, :cas_object_deleted, obj.storage_key}
      else
        {:deactivated, updated_ref, :ref_count, obj.ref_count}
      end
    end)
  end

  # ── Dedup check (use this on every upload) ────────────────────────────────

  def find_or_register_object(content_hash, object_attrs) do
    case get_object(content_hash) do
      nil ->
        # New file — insert and upload to S3
        create_object(Map.put(object_attrs, :content_hash, content_hash))

      existing ->
        # Same bytes already in S3 — just increment ref_count
        Repo.update_all(
          from(o in CasObject, where: o.content_hash == ^content_hash),
          inc: [ref_count: 1]
        )
        {:ok, existing}
    end
  end
end
