defmodule Alem.Namespace do
  @moduledoc """
  THE GATEWAY — every operation goes through here.

  Two responsibilities:
    1. Namespace lifecycle (delegates to Manager GenServer)
    2. Document operations (direct Ecto + CAS)

  Callers only need to alias Alem.Namespace — nothing else.
  """

  alias Alem.{Repo, Schemas.Namespace, Schemas.Document, DID, Cas}
  alias Alem.Cas.CasDedupRef
  alias Alem.Storage.CAS
  alias Alem.Namespace.Manager
  import Ecto.Query
  require Logger

  # ── Namespace lifecycle delegates (forward to Manager GenServer) ───────────

  @doc "Start the GenServer for a namespace. Horde supervises it."
  defdelegate start(user_id, tenant_id, opts \\ []), to: Manager

  @doc "Stop the GenServer for a namespace."
  defdelegate stop(user_id), to: Manager

  @doc "True if namespace exists in DB or as a running GenServer."
  defdelegate exists?(user_id), to: Manager

  @doc "Status of a namespace (from GenServer or DB if offline)."
  defdelegate status(user_id), to: Manager

  @doc "Get runtime config from the namespace GenServer."
  defdelegate get_config(user_id), to: Manager

  @doc "Update runtime config in the namespace GenServer."
  defdelegate update_config(user_id, config), to: Manager

  # ── Namespace lifecycle ────────────────────────────────────────────────────

  @doc "Create namespace row for a new user. Called after registration."
  def create_for_user(%{id: user_id, did_id: did_id}) do
    namespace_key = DID.namespace_key(did_id)

    attrs = %{
      id:              namespace_key,
      tenant_id:       namespace_key,
      did:             did_id,
      identity_type:   "did",
      config: %{
        storage: %{
          s3_bucket:  "perkeep",
          s3_prefix:  "user/#{namespace_key}/",
        }
      },
      status:          "active",
      last_activity_at: DateTime.utc_now()
    }

    case Repo.insert(%Namespace{} |> Namespace.changeset(attrs)) do
      {:ok, namespace} ->
        Logger.info("[Namespace] Created #{namespace_key} for user #{user_id}")
        {:ok, namespace}

      {:error, changeset} ->
        Logger.error("[Namespace] Create failed for #{user_id}: #{inspect(changeset.errors)}")
        {:error, changeset}
    end
  end

  def get_for_user(user_id) do
    user = Repo.get(Alem.Pleroma.User, user_id)

    if user && user.did_id do
      namespace_key = DID.namespace_key(user.did_id)
      case Repo.get(Namespace, namespace_key) do
        nil       -> {:error, :not_found}
        namespace -> {:ok, namespace}
      end
    else
      {:error, :no_did}
    end
  end

  def get(namespace_key) do
    case Repo.get(Namespace, namespace_key) do
      nil       -> {:error, :not_found}
      namespace -> {:ok, namespace}
    end
  end

  def touch(namespace_key) do
    case get(namespace_key) do
      {:ok, namespace} ->
        namespace
        |> Namespace.changeset(%{last_activity_at: DateTime.utc_now()})
        |> Repo.update()
      error -> error
    end
  end

  def update_stats(namespace_key, stats) do
    case get(namespace_key) do
      {:ok, namespace} ->
        namespace
        |> Namespace.changeset(stats)
        |> Repo.update()
      error -> error
    end
  end

  # ── THE UPLOAD GATEWAY ─────────────────────────────────────────────────────

  @doc """
  Ingest a file into the namespace. This is the ONLY entry point for uploads.

  Steps (all in one DB transaction):
    1. CAS.put — compute SHA-256, skip S3 if duplicate, otherwise upload
    2. Insert documents row (FK → cas_objects.content_hash)
    3. Insert cas_dedup_refs row (user's personal pointer)
    4. Insert cas_activities row (audit trail, verb: "Upload")
    5. Touch namespace last_activity_at

  Returns {:ok, document, cas_object} or {:error, reason}.
  """
  def ingest_document(namespace_key, %{
    doc_id:       doc_id,
    filename:     filename,
    file_data:    data,
    content_type: content_type,
    metadata:     metadata
  }) do
    # Check dedup BEFORE the transaction — so we can return it to the caller.
    # The resolver must NOT call CAS directly. Namespace decides everything.
    hash         = CAS.compute_hash(data)
    is_duplicate = CAS.exists?(hash)

    Repo.transaction(fn ->
      # Step 1: CAS — dedup S3
      case CAS.put(data, content_type) do
        {:ok, cas_obj} ->
          # Step 2: Document row
          doc_attrs = %{
            id:            doc_id,
            tenant_id:     namespace_key,
            user_id:       namespace_key,
            filename:      filename,
            content_type:  content_type,
            content_hash:  cas_obj.content_hash,
            file_size:     byte_size(data),
            activity_verb: "Upload",
            actor_id:      namespace_key,
            metadata:      metadata,
            status:        "synced"
          }

          case Repo.insert(Document.changeset(%Document{}, doc_attrs)) do
            {:ok, doc} ->
              # Step 3: Dedup ref — user's personal pointer
              Repo.insert(CasDedupRef.create_changeset(%CasDedupRef{}, %{
                tenant_id:     namespace_key,
                namespace_key: namespace_key,
                actor_did:     namespace_key,
                user_id:       namespace_key,
                content_hash:  cas_obj.content_hash,
                document_id:   doc_id,
                user_filename: filename,
                is_active:     true
              }))

              # Step 4: Activity log
              Cas.create_activity(%{
                tenant_id:     namespace_key,
                namespace_key: namespace_key,
                actor_did:     namespace_key,
                user_id:       namespace_key,
                auth_id:       namespace_key,
                verb:          "Upload",
                object_hash:   cas_obj.content_hash,
                object_type:   "Document",
                object_id:     doc_id
              })

              # Step 5: Update namespace
              touch(namespace_key)

              Logger.info("[Namespace:#{namespace_key}] Ingested #{filename} → #{String.slice(cas_obj.content_hash, 0, 16)}…")
              # Carry is_duplicate out so resolver never needs to call CAS itself
              {doc, cas_obj, is_duplicate}

            {:error, changeset} ->
              Repo.rollback(changeset)
          end

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {doc, cas_obj, is_duplicate}} -> {:ok, doc, cas_obj, is_duplicate}
      {:error, reason}                    -> {:error, reason}
    end
  end

  # ── Document queries ───────────────────────────────────────────────────────

  def list_documents(namespace_key, opts \\ %{}) do
    limit  = Map.get(opts, :limit,  20)
    offset = Map.get(opts, :offset, 0)
    status = Map.get(opts, :status)

    query =
      from d in Document,
      where: d.tenant_id == ^namespace_key,
      order_by: [desc: d.inserted_at],
      limit: ^limit,
      offset: ^offset

    query = if status, do: where(query, [d], d.status == ^status), else: query

    {:ok, Repo.all(query)}
  end

  def get_document(namespace_key, doc_id) do
    case Repo.one(
      from d in Document,
      where: d.id == ^doc_id and d.tenant_id == ^namespace_key
    ) do
      nil -> {:error, "Document not found"}
      doc -> {:ok, doc}
    end
  end

  def search_documents(namespace_key, search_query, opts \\ %{}) do
    limit = Map.get(opts, :limit, 20)

    results = Repo.all(
      from d in Document,
      where: d.tenant_id == ^namespace_key,
      where: fragment(
        "to_tsvector('english', coalesce(?, '')) @@ plainto_tsquery('english', ?)",
        d.text_content, ^search_query
      ),
      order_by: [desc: fragment(
        "ts_rank(to_tsvector('english', coalesce(?, '')), plainto_tsquery('english', ?))",
        d.text_content, ^search_query
      )],
      limit: ^limit
    )

    {:ok, results}
  end

  def delete_document(namespace_key, doc_id) do
    case Repo.one(
      from d in Document,
      where: d.id == ^doc_id and d.tenant_id == ^namespace_key
    ) do
      nil ->
        {:error, :not_found}

      doc ->
        Repo.transaction(fn ->
          # Deactivate dedup ref first (FK RESTRICT prevents deleting doc while ref exists)
          case Cas.get_dedup_ref(namespace_key, doc_id) do
            nil -> :ok
            ref -> Cas.deactivate_ref(ref, namespace_key)
          end

          # Log the delete
          Cas.create_activity(%{
            tenant_id:     namespace_key,
            namespace_key: namespace_key,
            actor_did:     namespace_key,
            user_id:       namespace_key,
            auth_id:       namespace_key,
            verb:          "Delete",
            object_type:   "Document",
            object_id:     doc_id
          })

          Repo.delete!(doc)
          Logger.info("[Namespace:#{namespace_key}] Deleted #{doc_id}")
          :ok
        end)
        |> case do
          {:ok, :ok}       -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end
end
