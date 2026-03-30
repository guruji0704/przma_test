defmodule AlemWeb.SyncController do
  use AlemWeb, :controller
  require Logger
  alias Alem.Auth

  @sqld_fallback Application.compile_env(:alem, :sqld_url, "http://localhost:8080")

  # ══════════════════════════════════════════════════════════════════════════
  # POST /api/v1/sync/crdt/upload
  # ══════════════════════════════════════════════════════════════════════════

  def crdt_upload(conn, params) do
    # MsgPack XRPC path: file_content is raw binary (serde_bytes bin type).
    # JSON legacy path:  file_content_b64 is base64 string.
    if is_binary(Map.get(params, "file_content")) and
       not match?(%Plug.Upload{}, Map.get(params, "file_content")) do
      crdt_upload_msgpack(conn, params)
    else
      crdt_upload_json(conn, params)
    end
  end

  # ── XRPC MsgPack upload ───────────────────────────────────────────────────
  # File content arrives as raw binary bin in "file_content" (serde_bytes).
  # automerge_state arrives as raw binary bin.
  # arrow_metadata_ipc arrives as raw Arrow IPC streaming bytes (bin).
  # Flow: XRPC MsgPack → LexiconValidator → XRPCController → Domain Actor →
  #       Vault.CASStore → S3  (file bytes, no base64 overhead)
  #       arrow_metadata_ipc → Arrow.Pipeline.load_ipc_stream → Parquet → S3

  defp crdt_upload_msgpack(conn, params) do
    file_bytes = Map.get(params, "file_content")   # already raw binary from rmp-serde
    crdt_state = decode_crdt_bytes(Map.get(params, "automerge_state"))
    arrow_ipc  = Map.get(params, "arrow_metadata_ipc")  # raw Arrow IPC bytes or nil

    Logger.info("[SyncController] MsgPack upload — doc_id=#{Map.get(params, "doc_id")}, " <>
                "filename=#{Map.get(params, "filename")}, " <>
                "content_type=#{Map.get(params, "content_type")}, " <>
                "file_size=#{byte_size(file_bytes)} bytes, " <>
                "arrow_ipc=#{if is_binary(arrow_ipc), do: "#{byte_size(arrow_ipc)} bytes", else: "nil"}")

    with {:ok, user}     <- get_current_user(conn),
         {:ok, doc_id}   <- require_param(params, "doc_id"),
         {:ok, filename} <- require_param(params, "filename")
    do
      user_id      = user.id
      content_type = Map.get(params, "content_type", "application/octet-stream")
      device_id    = Map.get(params, "device_id", "unknown")
      modified_at  = Map.get(params, "last_modified_at", DateTime.utc_now() |> DateTime.to_iso8601())
      epoch_id     = Map.get(params, "epoch_id")
      bucket       = System.get_env("AWS_S3_BUCKET", "perkeep")

      if byte_size(file_bytes) == 0 do
        Logger.error("❌ [MsgPack] Refusing empty file for doc #{doc_id}")
        conn |> put_status(400) |> json(%{error: "Empty file content — nothing to store"})
      else
        case upload_content_to_s3(user_id, doc_id, filename, file_bytes, content_type, bucket) do
          {:ok, s3_key} ->
            Logger.info("✅ [MsgPack S3] #{s3_key} (#{byte_size(file_bytes)} bytes)")

            # ── Arrow IPC (raw bin) → Parquet → S3 ───────────────────────
            # arrow_metadata_ipc is raw IPC bytes from the Rust StreamWriter.
            # load_ipc_stream/1 handles binary directly (no base64 decode needed).
            parquet_key =
              if is_binary(arrow_ipc) and byte_size(arrow_ipc) > 0 do
                case Alem.Arrow.Pipeline.load_ipc_stream(arrow_ipc) do
                  {:ok, df} ->
                    case Alem.Arrow.Pipeline.to_parquet(df) do
                      {:ok, pq_bytes} ->
                        case Alem.Arrow.Pipeline.store_parquet(user_id, df, pq_bytes, doc_id) do
                          {:ok, key} ->
                            Logger.info("✅ [MsgPack Arrow] Parquet shard: #{key}")
                            key
                          {:error, reason} ->
                            Logger.warning("⚠ [MsgPack Arrow] S3 write skipped: #{inspect(reason)}")
                            nil
                        end
                      {:error, reason} ->
                        Logger.warning("⚠ [MsgPack Arrow] Parquet encode failed: #{inspect(reason)}")
                        nil
                    end
                  {:error, reason} ->
                    Logger.warning("⚠ [MsgPack Arrow] IPC decode failed: #{inspect(reason)}")
                    nil
                end
              else
                Logger.info("[MsgPack Arrow] No arrow_metadata_ipc — skipping Parquet shard")
                nil
              end

            case upsert_document_metadata(%{
              id:               doc_id,
              user_id:          user_id,
              filename:         filename,
              automerge_state:  crdt_state,
              s3_content_key:   s3_key,
              device_id:        device_id,
              last_modified_at: modified_at,
              file_size:        byte_size(file_bytes),
              epoch_id:         epoch_id,
              status:           "synced"
            }, @sqld_fallback) do
              :ok ->
                Logger.info("✅ [MsgPack] Complete for '#{filename}'")
                json(conn, %{
                  success:      true,
                  doc_id:       doc_id,
                  s3_key:       s3_key,
                  parquet_key:  parquet_key,
                  file_size:    byte_size(file_bytes),
                  storage_type: "msgpack+arrow+parquet"
                })

              {:error, reason} ->
                Logger.error("❌ [MsgPack] sqld write failed: #{inspect(reason)}")
                conn |> put_status(500) |> json(%{error: "Database write failed"})
            end

          {:error, reason} ->
            Logger.error("❌ [MsgPack] S3 upload failed: #{inspect(reason)}")
            conn |> put_status(500) |> json(%{error: "Storage upload failed: #{inspect(reason)}"})
        end
      end
    else
      {:error, :missing_token}    -> conn |> put_status(401) |> json(%{error: "Missing auth token"})
      {:error, :invalid_token}    -> conn |> put_status(401) |> json(%{error: "Invalid token"})
      {:error, {:missing, field}} -> conn |> put_status(400) |> json(%{error: "Missing required field: #{field}"})
      {:error, reason}            -> conn |> put_status(400) |> json(%{error: inspect(reason)})
    end
  end

  # ── XRPC JSON upload ──────────────────────────────────────────────────────
  # File content arrives as base64 in "file_content_b64".
  # Arrow IPC analytics snapshot is sent separately via the analytics endpoint.
  # Flow: XRPC → LexiconValidator → XRPCController → Domain Actor →
  #       Vault.CASStore → S3  (file content)
  #       Arrow IPC → Arrow→Parquet → S3  (analytics backup, separate path)

  defp crdt_upload_json(conn, params) do
    Logger.info("[SyncController] Legacy JSON upload — doc_id=#{Map.get(params, "doc_id")}, " <>
                "filename=#{Map.get(params, "filename")}, " <>
                "content_type=#{Map.get(params, "content_type")}, " <>
                "file_size=#{Map.get(params, "file_size", "unknown")}")

    with {:ok, user}          <- get_current_user(conn),
         {:ok, doc_id}        <- require_param(params, "doc_id"),
         {:ok, filename}      <- require_param(params, "filename"),
         {:ok, file_bytes}    <- decode_file_content(params),
         {:ok, crdt_state}    <- decode_crdt_state(params)
    do
      user_id      = user.id
      content_type = Map.get(params, "content_type", "application/octet-stream")
      device_id    = Map.get(params, "device_id", "unknown")
      modified_at  = Map.get(params, "last_modified_at", DateTime.utc_now() |> DateTime.to_iso8601())
      bucket       = System.get_env("AWS_S3_BUCKET", "perkeep")

      Logger.info("🔄 [Sync] Uploading '#{filename}' (#{byte_size(file_bytes)} bytes, #{content_type}) from device #{String.slice(device_id, 0, 8)}")

      # Guard: refuse to store an empty file
      if byte_size(file_bytes) == 0 do
        Logger.error("❌ [Sync] Refusing to store empty file for doc #{doc_id}")
        conn
        |> put_status(400)
        |> json(%{error: "Empty file content — nothing to store"})
      else
        case upload_content_to_s3(user_id, doc_id, filename, file_bytes, content_type, bucket) do
          {:ok, s3_key} ->
            Logger.info("✅ [S3] #{s3_key} (#{byte_size(file_bytes)} bytes)")

            # ── Arrow IPC → Parquet → S3 ─────────────────────────────────
            # Every upload now writes a Parquet metadata shard alongside the
            # vault file.  Non-fatal: log and continue even if Parquet fails.
            arrow_ipc_b64 = Map.get(params, "arrow_metadata_ipc", "")
            parquet_key = case Alem.Arrow.Pipeline.ingest(user_id, arrow_ipc_b64, doc_id) do
              {:ok, key}   ->
                Logger.info("✅ [Arrow] Parquet shard: #{key}")
                key
              {:error, reason} ->
                Logger.warning("⚠ [Arrow] Parquet ingest skipped: #{inspect(reason)}")
                nil
            end

            case upsert_document_metadata(%{
              id:               doc_id,
              user_id:          user_id,
              filename:         filename,
              automerge_state:  crdt_state,
              s3_content_key:   s3_key,
              device_id:        device_id,
              last_modified_at: modified_at,
              file_size:        byte_size(file_bytes),
              status:           "synced"
            }, @sqld_fallback) do
              :ok ->
                Logger.info("✅ [Sync] Complete for '#{filename}'")
                json(conn, %{
                  success:      true,
                  doc_id:       doc_id,
                  s3_key:       s3_key,
                  parquet_key:  parquet_key,
                  file_size:    byte_size(file_bytes),
                  storage_type: "arrow+parquet"
                })

              {:error, reason} ->
                Logger.error("❌ [Sync] sqld write failed: #{inspect(reason)}")
                conn |> put_status(500) |> json(%{error: "Database write failed"})
            end

          {:error, reason} ->
            Logger.error("❌ [Sync] S3 upload failed: #{inspect(reason)}")
            conn |> put_status(500) |> json(%{error: "Storage upload failed: #{inspect(reason)}"})
        end
      end
    else
      {:error, :missing_token}    -> conn |> put_status(401) |> json(%{error: "Missing auth token"})
      {:error, :invalid_token}    -> conn |> put_status(401) |> json(%{error: "Invalid token"})
      {:error, {:missing, field}} -> conn |> put_status(400) |> json(%{error: "Missing required field: #{field}"})
      {:error, reason}            -> conn |> put_status(400) |> json(%{error: inspect(reason)})
    end
  end

  # ── Arrow DataFrame column helpers ───────────────────────────────────────

  # Extract the first value from a named column; error if column missing.
  defp extract_column(df, col) do
    try do
      value = df |> Explorer.DataFrame.pull(col) |> Explorer.Series.first()
      if is_nil(value), do: {:error, {:missing_col, col}}, else: {:ok, value}
    rescue
      _ -> {:error, {:missing_col, col}}
    end
  end

  # Extract first value or return default (non-fatal).
  defp extract_column_or(df, col, default) do
    try do
      df |> Explorer.DataFrame.pull(col) |> Explorer.Series.first() || default
    rescue
      _ -> default
    end
  end

  # Decode binary CRDT state bytes (passed as raw binary in MsgPack).
  defp decode_crdt_bytes(nil),   do: <<>>
  defp decode_crdt_bytes(bytes) when is_binary(bytes), do: bytes
  defp decode_crdt_bytes(_),    do: <<>>

  # ══════════════════════════════════════════════════════════════════════════
  # POST /api/v1/sync/crdt/upload_chunk
  #
  # Receives one 4 MB slice of a large file.  The client uploads all chunks
  # in parallel; order does not matter because each chunk carries an index.
  # ══════════════════════════════════════════════════════════════════════════

  # chunk_upload receives JSON body: {doc_id, chunk_index, total_chunks, chunk_data}.
  # chunk_data is base64-encoded binary. Plug.Parsers :json parser handles the body
  # before the router runs, so params always has the full decoded values — no raw
  # body read needed and no multipart/octet-stream timeout issues.
  def chunk_upload(conn, params) do
    with {:ok, _user}        <- get_current_user(conn),
         {:ok, doc_id}       <- require_param(params, "doc_id"),
         {:ok, chunk_index}  <- parse_integer(params, "chunk_index"),
         {:ok, total_chunks} <- parse_integer(params, "total_chunks"),
         {:ok, chunk_b64}    <- require_param(params, "chunk_data"),
         {:ok, chunk_bytes}  <- decode_base64(chunk_b64)
    do
      chunk_dir  = Path.join(System.tmp_dir!(), "przma_chunks/#{doc_id}")
      chunk_path = Path.join(chunk_dir, "#{chunk_index}.bin")

      File.mkdir_p!(chunk_dir)

      case File.write(chunk_path, chunk_bytes) do
        :ok ->
          Logger.info("[Chunk] doc=#{doc_id} chunk #{chunk_index + 1}/#{total_chunks} (#{byte_size(chunk_bytes)} bytes)")
          json(conn, %{success: true, chunk_index: chunk_index})

        {:error, reason} ->
          Logger.error("[Chunk] Write failed: #{inspect(reason)}")
          conn |> put_status(500) |> json(%{error: "Failed to store chunk"})
      end
    else
      {:error, :missing_token}    -> conn |> put_status(401) |> json(%{error: "Missing auth token"})
      {:error, :invalid_token}    -> conn |> put_status(401) |> json(%{error: "Invalid token"})
      {:error, {:missing, field}} -> conn |> put_status(400) |> json(%{error: "Missing: #{field}"})
      {:error, reason}            -> conn |> put_status(400) |> json(%{error: inspect(reason)})
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # POST /api/v1/sync/crdt/finalize_upload
  #
  # Called after ALL chunks have been uploaded.  Assembles them in order,
  # pushes the complete file to S3, records metadata in sqld, then cleans
  # up the temp chunk files.
  # ══════════════════════════════════════════════════════════════════════════

  def finalize_upload(conn, params) do
    with {:ok, user}         <- get_current_user(conn),
         {:ok, doc_id}       <- require_param(params, "doc_id"),
         {:ok, filename}     <- require_param(params, "filename"),
         {:ok, total_chunks} <- parse_integer(params, "total_chunks"),
         {:ok, file_bytes}   <- assemble_chunks(doc_id, total_chunks),
         {:ok, crdt_state}   <- decode_crdt_state(params)
    do
      user_id      = user.id
      content_type = Map.get(params, "content_type", "application/octet-stream")
      device_id    = Map.get(params, "device_id", "unknown")
      modified_at  = Map.get(params, "last_modified_at", DateTime.utc_now() |> DateTime.to_iso8601())
      bucket       = System.get_env("AWS_S3_BUCKET", "perkeep")

      Logger.info("[Finalize] '#{filename}' assembled #{byte_size(file_bytes)} bytes from #{total_chunks} chunks")

      if byte_size(file_bytes) == 0 do
        conn |> put_status(400) |> json(%{error: "Assembled file is empty"})
      else
        case upload_content_to_s3(user_id, doc_id, filename, file_bytes, content_type, bucket) do
          {:ok, s3_key} ->
            # Arrow IPC → Parquet → S3 (same as crdt_upload)
            arrow_ipc_b64 = Map.get(params, "arrow_metadata_ipc", "")
            parquet_key = case Alem.Arrow.Pipeline.ingest(user.id, arrow_ipc_b64, doc_id) do
              {:ok, key}       -> Logger.info("✅ [Arrow] Parquet shard: #{key}"); key
              {:error, reason} -> Logger.warning("⚠ [Arrow] Parquet skipped: #{inspect(reason)}"); nil
            end

            case upsert_document_metadata(%{
              id:               doc_id,
              user_id:          user_id,
              filename:         filename,
              automerge_state:  crdt_state,
              s3_content_key:   s3_key,
              device_id:        device_id,
              last_modified_at: modified_at,
              file_size:        byte_size(file_bytes),
              status:           "synced"
            }, @sqld_fallback) do
              :ok ->
                cleanup_chunks(doc_id)
                Logger.info("[Finalize] ✅ '#{filename}' complete (#{byte_size(file_bytes)} bytes)")
                json(conn, %{
                  success:      true,
                  doc_id:       doc_id,
                  s3_key:       s3_key,
                  parquet_key:  parquet_key,
                  file_size:    byte_size(file_bytes),
                  storage_type: "arrow+parquet+chunked"
                })

              {:error, reason} ->
                Logger.error("[Finalize] sqld write failed: #{inspect(reason)}")
                conn |> put_status(500) |> json(%{error: "Database write failed"})
            end

          {:error, reason} ->
            Logger.error("[Finalize] S3 upload failed: #{inspect(reason)}")
            conn |> put_status(500) |> json(%{error: "Storage upload failed: #{inspect(reason)}"})
        end
      end
    else
      {:error, :missing_token}    -> conn |> put_status(401) |> json(%{error: "Missing auth token"})
      {:error, :invalid_token}    -> conn |> put_status(401) |> json(%{error: "Invalid token"})
      {:error, {:missing, field}} -> conn |> put_status(400) |> json(%{error: "Missing: #{field}"})
      {:error, reason}            -> conn |> put_status(400) |> json(%{error: inspect(reason)})
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # POST /api/v1/sync/upload-url
  #
  # Issues an S3 presigned PUT URL so the client can upload large files
  # directly to S3, bypassing Phoenix entirely (no base64, no buffering).
  #
  # Crucially: the sqld metadata write (status: "uploading") is kicked off
  # in a background Task in parallel with the client's S3 PUT — so by the
  # time upload_document is called, sqld already has the record.
  #
  # Body:    { doc_id, filename, content_type, automerge_state,
  #            device_id, last_modified_at, file_size }
  # Returns: { upload_url, s3_key }
  # ══════════════════════════════════════════════════════════════════════════

  def get_upload_url(conn, params) do
    with {:ok, user}     <- get_current_user(conn),
         {:ok, doc_id}   <- require_param(params, "doc_id"),
         {:ok, filename} <- require_param(params, "filename")
    do
      content_type = Map.get(params, "content_type", "application/octet-stream")
      device_id    = Map.get(params, "device_id", "unknown")
      modified_at  = Map.get(params, "last_modified_at", DateTime.utc_now() |> DateTime.to_iso8601())
      file_size    = Map.get(params, "file_size", 0)
      total_parts  = Map.get(params, "total_parts", 1)
      bucket       = System.get_env("AWS_S3_BUCKET", "perkeep")
      s3_key       = "user/#{user.id}/documents/#{doc_id}/#{filename}"

      Logger.info("[PresignedURL] Initiating multipart upload for '#{filename}' " <>
                  "(#{file_size} bytes, #{total_parts} parts)")

      # Initiate S3 multipart upload — returns an upload_id
      case ExAws.S3.initiate_multipart_upload(bucket, s3_key,
             content_type: content_type
           ) |> ExAws.request() do
        {:ok, %{body: %{upload_id: upload_id}}} ->

          # Generate one presigned PUT URL per part
          # Each URL includes ?partNumber=N&uploadId=UPLOAD_ID in the query string
          part_urls =
            Enum.map(1..total_parts, fn part_number ->
              {:ok, url} =
                ExAws.S3.presigned_url(
                  ExAws.Config.new(:s3), :put, bucket, s3_key,
                  expires_in: 3600,
                  query_params: [
                    {"partNumber", to_string(part_number)},
                    {"uploadId",   upload_id}
                  ]
                )
              url
            end)

          Logger.info("[PresignedURL] #{total_parts} part URLs issued for '#{filename}' upload_id=#{upload_id}")

          # Decode optional CRDT state (non-fatal if absent)
          {:ok, crdt_state} = decode_crdt_state(params)

          # ── Write metadata to sqld IN PARALLEL with the multipart upload ──
          # Task.start is fire-and-forget — response returns immediately.
          # sqld record is ready before the last S3 part finishes uploading.
          sqld_url = @sqld_fallback
          Task.start(fn ->
            case upsert_document_metadata(%{
              id:               doc_id,
              user_id:          user.id,
              filename:         filename,
              automerge_state:  crdt_state,
              s3_content_key:   s3_key,
              device_id:        device_id,
              last_modified_at: modified_at,
              file_size:        file_size,
              status:           "uploading"
            }, sqld_url) do
              :ok ->
                Logger.info("[PresignedURL] sqld metadata written (uploading) for '#{filename}'")
              {:error, reason} ->
                Logger.warning("[PresignedURL] sqld pre-write failed (non-fatal): #{inspect(reason)}")
            end
          end)

          json(conn, %{upload_id: upload_id, part_urls: part_urls, s3_key: s3_key})

        {:error, reason} ->
          Logger.error("[PresignedURL] S3 multipart initiate failed for '#{filename}': #{inspect(reason)}")
          conn |> put_status(500) |> json(%{error: "Could not initiate multipart upload: #{inspect(reason)}"})
      end
    else
      {:error, :missing_token}    -> conn |> put_status(401) |> json(%{error: "Missing auth token"})
      {:error, :invalid_token}    -> conn |> put_status(401) |> json(%{error: "Invalid token"})
      {:error, {:missing, field}} -> conn |> put_status(400) |> json(%{error: "Missing required field: #{field}"})
      {:error, reason}            -> conn |> put_status(400) |> json(%{error: inspect(reason)})
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # POST /api/v1/sync/upload
  #
  # Called AFTER the client's S3 PUT completes.  File bytes never pass
  # through Phoenix — only a tiny metadata JSON payload arrives here.
  # Flips the sqld record status from "uploading" → "synced".
  #
  # Body:    { doc_id, filename, s3_key, content_type, file_size }
  # Returns: { success: true, doc_id, s3_key }
  # ══════════════════════════════════════════════════════════════════════════

  def upload_document(conn, params) do
    with {:ok, user}      <- get_current_user(conn),
         {:ok, doc_id}    <- require_param(params, "doc_id"),
         {:ok, filename}  <- require_param(params, "filename"),
         {:ok, s3_key}    <- require_param(params, "s3_key"),
         {:ok, upload_id} <- require_param(params, "upload_id")
    do
      content_type = Map.get(params, "content_type", "application/octet-stream")
      device_id    = Map.get(params, "device_id", "unknown")
      modified_at  = Map.get(params, "last_modified_at", DateTime.utc_now() |> DateTime.to_iso8601())
      file_size    = Map.get(params, "file_size", 0)
      parts_raw    = Map.get(params, "parts", [])
      epoch_id     = Map.get(params, "epoch_id")  # nil for v1 vault files
      bucket       = System.get_env("AWS_S3_BUCKET", "perkeep")

      Logger.info("[PresignedUpload] Completing multipart for '#{filename}' " <>
                  "(#{length(parts_raw)} parts, upload_id=#{upload_id}, epoch_id=#{inspect(epoch_id)})")

      # Build the parts list S3 requires: [{part_number, etag}, ...]
      # sorted by part_number ascending
      parts =
        parts_raw
        |> Enum.map(fn p -> {p["part_number"], p["etag"]} end)
        |> Enum.sort_by(fn {n, _} -> n end)

      # ── Complete S3 multipart upload ───────────────────────────────────
      case ExAws.S3.complete_multipart_upload(bucket, s3_key, upload_id, parts)
           |> ExAws.request() do
        {:ok, _} ->
          Logger.info("✅ [S3] Multipart complete for '#{filename}' → #{s3_key}")

          # ── Flip sqld status from "uploading" → "synced" ──────────────
          case upsert_document_metadata(%{
            id:               doc_id,
            user_id:          user.id,
            filename:         filename,
            automerge_state:  <<>>,  # already saved during parallel pre-write
            s3_content_key:   s3_key,
            device_id:        device_id,
            last_modified_at: modified_at,
            file_size:        file_size,
            epoch_id:         epoch_id,
            status:           "synced"
          }, @sqld_fallback) do
            :ok ->
              Logger.info("✅ [PresignedUpload] '#{filename}' synced")

              # ── Async CAS extraction (vault v2 only) ──────────────────
              # Fire-and-forget: download vault from S3, decrypt using epoch key,
              # extract content metadata for CAS indexing.
              # Does NOT block the HTTP response — client gets 200 immediately.
              if is_integer(epoch_id) do
                sqld_url = @sqld_fallback
                Task.start(fn ->
                  extract_vault_content_async(doc_id, s3_key, bucket, epoch_id, sqld_url)
                end)
              end

              json(conn, %{success: true, doc_id: doc_id, s3_key: s3_key})

            {:error, reason} ->
              Logger.error("❌ [PresignedUpload] sqld finalise failed: #{inspect(reason)}")
              conn |> put_status(500) |> json(%{error: "Database write failed"})
          end

        {:error, reason} ->
          Logger.error("❌ [S3] CompleteMultipartUpload failed for '#{filename}': #{inspect(reason)}")
          conn |> put_status(500) |> json(%{error: "S3 multipart complete failed: #{inspect(reason)}"})
      end
    else
      {:error, :missing_token}    -> conn |> put_status(401) |> json(%{error: "Missing auth token"})
      {:error, :invalid_token}    -> conn |> put_status(401) |> json(%{error: "Invalid token"})
      {:error, {:missing, field}} -> conn |> put_status(400) |> json(%{error: "Missing required field: #{field}"})
      {:error, reason}            -> conn |> put_status(400) |> json(%{error: inspect(reason)})
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Decode file content from request
  # ══════════════════════════════════════════════════════════════════════════

  # Decode file content — supports three formats in priority order:
  #   1. Multipart part  → %Plug.Upload{} written to a temp file (new, preferred)
  #   2. file_content_b64 → base64 string in JSON body (legacy)
  #   3. text_content     → plain text fallback
  defp decode_file_content(params) do
    case Map.get(params, "file_content") do
      %Plug.Upload{path: tmp_path} ->
        case File.read(tmp_path) do
          {:ok, bytes} ->
            Logger.info("[Decode] multipart → #{byte_size(bytes)} bytes")
            {:ok, bytes}
          {:error, reason} ->
            Logger.error("[Decode] Failed to read multipart temp file: #{inspect(reason)}")
            {:error, :file_read_failed}
        end

      _ ->
        # Legacy: base64 JSON body
        b64  = Map.get(params, "file_content_b64")
        text = Map.get(params, "text_content")

        cond do
          is_binary(b64) and b64 != "" ->
            case Base.decode64(b64) do
              {:ok, bytes} ->
                Logger.info("[Decode] base64 fallback → #{byte_size(bytes)} bytes")
                {:ok, bytes}
              :error ->
                Logger.error("[Decode] Invalid base64 in file_content_b64")
                {:error, :invalid_base64}
            end

          is_binary(text) and text != "" ->
            Logger.info("[Decode] text_content fallback → #{byte_size(text)} bytes")
            {:ok, text}

          true ->
            {:error, :no_file_content}
        end
    end
  end

  defp decode_crdt_state(params) do
    case Map.get(params, "automerge_state") do
      nil                                    -> {:ok, <<>>}
      bin when is_binary(bin) and bin != ""  ->
        # MsgPack path: already raw binary — no base64 decode needed.
        # JSON legacy: treat as base64 string.
        case Base.decode64(bin) do
          {:ok, decoded} -> {:ok, decoded}
          :error         -> {:ok, bin}   # already raw binary from MsgPack
        end
      _                                      -> {:ok, <<>>}
    end
  end

  defp require_param(params, key) do
    case Map.get(params, key) do
      nil -> {:error, {:missing, key}}
      ""  -> {:error, {:missing, key}}
      val -> {:ok, val}
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # S3 Upload
  # ══════════════════════════════════════════════════════════════════════════

  defp upload_content_to_s3(user_id, doc_id, filename, file_bytes, content_type, bucket) do
    s3_key = "user/#{user_id}/documents/#{doc_id}/#{filename}"

    # Use correct content-type header so S3 stores the file correctly
    opts = [content_type: content_type]

    case ExAws.S3.put_object(bucket, s3_key, file_bytes, opts) |> ExAws.request() do
      {:ok, _} ->
        Logger.info("✅ [S3] Stored #{byte_size(file_bytes)} bytes at #{s3_key}")
        {:ok, s3_key}
      {:error, reason} ->
        Logger.error("❌ [S3] Failed #{s3_key}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # sqld: Upsert document metadata + CRDT state
  # ══════════════════════════════════════════════════════════════════════════

  defp upsert_document_metadata(attrs, sqld_url) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    sql = """
    INSERT INTO documents (
      id, user_id, filename, automerge_state, s3_content_key,
      device_id, last_modified_at, file_size, epoch_id, status, inserted_at, updated_at
    )
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      filename         = excluded.filename,
      automerge_state  = excluded.automerge_state,
      s3_content_key   = excluded.s3_content_key,
      device_id        = excluded.device_id,
      last_modified_at = excluded.last_modified_at,
      file_size        = excluded.file_size,
      epoch_id         = excluded.epoch_id,
      status           = excluded.status,
      updated_at       = excluded.updated_at
    """

    args = [
      attrs.id,
      attrs.user_id,
      attrs.filename,
      attrs.automerge_state,
      attrs.s3_content_key,
      attrs.device_id,
      attrs.last_modified_at,
      attrs.file_size,
      Map.get(attrs, :epoch_id),   # nil for v1 vault files
      attrs.status,
      now,
      now
    ]

    sqld_execute(sql, args, sqld_url)
  end

  # ══════════════════════════════════════════════════════════════════════════
  # sqld HTTP client
  # ══════════════════════════════════════════════════════════════════════════

  defp sqld_execute(sql, args, sqld_url) do
    body = Jason.encode!(%{
      requests: [
        %{type: "execute", stmt: %{sql: sql, args: Enum.map(args, &encode_sqld_arg/1)}},
        %{type: "close"}
      ]
    })

    case Req.post("#{sqld_url}/v3/pipeline",
      body: body,
      headers: [{"content-type", "application/json"}],
      receive_timeout: 10_000
    ) do
      {:ok, %{status: 200, body: resp_body}} ->
        # sqld returns 200 even for SQL errors — check inside
        case resp_body do
          %{"results" => [%{"response" => %{"error" => error}} | _]} ->
            Logger.error("[sqld] SQL error: #{inspect(error)}")
            {:error, {:sql_error, error}}
          _ ->
            :ok
        end

      {:ok, %{status: status, body: resp_body}} ->
        Logger.error("[sqld] HTTP #{status}: #{inspect(resp_body)}")
        {:error, {:http, status}}

      {:error, reason} ->
        Logger.error("[sqld] Request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # CAS Content Extraction (vault v2 only)
  #
  # Runs in a background Task after multipart S3 upload completes.
  # Downloads the vault from S3, decrypts using the epoch key, then
  # extracts metadata for content-addressable storage indexing.
  #
  # This is where lexicons, metadata, and perspective analysis will live.
  # The server CAN decrypt because the vault v2 header contains a
  # server_wrapped_key sealed with ECDH(ephemeral, server_epoch_public).
  # ══════════════════════════════════════════════════════════════════════════

  defp extract_vault_content_async(doc_id, s3_key, bucket, epoch_id, sqld_url) do
    Logger.info("[CAS] Starting extraction for doc=#{doc_id} epoch=#{epoch_id}")

    with {:ok, %{body: vault_bytes}} <- ExAws.S3.get_object(bucket, s3_key) |> ExAws.request(),
         {:ok, header}               <- parse_vault_header_v2(vault_bytes),
         {:ok, file_key}             <- Alem.Vault.EpochKeyManager.decrypt_file_key(
                                          epoch_id,
                                          Base.encode64(header.ephemeral_pub),
                                          Base.encode64(header.server_nonce <> header.server_wrapped)
                                        ),
         {:ok, plaintext}            <- decrypt_vault_chunks(vault_bytes, header.chunks_offset, file_key)
    do
      Logger.info("[CAS] ✅ Decrypted #{byte_size(plaintext)} bytes for doc=#{doc_id}")

      # ── Content extraction (extend this for lexicons, embeddings, etc.) ──
      extracted = %{
        byte_size:    byte_size(plaintext),
        sha256:       Base.encode16(:crypto.hash(:sha256, plaintext), case: :lower),
        extracted_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      }

      # Store content hash in sqld for deduplication
      sqld_execute(
        "UPDATE documents SET status = 'indexed' WHERE id = ?",
        [doc_id], sqld_url
      )

      Logger.info("[CAS] ✅ Indexed doc=#{doc_id} sha256=#{extracted.sha256}")
    else
      {:error, reason} ->
        Logger.warning("[CAS] Extraction failed for doc=#{doc_id}: #{inspect(reason)}")
    end
  end

  # Parse vault v2 header from binary.
  # Layout: [4 magic][1 ver=2][8 orig_size][4 epoch_id][32 ephem_pub]
  #         [12 local_nonce][48 local_wrapped][12 server_nonce][48 server_wrapped]
  #         [chunks...]
  defp parse_vault_header_v2(<<
    "ALEM",
    2,
    _orig_size::little-64,
    _epoch_id::little-32,
    ephemeral_pub::binary-32,
    _local_nonce::binary-12,
    _local_wrapped::binary-48,
    server_nonce::binary-12,
    server_wrapped::binary-48,
    _rest::binary
  >> = vault_bytes) do
    {:ok, %{
      ephemeral_pub:  ephemeral_pub,
      server_nonce:   server_nonce,
      server_wrapped: server_wrapped,
      chunks_offset:  169,
      vault_bytes:    vault_bytes,
    }}
  end
  defp parse_vault_header_v2(_), do: {:error, :not_v2_vault}

  # Decrypt all chunks from a v2 vault binary.
  # Chunk format: [4 enc_len LE][12 nonce][enc_len ciphertext+tag]
  defp decrypt_vault_chunks(vault_bytes, offset, file_key) do
    chunks_binary = binary_part(vault_bytes, offset, byte_size(vault_bytes) - offset)
    do_decrypt_chunks(chunks_binary, file_key, [])
  end

  defp do_decrypt_chunks(<<>>, _key, acc) do
    {:ok, IO.iodata_to_binary(Enum.reverse(acc))}
  end

  defp do_decrypt_chunks(<<enc_len::little-32, nonce::binary-12, rest::binary>>, file_key, acc) do
    <<ciphertext::binary-size(enc_len), remainder::binary>> = rest
    data_len = enc_len - 16
    <<data::binary-size(data_len), tag::binary-16>> = ciphertext

    case :crypto.crypto_one_time_aead(:chacha20_poly1305, file_key, nonce, data, "", tag, false) do
      plaintext when is_binary(plaintext) ->
        do_decrypt_chunks(remainder, file_key, [plaintext | acc])
      :error ->
        {:error, :chunk_decrypt_failed}
    end
  end

  defp do_decrypt_chunks(_, _key, _acc), do: {:error, :malformed_chunk}

  defp encode_sqld_arg(nil),                  do: %{"type" => "null",    "value" => nil}
  defp encode_sqld_arg(v) when is_integer(v), do: %{"type" => "integer", "value" => to_string(v)}
  defp encode_sqld_arg(v) when is_binary(v) do
    if String.valid?(v) do
      %{"type" => "text",  "value" => v}
    else
      %{"type" => "blob",  "base64" => Base.encode64(v)}
    end
  end
  defp encode_sqld_arg(v), do: %{"type" => "text", "value" => to_string(v)}

  # ── Chunk helpers ──────────────────────────────────────────────────────────

  defp decode_base64(b64) do
    case Base.decode64(b64) do
      {:ok, bytes} -> {:ok, bytes}
      :error       -> {:error, :invalid_base64}
    end
  end

  # Assemble ordered chunk files → single binary
  defp assemble_chunks(doc_id, total_chunks) do
    chunk_dir = Path.join(System.tmp_dir!(), "przma_chunks/#{doc_id}")

    result =
      Enum.reduce_while(0..(total_chunks - 1), {:ok, []}, fn idx, {:ok, parts} ->
        path = Path.join(chunk_dir, "#{idx}.bin")

        case File.read(path) do
          {:ok, bytes}     -> {:cont, {:ok, [bytes | parts]}}
          {:error, reason} -> {:halt, {:error, {:missing_chunk, idx, reason}}}
        end
      end)

    case result do
      {:ok, parts}     -> {:ok, IO.iodata_to_binary(Enum.reverse(parts))}
      {:error, reason} -> {:error, reason}
    end
  end

  # Remove temp chunk directory after successful finalization
  defp cleanup_chunks(doc_id) do
    chunk_dir = Path.join(System.tmp_dir!(), "przma_chunks/#{doc_id}")
    File.rm_rf(chunk_dir)
    :ok
  end

  # Parse a string or integer param as an integer
  defp parse_integer(params, key) do
    case Map.get(params, key) do
      nil                  -> {:error, {:missing, key}}
      v when is_integer(v) -> {:ok, v}
      v when is_binary(v)  ->
        case Integer.parse(v) do
          {n, ""} -> {:ok, n}
          _       -> {:error, {:invalid_integer, key}}
        end
      _ -> {:error, {:invalid_integer, key}}
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Auth
  # ══════════════════════════════════════════════════════════════════════════

  defp get_current_user(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] ->
        case Auth.verify_token(token) do
          {:ok, user} -> {:ok, user}
          {:error, _} -> {:error, :invalid_token}
        end
      _ ->
        {:error, :missing_token}
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # GET /api/v1/sync/changes?since=<ISO8601>
  #
  # Returns all documents for this user updated after `since`.
  # Each document includes a short-lived presigned S3 download URL.
  # Client uses this to pull files it is missing or that changed remotely.
  # ══════════════════════════════════════════════════════════════════════════

  def get_changes(conn, params) do
    with {:ok, user} <- get_current_user(conn) do
      since  = Map.get(params, "since", "1970-01-01T00:00:00Z")
      bucket = System.get_env("AWS_S3_BUCKET", "perkeep")

      case query_user_documents(user.id, since, @sqld_fallback) do
        {:ok, docs} ->
          docs_with_urls = Enum.map(docs, fn doc ->
            url = case doc["s3_content_key"] do
              nil -> nil
              key ->
                case Alem.Storage.ObjectStore.presigned_download_url(bucket, key, expires_in: 900) do
                  {:ok, u} -> u
                  _        -> nil
                end
            end
            Map.put(doc, "download_url", url)
          end)

          Logger.info("[Sync] get_changes user=#{user.id} since=#{since} → #{length(docs_with_urls)} docs")
          json(conn, %{success: true, changes: docs_with_urls, count: length(docs_with_urls)})

        {:error, reason} ->
          Logger.error("[Sync] get_changes failed: #{inspect(reason)}")
          conn |> put_status(500) |> json(%{error: "Failed to query changes"})
      end
    else
      {:error, :missing_token} -> conn |> put_status(401) |> json(%{error: "Unauthorized"})
      {:error, :invalid_token} -> conn |> put_status(401) |> json(%{error: "Invalid token"})
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # POST /api/v1/sync/apply
  #
  # Client sends { doc_ids: ["id1","id2",...] } — the IDs it already has.
  # Server returns docs the client is MISSING with presigned download URLs.
  # ══════════════════════════════════════════════════════════════════════════

  def apply_changes(conn, params) do
    with {:ok, user} <- get_current_user(conn) do
      client_ids = Map.get(params, "doc_ids", [])
      bucket     = System.get_env("AWS_S3_BUCKET", "perkeep")

      case query_user_documents(user.id, "1970-01-01T00:00:00Z", @sqld_fallback) do
        {:ok, all_docs} ->
          missing = Enum.filter(all_docs, fn doc ->
            doc["id"] not in client_ids
          end)

          missing_with_urls = Enum.map(missing, fn doc ->
            url = case doc["s3_content_key"] do
              nil -> nil
              key ->
                case Alem.Storage.ObjectStore.presigned_download_url(bucket, key, expires_in: 900) do
                  {:ok, u} -> u
                  _        -> nil
                end
            end
            Map.put(doc, "download_url", url)
          end)

          Logger.info("[Sync] apply_changes user=#{user.id} client_has=#{length(client_ids)} missing=#{length(missing_with_urls)}")
          json(conn, %{success: true, missing: missing_with_urls, count: length(missing_with_urls)})

        {:error, reason} ->
          Logger.error("[Sync] apply_changes failed: #{inspect(reason)}")
          conn |> put_status(500) |> json(%{error: "Failed to compute diff"})
      end
    else
      {:error, :missing_token} -> conn |> put_status(401) |> json(%{error: "Unauthorized"})
      {:error, :invalid_token} -> conn |> put_status(401) |> json(%{error: "Invalid token"})
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # GET /api/v1/sync/stats
  #
  # Returns aggregate counts and byte totals for the user's vault.
  # ══════════════════════════════════════════════════════════════════════════

  def get_stats(conn, _params) do
    with {:ok, user} <- get_current_user(conn) do
      case query_user_documents(user.id, "1970-01-01T00:00:00Z", @sqld_fallback) do
        {:ok, docs} ->
          total_bytes = Enum.reduce(docs, 0, fn d, acc -> acc + (d["file_size"] || 0) end)
          synced      = Enum.count(docs, fn d -> d["status"] == "synced" end)
          indexed     = Enum.count(docs, fn d -> d["status"] == "indexed" end)
          pending     = length(docs) - synced - indexed

          json(conn, %{
            success:          true,
            total_files:      length(docs),
            total_size_bytes: total_bytes,
            synced:           synced,
            indexed:          indexed,
            pending:          pending
          })

        {:error, reason} ->
          conn |> put_status(500) |> json(%{error: "Stats query failed: #{inspect(reason)}"})
      end
    else
      {:error, :missing_token} -> conn |> put_status(401) |> json(%{error: "Unauthorized"})
      {:error, :invalid_token} -> conn |> put_status(401) |> json(%{error: "Invalid token"})
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # GET /api/v1/sync/download/:doc_id
  #
  # Returns a presigned S3 download URL for the given document.
  # Client uses the URL to fetch the encrypted vault file directly from S3.
  # ══════════════════════════════════════════════════════════════════════════

  def download_file(conn, %{"doc_id" => doc_id}) do
    with {:ok, user} <- get_current_user(conn) do
      bucket = System.get_env("AWS_S3_BUCKET", "perkeep")

      case query_document_by_id(user.id, doc_id, @sqld_fallback) do
        {:ok, nil} ->
          conn |> put_status(404) |> json(%{error: "Document not found"})

        {:ok, doc} ->
          case doc["s3_content_key"] do
            nil ->
              conn |> put_status(404) |> json(%{error: "No S3 key for this document"})

            s3_key ->
              case Alem.Storage.ObjectStore.presigned_download_url(bucket, s3_key, expires_in: 900) do
                {:ok, url} ->
                  Logger.info("[Sync] download_file doc=#{doc_id} → presigned URL (15min)")
                  json(conn, %{
                    success:      true,
                    doc_id:       doc_id,
                    filename:     doc["filename"],
                    file_size:    doc["file_size"],
                    content_type: doc["content_type"],
                    download_url: url,
                    expires_in:   900
                  })

                {:error, reason} ->
                  Logger.error("[Sync] presigned URL failed: #{inspect(reason)}")
                  conn |> put_status(500) |> json(%{error: "Could not generate download URL"})
              end
          end

        {:error, reason} ->
          Logger.error("[Sync] download_file query failed: #{inspect(reason)}")
          conn |> put_status(500) |> json(%{error: "Database query failed"})
      end
    else
      {:error, :missing_token} -> conn |> put_status(401) |> json(%{error: "Unauthorized"})
      {:error, :invalid_token} -> conn |> put_status(401) |> json(%{error: "Invalid token"})
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # GET /api/v1/sync/stream
  #
  # Server-Sent Events (SSE) endpoint.
  # Client connects once; server pushes events as files change.
  # Event types: file_uploaded | file_deleted | sync_complete | ping
  # ══════════════════════════════════════════════════════════════════════════

  def event_stream(conn, _params) do
    with {:ok, _user} <- get_current_user(conn) do
      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> put_resp_header("x-accel-buffering", "no")
        |> send_chunked(200)

      # Send initial ping so client knows the stream is alive
      {:ok, conn} = chunk(conn, "event: ping\ndata: {\"ts\":\"#{DateTime.utc_now() |> DateTime.to_iso8601()}\"}\n\n")

      # Register this connection with the PubSub registry
      Phoenix.PubSub.subscribe(Alem.PubSub, "sync:events")

      stream_loop(conn)
    else
      {:error, _} -> conn |> put_status(401) |> json(%{error: "Unauthorized"})
    end
  end

  defp stream_loop(conn) do
    receive do
      {:sync_event, event_type, payload} ->
        data = Jason.encode!(payload)
        case chunk(conn, "event: #{event_type}\ndata: #{data}\n\n") do
          {:ok, conn} -> stream_loop(conn)
          {:error, _} -> conn  # client disconnected
        end

      :ping ->
        ts = DateTime.utc_now() |> DateTime.to_iso8601()
        case chunk(conn, "event: ping\ndata: {\"ts\":\"#{ts}\"}\n\n") do
          {:ok, conn} -> stream_loop(conn)
          {:error, _} -> conn
        end

    after
      # Send keepalive ping every 25 seconds to prevent proxy timeouts
      25_000 ->
        ts = DateTime.utc_now() |> DateTime.to_iso8601()
        case chunk(conn, "event: ping\ndata: {\"ts\":\"#{ts}\"}\n\n") do
          {:ok, conn} -> stream_loop(conn)
          {:error, _} -> conn
        end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # sqld: Query a single document by id (scoped to user)
  # ══════════════════════════════════════════════════════════════════════════

  defp query_document_by_id(user_id, doc_id, sqld_url) do
    sql = """
    SELECT id, filename, content_type, file_size, s3_content_key,
           status, last_modified_at, updated_at, epoch_id
    FROM documents
    WHERE user_id = ? AND id = ?
    LIMIT 1
    """

    body = Jason.encode!(%{
      requests: [
        %{type: "execute", stmt: %{sql: sql, args: [
          encode_sqld_arg(user_id),
          encode_sqld_arg(doc_id)
        ]}},
        %{type: "close"}
      ]
    })

    case Req.post("#{sqld_url}/v3/pipeline",
      body: body,
      headers: [{"content-type", "application/json"}],
      receive_timeout: 10_000
    ) do
      {:ok, %{status: 200, body: %{"results" => [%{"response" => %{"result" => result}} | _]}}} ->
        cols = Enum.map(result["cols"], & &1["name"])
        rows = Enum.map(result["rows"], fn row ->
          row
          |> Enum.map(fn cell -> cell["value"] end)
          |> then(fn vals -> Enum.zip(cols, vals) |> Map.new() end)
        end)
        {:ok, List.first(rows)}

      {:ok, %{status: 200, body: %{"results" => [%{"response" => %{"error" => err}} | _]}}} ->
        {:error, {:sql_error, err}}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # sqld: Query documents for a user updated after a given timestamp
  # ══════════════════════════════════════════════════════════════════════════

  defp query_user_documents(user_id, since, sqld_url) do
    sql = """
    SELECT id, filename, content_type, file_size, s3_content_key,
           status, last_modified_at, updated_at, epoch_id
    FROM documents
    WHERE user_id = ? AND updated_at >= ?
    ORDER BY updated_at DESC
    LIMIT 500
    """

    body = Jason.encode!(%{
      requests: [
        %{type: "execute", stmt: %{sql: sql, args: [
          encode_sqld_arg(user_id),
          encode_sqld_arg(since)
        ]}},
        %{type: "close"}
      ]
    })

    case Req.post("#{sqld_url}/v3/pipeline",
      body: body,
      headers: [{"content-type", "application/json"}],
      receive_timeout: 10_000
    ) do
      {:ok, %{status: 200, body: %{"results" => [%{"response" => %{"result" => result}} | _]}}} ->
        cols = Enum.map(result["cols"], & &1["name"])
        rows = Enum.map(result["rows"], fn row ->
          row
          |> Enum.map(fn cell -> cell["value"] end)
          |> then(fn vals -> Enum.zip(cols, vals) |> Map.new() end)
        end)
        {:ok, rows}

      {:ok, %{status: 200, body: %{"results" => [%{"response" => %{"error" => err}} | _]}}} ->
        {:error, {:sql_error, err}}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
