defmodule Alem.Sync.ChangeTracker do
  @moduledoc """
  Track changes across sync sessions for efficient delta synchronization.
  """

  require Logger
  import Ecto.Query
  alias Alem.{Repo, Schemas.Document}

  @doc "Get all changes for a user since a timestamp"
  def get_changes_since(user_id, since_timestamp, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)

    {:ok, since_dt, _} = DateTime.from_iso8601(since_timestamp)

    changes = Repo.all(
      from d in Document,
      where: d.user_id == ^user_id,
      where: d.updated_at > ^since_dt,
      order_by: [asc: d.updated_at],
      limit: ^limit,
      offset: ^offset
    )

    Logger.info("[ChangeTracker] Found #{length(changes)} changes for user #{user_id} since #{since_timestamp}")

    Enum.map(changes, &document_to_change/1)
  end

  @doc "Get changes by document IDs"
  def get_changes_by_ids(user_id, document_ids) do
    Repo.all(
      from d in Document,
      where: d.user_id == ^user_id,
      where: d.id in ^document_ids
    )
    |> Enum.map(&document_to_change/1)
  end

  @doc "Track a new change"
  def track_change(user_id, change_type, resource_id, metadata \\ %{}) do
    Logger.info("[ChangeTracker] Tracking change: #{change_type} for #{resource_id}")

    # In a more advanced system, you'd store this in a dedicated changes table
    # For now, we rely on document.updated_at timestamps
    {:ok, %{
      user_id: user_id,
      change_type: change_type,
      resource_id: resource_id,
      metadata: metadata,
      timestamp: DateTime.utc_now()
    }}
  end

  defp document_to_change(doc) do
    %{
      type: determine_change_type(doc),
      id: doc.id,
      timestamp: DateTime.to_iso8601(doc.updated_at),
      data: serialize_document(doc)
    }
  end

  defp determine_change_type(doc) do
    cond do
      doc.status == "deleted" -> "delete_document"
      DateTime.diff(doc.updated_at, doc.inserted_at, :second) < 1 -> "create_document"
      true -> "update_document"
    end
  end

  defp serialize_document(doc) do
    %{
      id: doc.id,
      filename: doc.filename,
      content_type: doc.content_type,
      object_key: doc.object_key,
      content_hash: doc.content_hash,
      text_content: doc.text_content,
      metadata: doc.metadata,
      status: doc.status,
      file_size: doc.file_size,
      created_at: DateTime.to_iso8601(doc.inserted_at),
      updated_at: DateTime.to_iso8601(doc.updated_at)
    }
  end
end
