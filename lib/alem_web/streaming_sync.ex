defmodule AlemWeb.StreamingSync do
  @moduledoc """
  Handles streaming MessagePack uploads containing Arrow RecordBatches.
  Used for 1GB+ files to maintain a constant, low RAM footprint.
  """

  require Logger
  alias Plug.Conn

  @doc """
  Main entry point for a streaming sync request.
  Consumes the request body as a stream of MessagePack objects.
  """
  def handle_stream(conn) do
    Logger.info("[StreamingSync] Starting stream handler")
    
    # Initialize the decoder state
    # We will use Msgpax.Unpacker to decode objects from the chunked input
    try do
      {:ok, result, conn} = run_protocol(conn)
      
      conn
      |> Plug.Conn.put_status(200)
      |> Phoenix.Controller.json(%{status: "ok", message: result})
    rescue
      e ->
        Logger.error("[StreamingSync] Critical failure: #{inspect(e)}")
        conn |> Plug.Conn.send_resp(500, "Internal Server Error during streaming")
    end
  end

  defp run_protocol(conn) do
    # 1. READ ROUTING & ANALYTICS METADATA
    # We start with an empty buffer
    {:ok, routing_meta, buffer, conn} = read_next_object(<<>>, conn)
    Logger.info("[StreamingSync] Received Routing Meta: #{inspect(routing_meta)}")

    {:ok, analytics_ipc, buffer, conn} = read_next_object(buffer, conn)
    Logger.info("[StreamingSync] Received Analytics Arrow Batch: #{byte_size(analytics_ipc)} bytes")

    user_id = routing_meta["user_id"]
    doc_id = routing_meta["doc_id"]
    filename = routing_meta["filename"]
    content_type = routing_meta["content_type"] || "application/octet-stream"
    bucket = routing_meta["bucket"] || "perkeep"

    # Process Analytics in the background (Track B)
    # We pass the IPC binary to the MetadataStore to be saved as Parquet
    Task.start(fn -> 
      Alem.Analytics.MetadataStore.ingest(analytics_ipc, user_id, doc_id)
    end)

    # Start S3 Multipart for the raw file
    upload_id = initiate_s3_upload(bucket, user_id, doc_id, filename, content_type)

    # 2. READ PAYLOAD (Arrow Batches)
    # This now uses pipelining: we start uploading part N while downloading part N+1
    {:ok, upload_tasks, _buffer, conn} = process_chunks(buffer, conn, bucket, user_id, doc_id, filename, upload_id, 1, [])

    # 3. COMPLETE S3 (Wait for all pending uploads)
    Logger.info("[StreamingSync] Waiting for #{length(upload_tasks)} parts to finish uploading to S3...")
    
    parts_list = 
      upload_tasks
      |> Enum.map(fn task -> Task.await(task, 600_000) end)
      |> Enum.sort_by(fn {num, _etag} -> num end)

    ExAws.S3.complete_multipart_upload(bucket, "user/#{user_id}/documents/#{doc_id}/#{filename}", upload_id, parts_list)
    |> ExAws.request!(virtual_host: false)

    {:ok, "Uploaded #{length(parts_list)} segments successfully", conn}
  end

  defp read_next_object(buffer, conn) do
    case Msgpax.unpack_slice(buffer) do
      {:ok, object, rest} ->
        {:ok, object, rest, conn}
      
      {:error, %Msgpax.UnpackError{reason: :incomplete}} ->
        # We need more data. Use a larger read buffer (6MB) to capture 5MB chunks efficiently.
        case Conn.read_body(conn, length: 6_000_000) do
          {:ok, new_binary, conn} -> 
            read_next_object(buffer <> new_binary, conn)
          {:more, new_binary, conn} -> 
            read_next_object(buffer <> new_binary, conn)
          {:error, reason} -> 
            throw({:connectivity_error, reason})
        end

      {:error, reason} ->
        throw({:decode_error, reason})
    end
  end

  defp process_chunks(buffer, conn, bucket, user_id, doc_id, filename, upload_id, part_num, tasks) do
    case read_next_object(buffer, conn) do
      {:ok, %{"type" => "sync_footer"} = sync_info, rest, conn} ->
        # We finished the chunks and hit the footer
        Logger.info("[StreamingSync] Received Footer: #{inspect(sync_info)}")
        {:ok, Enum.reverse(tasks), rest, conn}

      {:ok, binary_batch, rest, conn} when is_binary(binary_batch) ->
        # PIPELINING: Start S3 upload in the background
        key = "user/#{user_id}/documents/#{doc_id}/#{filename}"
        
        # Capture the current part number
        current_part = part_num
        
        task = Task.async(fn -> 
          res = ExAws.S3.upload_part(bucket, key, upload_id, current_part, binary_batch)
                |> ExAws.request!(virtual_host: false)
          
          etag = res.headers |> Enum.find_value(fn {k, v} -> if String.downcase(k) == "etag", do: v end)
          {current_part, etag}
        end)
        
        process_chunks(rest, conn, bucket, user_id, doc_id, filename, upload_id, part_num + 1, [task | tasks])
      
      {:ok, other, _rest, _conn} ->
        Logger.error("[StreamingSync] Unexpected object in stream: #{inspect(other)}")
        throw({:protocol_error, "Expected binary chunk, got #{inspect(other)}"})
    end
  end

  defp initiate_s3_upload(bucket, user_id, doc_id, filename, content_type) do
    key = "user/#{user_id}/documents/#{doc_id}/#{filename}"
    res = ExAws.S3.initiate_multipart_upload(bucket, key, content_type: content_type)
          |> ExAws.request!(virtual_host: false)
    res.body.upload_id
  end
end
