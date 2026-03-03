defmodule Alem.Sync.Manager do
  @moduledoc """
  Sync Manager - Coordinates all sync operations between Tauri clients and server.

  Handles:
  - Change tracking and merging
  - S3 file uploads via presigned URLs
  - sqld metadata synchronization
  - PostgreSQL full-text search updates
  - CRDT-based conflict resolution
  """

  use GenServer
  require Logger

  alias Alem.{Repo, DID}
  alias Alem.Schemas.{Document, SyncLog}
  alias Alem.Sync.{ChangeTracker, ConflictResolver, Session}
  import Ecto.Query

  @sync_check_interval 60_000  # Check for stale sessions every 60s
  @session_timeout 300_000     # 5 minutes

  defstruct [
    :active_sessions,
    :stats
  ]

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Start a sync session for a user"
  def start_session(user_id, client_info \\ %{}) do
    GenServer.call(__MODULE__, {:start_session, user_id, client_info})
  end

  @doc "End a sync session"
  def end_session(session_id) do
    GenServer.call(__MODULE__, {:end_session, session_id})
  end

  @doc "Apply changes from Tauri client"
  def apply_changes(user_id, changes, session_id) do
    GenServer.call(__MODULE__, {:apply_changes, user_id, changes, session_id}, 30_000)
  end

  @doc "Get changes since timestamp for a user"
  def get_changes(user_id, since, limit \\ 100) do
    GenServer.call(__MODULE__, {:get_changes, user_id, since, limit})
  end

  @doc "Generate presigned S3 upload URL"
  def get_upload_url(user_id, filename, doc_id) do
    GenServer.call(__MODULE__, {:get_upload_url, user_id, filename, doc_id})
  end

  @doc "Get sync statistics for a user"
  def get_stats(user_id) do
    GenServer.call(__MODULE__, {:get_stats, user_id})
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    Logger.info("[SyncManager] Starting sync manager")

    # Schedule periodic cleanup
    schedule_cleanup()

    state = %__MODULE__{
      active_sessions: %{},
      stats: %{
        total_syncs: 0,
        total_changes: 0,
        total_conflicts: 0
      }
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:start_session, user_id, client_info}, _from, state) do
    session_id = generate_session_id()

    session = %Session{
      id: session_id,
      user_id: user_id,
      client_info: client_info,
      started_at: DateTime.utc_now(),
      last_activity: DateTime.utc_now()
    }

    new_sessions = Map.put(state.active_sessions, session_id, session)

    Logger.info("[SyncManager] Started session #{session_id} for user #{user_id}")

    {:reply, {:ok, session_id}, %{state | active_sessions: new_sessions}}
  end

  @impl true
  def handle_call({:end_session, session_id}, _from, state) do
    case Map.get(state.active_sessions, session_id) do
      nil ->
        {:reply, {:error, :session_not_found}, state}

      session ->
        Logger.info("[SyncManager] Ended session #{session_id} for user #{session.user_id}")
        new_sessions = Map.delete(state.active_sessions, session_id)
        {:reply, :ok, %{state | active_sessions: new_sessions}}
    end
  end

  @impl true
  def handle_call({:apply_changes, user_id, changes, session_id}, _from, state) do
    Logger.info("[SyncManager] Applying #{length(changes)} changes for user #{user_id}")

    # Update session activity
    state = update_session_activity(state, session_id)

    # Get user's namespace key
    user = Repo.get(Alem.Pleroma.User, user_id)
    namespace_key = DID.namespace_key(user.did_id)

    # Process changes
    {results, conflicts} = process_changes(user_id, namespace_key, changes)

    # Update stats
    new_stats = %{
      state.stats |
      total_syncs: state.stats.total_syncs + 1,
      total_changes: state.stats.total_changes + length(changes),
      total_conflicts: state.stats.total_conflicts + length(conflicts)
    }

    response = %{
      applied: length(results),
      conflicts: conflicts,
      results: results
    }

    {:reply, {:ok, response}, %{state | stats: new_stats}}
  end

  @impl true
  def handle_call({:get_changes, user_id, since, limit}, _from, state) do
    Logger.info("[SyncManager] Fetching changes for user #{user_id} since #{since}")

    changes = fetch_changes_since(user_id, since, limit)

    {:reply, {:ok, changes}, state}
  end

  @impl true
  def handle_call({:get_upload_url, user_id, filename, doc_id}, _from, state) do
    user = Repo.get(Alem.Pleroma.User, user_id)
    namespace_key = DID.namespace_key(user.did_id)

    result = generate_s3_upload_url(namespace_key, filename, doc_id)

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_stats, user_id}, _from, state) do
    stats = calculate_user_stats(user_id)
    {:reply, {:ok, stats}, state}
  end

  @impl true
  def handle_info(:cleanup_sessions, state) do
    new_sessions = cleanup_stale_sessions(state.active_sessions)
    schedule_cleanup()
    {:noreply, %{state | active_sessions: new_sessions}}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_sessions, @sync_check_interval)
  end

  defp update_session_activity(state, session_id) do
    case Map.get(state.active_sessions, session_id) do
      nil -> state
      session ->
        updated_session = %{session | last_activity: DateTime.utc_now()}
        new_sessions = Map.put(state.active_sessions, session_id, updated_session)
        %{state | active_sessions: new_sessions}
    end
  end

  defp cleanup_stale_sessions(sessions) do
    now = DateTime.utc_now()

    Enum.reject(sessions, fn {session_id, session} ->
      diff = DateTime.diff(now, session.last_activity, :millisecond)

      if diff > @session_timeout do
        Logger.info("[SyncManager] Cleaning up stale session #{session_id}")
        true
      else
        false
      end
    end)
    |> Enum.into(%{})
  end

  # ============================================================================
  # Change Processing
  # ============================================================================

  defp process_changes(user_id, namespace_key, changes) do
    results = Enum.map(changes, fn change ->
      process_single_change(user_id, namespace_key, change)
    end)

    # Separate successful results from conflicts
    conflicts = Enum.filter(results, fn r -> r.status == :conflict end)
    successful = Enum.filter(results, fn r -> r.status == :ok end)

    {successful, conflicts}
  end

  defp process_single_change(user_id, namespace_key, change) do
    case change["type"] do
      "create_document" ->
        handle_create_document(user_id, namespace_key, change["data"])

      "update_document" ->
        handle_update_document(user_id, namespace_key, change["data"])

      "delete_document" ->
        handle_delete_document(user_id, namespace_key, change["data"])

      unknown_type ->
        Logger.warning("[SyncManager] Unknown change type: #{unknown_type}")
        %{status: :error, type: unknown_type, reason: "unsupported_type"}
    end
  end

  defp handle_create_document(user_id, namespace_key, data) do
    attrs = %{
      id: data["id"],
      user_id: user_id,
      tenant_id: namespace_key,
      filename: data["filename"],
      content_type: data["content_type"],
      object_key: data["object_key"],
      content_hash: data["content_hash"],
      text_content: data["text_content"],
      metadata: data["metadata"] || %{},
      status: "synced"
    }

    case Repo.insert(%Document{} |> Document.changeset(attrs)) do
      {:ok, doc} ->
        # Log sync event
        create_sync_log(user_id, "create_document", doc.id, "success")

        %{status: :ok, type: "create_document", id: doc.id}

      {:error, %Ecto.Changeset{errors: errors}} ->
        # Check if it's a conflict (document already exists)
        if Keyword.has_key?(errors, :id) do
          # Document exists - try to resolve conflict
          existing = Repo.get(Document, data["id"])
          resolved = ConflictResolver.resolve_document_conflict(existing, data)

          case Repo.update(Document.changeset(existing, resolved)) do
            {:ok, doc} ->
              create_sync_log(user_id, "create_document", doc.id, "conflict_resolved")
              %{status: :conflict, type: "create_document", id: doc.id, resolution: "merged"}

            {:error, _} ->
              create_sync_log(user_id, "create_document", data["id"], "conflict_failed")
              %{status: :error, type: "create_document", id: data["id"], reason: "conflict_resolution_failed"}
          end
        else
          %{status: :error, type: "create_document", reason: format_errors(errors)}
        end
    end
  end

  defp handle_update_document(user_id, namespace_key, data) do
    case Repo.get(Document, data["id"]) do
      nil ->
        # Document doesn't exist locally - create it
        handle_create_document(user_id, namespace_key, data)

      existing_doc ->
        # Check for conflicts
        if existing_doc.user_id != user_id do
          %{status: :error, type: "update_document", reason: "unauthorized"}
        else
          # Resolve any conflicts using CRDT
          resolved_data = ConflictResolver.resolve_document_conflict(existing_doc, data)

          case Repo.update(Document.changeset(existing_doc, resolved_data)) do
            {:ok, doc} ->
              create_sync_log(user_id, "update_document", doc.id, "success")
              %{status: :ok, type: "update_document", id: doc.id}

            {:error, changeset} ->
              %{status: :error, type: "update_document", reason: format_errors(changeset.errors)}
          end
        end
    end
  end

  defp handle_delete_document(user_id, _namespace_key, data) do
    case Repo.get(Document, data["id"]) do
      nil ->
        %{status: :ok, type: "delete_document", id: data["id"], note: "already_deleted"}

      doc ->
        if doc.user_id != user_id do
          %{status: :error, type: "delete_document", reason: "unauthorized"}
        else
          case Repo.delete(doc) do
            {:ok, _} ->
              create_sync_log(user_id, "delete_document", data["id"], "success")
              %{status: :ok, type: "delete_document", id: data["id"]}

            {:error, changeset} ->
              %{status: :error, type: "delete_document", reason: format_errors(changeset.errors)}
          end
        end
    end
  end

  # ============================================================================
  # Change Fetching
  # ============================================================================

  defp fetch_changes_since(user_id, since_iso, limit) do
    {:ok, since_dt, _} = DateTime.from_iso8601(since_iso)

    docs = Repo.all(
      from d in Document,
      where: d.user_id == ^user_id,
      where: d.updated_at > ^since_dt,
      order_by: [asc: d.updated_at],
      limit: ^limit
    )

    Enum.map(docs, fn doc ->
      %{
        type: determine_change_type(doc),
        id: doc.id,
        timestamp: DateTime.to_iso8601(doc.updated_at),
        data: %{
          id: doc.id,
          filename: doc.filename,
          content_type: doc.content_type,
          object_key: doc.object_key,
          content_hash: doc.content_hash,
          text_content: doc.text_content,
          metadata: doc.metadata,
          status: doc.status,
          updated_at: DateTime.to_iso8601(doc.updated_at)
        }
      }
    end)
  end

  defp determine_change_type(doc) do
    cond do
      doc.status == "deleted" -> "delete_document"
      doc.inserted_at == doc.updated_at -> "create_document"
      true -> "update_document"
    end
  end

  # ============================================================================
  # S3 Presigned URLs
  # ============================================================================

  defp generate_s3_upload_url(namespace_key, filename, doc_id) do
    bucket = "perkeep"
    object_key = "user/#{namespace_key}/documents/#{doc_id}/#{filename}"

    case ExAws.S3.presigned_url(
      ExAws.Config.new(:s3),
      :put,
      bucket,
      object_key,
      expires_in: 3600,
      virtual_host: false
    ) do
      {:ok, url} ->
        {:ok, %{
          upload_url: url,
          object_key: object_key,
          bucket: bucket,
          expires_in: 3600
        }}

      {:error, reason} ->
        Logger.error("[SyncManager] Failed to generate upload URL: #{inspect(reason)}")
        {:error, :url_generation_failed}
    end
  end

  # ============================================================================
  # Statistics
  # ============================================================================

  defp calculate_user_stats(user_id) do
    total_docs = Repo.one(
      from d in Document,
      where: d.user_id == ^user_id,
      select: count(d.id)
    )

    synced_docs = Repo.one(
      from d in Document,
      where: d.user_id == ^user_id,
      where: d.status == "synced",
      select: count(d.id)
    )

    total_size = Repo.one(
      from d in Document,
      where: d.user_id == ^user_id,
      select: sum(d.file_size)
    ) || 0

    recent_syncs = Repo.one(
      from l in SyncLog,
      where: l.user_id == ^user_id,
      where: l.inserted_at > ago(7, "day"),
      select: count(l.id)
    )

    %{
      total_documents: total_docs,
      synced_documents: synced_docs,
      pending_documents: total_docs - synced_docs,
      total_storage_bytes: total_size,
      recent_syncs: recent_syncs,
      last_sync: get_last_sync_time(user_id)
    }
  end

  defp get_last_sync_time(user_id) do
    case Repo.one(
      from l in SyncLog,
      where: l.user_id == ^user_id,
      order_by: [desc: l.inserted_at],
      limit: 1,
      select: l.inserted_at
    ) do
      nil -> nil
      datetime -> DateTime.to_iso8601(datetime)
    end
  end

  # ============================================================================
  # Sync Logging
  # ============================================================================

  defp create_sync_log(user_id, operation, resource_id, status) do
    attrs = %{
      user_id: user_id,
      operation: operation,
      resource_id: resource_id,
      status: status,
      metadata: %{}
    }

    %SyncLog{}
    |> SyncLog.changeset(attrs)
    |> Repo.insert()
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp format_errors(errors) when is_list(errors) do
    Enum.map(errors, fn {field, {msg, _}} -> "#{field}: #{msg}" end)
    |> Enum.join(", ")
  end

  defp format_errors(changeset) when is_map(changeset) do
    format_errors(changeset.errors)
  end
end
