defmodule Alem.Sync.ConflictResolver do
  @moduledoc """
  CRDT-based conflict resolution for document synchronization.

  Uses Last-Write-Wins (LWW) strategy with vector clocks.
  """

  require Logger

  @doc """
  Resolve conflicts between existing server document and incoming client data.

  Strategy:
  - Last-Write-Wins (LWW) for most fields
  - Metadata is merged (union)
  - Content hash determines if content changed
  """
  def resolve_document_conflict(existing_doc, incoming_data) do
    Logger.info("[ConflictResolver] Resolving conflict for document #{existing_doc.id}")

    existing_updated = existing_doc.updated_at
    incoming_updated = parse_datetime(incoming_data["updated_at"])

    # Compare timestamps - newer wins
    winner = if DateTime.compare(incoming_updated, existing_updated) == :gt do
      :incoming
    else
      :existing
    end

    resolved_attrs = case winner do
      :incoming ->
        Logger.info("[ConflictResolver] Incoming data is newer - using client version")
        %{
          filename: incoming_data["filename"] || existing_doc.filename,
          content_type: incoming_data["content_type"] || existing_doc.content_type,
          object_key: incoming_data["object_key"] || existing_doc.object_key,
          content_hash: incoming_data["content_hash"] || existing_doc.content_hash,
          text_content: incoming_data["text_content"] || existing_doc.text_content,
          metadata: merge_metadata(existing_doc.metadata, incoming_data["metadata"]),
          status: incoming_data["status"] || existing_doc.status,
          updated_at: incoming_updated
        }

      :existing ->
        Logger.info("[ConflictResolver] Existing data is newer - keeping server version")
        %{
          # Keep existing but merge metadata
          metadata: merge_metadata(existing_doc.metadata, incoming_data["metadata"]),
          updated_at: existing_updated
        }
    end

    resolved_attrs
  end

  @doc "Merge metadata maps using union strategy"
  def merge_metadata(existing_meta, incoming_meta) when is_map(existing_meta) and is_map(incoming_meta) do
    Map.merge(existing_meta, incoming_meta, fn _key, v1, v2 ->
      # For conflicts within metadata, prefer newer (incoming)
      v2 || v1
    end)
  end

  def merge_metadata(existing_meta, nil), do: existing_meta
  def merge_metadata(nil, incoming_meta), do: incoming_meta
  def merge_metadata(_existing, _incoming), do: %{}

  defp parse_datetime(nil), do: DateTime.utc_now()
  defp parse_datetime(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end
  defp parse_datetime(_), do: DateTime.utc_now()
end
