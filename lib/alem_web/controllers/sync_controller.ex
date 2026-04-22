defmodule AlemWeb.SyncController do
  use AlemWeb, :controller
  require Logger
  alias Alem.Auth
  alias Alem.DID
  alias Alem.Namespace.Manager


  # ══════════════════════════════════════════════════════════════════════════
  # V1 SYNC (Legacy / Single-Part)
  # ══════════════════════════════════════════════════════════════════════════

  def crdt_upload(conn, params) do
    content_type = get_req_header(conn, "content-type") |> List.first()

    case content_type do
      "application/x-msgpack-stream" ->
        AlemWeb.StreamingSync.handle_stream(conn)

      _ ->
        file_content = Map.get(params, "file_content")

        if is_binary(file_content) and not match?(%Plug.Upload{}, file_content) do
          crdt_upload_msgpack(conn, params)
        else
          crdt_upload_json(conn, params)
        end
    end
  end

  defp crdt_upload_msgpack(conn, params) do
    file_bytes = normalize_binary(Map.get(params, "file_content"))
    crdt_state = decode_crdt_state(params)
    arrow_ipc = normalize_binary(Map.get(params, "arrow_metadata_ipc"))

    with {:ok, user} <- get_current_user(conn),
         {:ok, doc_id} <- require_param(params, "doc_id"),
         {:ok, filename} <- require_param(params, "filename") do
      user_id = user.id
      content_type = Map.get(params, "content_type", "application/octet-stream")
      bucket = get_s3_bucket()

      if byte_size(file_bytes) == 0 do
        conn |> put_status(400) |> json(%{error: "Empty file content"})
      else
        case upload_content_to_s3(user_id, doc_id, filename, file_bytes, content_type, bucket) do
          {:ok, s3_key} ->
            # Optional Arrow metadata ingest
            if is_binary(arrow_ipc) and byte_size(arrow_ipc) > 0 do
              Task.start(fn -> Alem.Analytics.MetadataStore.ingest(arrow_ipc, user_id, doc_id) end)
            end

            upsert_document_metadata(%{
              id: doc_id,
              user_id: user_id,
              filename: filename,
              automerge_state: crdt_state,
              s3_content_key: s3_key,
              device_id: Map.get(params, "device_id", "unknown"),
              last_modified_at: Map.get(params, "last_modified_at", ""),
              file_size: byte_size(file_bytes),
              status: "synced"
            }, @sqld_fallback)

            json(conn, %{success: true, doc_id: doc_id, s3_key: s3_key})

          {:error, reason} ->
            conn |> put_status(500) |> json(%{error: "S3 failed: #{inspect(reason)}"})
        end
      end
    end
  end

  defp crdt_upload_json(conn, params) do
    with {:ok, user} <- get_current_user(conn),
         {:ok, doc_id} <- require_param(params, "doc_id"),
         {:ok, filename} <- require_param(params, "filename"),
         {:ok, file_bytes} <- decode_file_content(params),
         {:ok, crdt_state} <- decode_crdt_state(params) do
      bucket = get_s3_bucket()

      case upload_content_to_s3(user.id, doc_id, filename, file_bytes, "application/octet-stream", bucket) do
        {:ok, s3_key} ->
          upsert_document_metadata(%{
            id: doc_id,
            user_id: user.id,
            filename: filename,
            automerge_state: crdt_state,
            s3_content_key: s3_key,
            device_id: Map.get(params, "device_id", "unknown"),
            last_modified_at: Map.get(params, "last_modified_at", ""),
            file_size: byte_size(file_bytes),
            status: "synced"
          }, @sqld_fallback)

          json(conn, %{success: true, s3_key: s3_key})
        {:error, _} -> conn |> put_status(500) |> json(%{error: "Upload failed"})
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # V2 PARALLEL SYNC (Direct S3 / High Performance)
  # ══════════════════════════════════════════════════════════════════════════

  def v2_initiate(conn, params) do
    with {:ok, user}     <- get_current_user(conn),
         {:ok, doc_id}   <- require_param(params, "doc_id"),
         {:ok, filename} <- require_param(params, "filename")
    do
      # Derive Namespace key from DID (v3.1)
      did_id = user.did_id || Alem.DID.generate(user.id)
      namespace_key = Alem.DID.namespace_key(did_id)
      Alem.Namespace.Manager.start(user.id, namespace_key, [did: did_id])

      content_type = Map.get(params, "content_type", "application/octet-stream")
      bucket       = get_s3_bucket()
      s3_key       = "user/#{namespace_key}/documents/#{doc_id}/#{filename}"

      case ExAws.S3.initiate_multipart_upload(bucket, s3_key, content_type: content_type)
           |> ExAws.request(virtual_host: false) do
        {:ok, %{body: %{upload_id: upload_id}}} ->
          # Metadata Ingest (Arrow)
          arrow_ipc = normalize_binary(Map.get(params, "arrow_metadata_ipc"))
          if is_binary(arrow_ipc) and byte_size(arrow_ipc) > 0 do
            Logger.info("[Sync] Detected Arrow IPC metadata (#{byte_size(arrow_ipc)} bytes) — triggering analytics ingest.")
            Task.start(fn -> Alem.Analytics.MetadataStore.ingest(arrow_ipc, user.id, doc_id) end)
          end

          json(conn, %{success: true, upload_id: upload_id, s3_key: s3_key, namespace_key: namespace_key})

        {:error, reason} ->
          conn |> put_status(500) |> json(%{error: "S3 failed: #{inspect(reason)}"})
      end
    end
  end

  def v2_upload_part(conn, params) do
    with {:ok, user}      <- get_current_user(conn),
         {:ok, upload_id} <- require_param(params, "upload_id"),
         {:ok, doc_id}    <- require_param(params, "doc_id"),
         {:ok, part_num}  <- parse_integer(params, "part_num")
    do
      case read_full_body(conn, <<>>) do
        {:ok, binary, conn} ->
          bucket   = get_s3_bucket()
          filename = Map.get(params, "filename", "unknown")
          namespace_key = Alem.DID.namespace_key(user.did_id || Alem.DID.generate(user.id))
          s3_key   = "user/#{namespace_key}/documents/#{doc_id}/#{filename}"

          case ExAws.S3.upload_part(bucket, s3_key, upload_id, part_num, binary)
               |> ExAws.request(virtual_host: false) do
            {:ok, res} ->
              etag = res.headers |> Enum.find_value(fn {k, v} -> if String.downcase(k) == "etag", do: v end)
              json(conn, %{success: true, etag: etag, part_num: part_num})
            {:error, _} -> conn |> put_status(500) |> json(%{error: "UploadPart failed"})
          end
        {:error, _} -> conn |> put_status(400) |> json(%{error: "Body read failed"})
      end
    end
  end

  def v2_complete(conn, params) do
    with {:ok, user}      <- get_current_user(conn),
         {:ok, doc_id}    <- require_param(params, "doc_id"),
         {:ok, upload_id} <- require_param(params, "upload_id"),
         {:ok, filename}  <- require_param(params, "filename"),
         {:ok, parts_raw} <- require_param(params, "parts")
    do
      namespace_key = Alem.DID.namespace_key(user.did_id || Alem.DID.generate(user.id))
      bucket = get_s3_bucket()
      s3_key = "user/#{namespace_key}/documents/#{doc_id}/#{filename}"

      parts = parts_raw
        |> Enum.map(fn p -> {p["part_num"], p["etag"]} end)
        |> Enum.sort_by(fn {n, _} -> n end)

      case ExAws.S3.complete_multipart_upload(bucket, s3_key, upload_id, parts)
           |> ExAws.request(virtual_host: false) do
        {:ok, _} ->
          # Process metadata and CAS in a single background task to ensure ordering
          epoch_id = Map.get(params, "epoch_id")
          ctx = %{
            user_id: user.id,
            namespace_key: user.id, # Postgres PK
            actor_did: user.did_id,
            device_id: Map.get(params, "device_id", "unknown"),
            filename: filename
          }

          Task.start(fn ->
            # 1. Update metadata in both SQLD and Postgres
            upsert_document_metadata(%{
              id: doc_id, user_id: user.id, filename: filename, s3_content_key: s3_key,
              status: "synced", automerge_state: <<>>, device_id: ctx.device_id,
              last_modified_at: Map.get(params, "last_modified_at", ""),
              file_size: Map.get(params, "file_size", 0),
              epoch_id: epoch_id
            }, @sqld_fallback)

            # 2. Trigger CAS extraction if applicable
            if is_integer(epoch_id) do
              extract_vault_content_async(doc_id, s3_key, bucket, epoch_id, @sqld_fallback, ctx)
            else
              Logger.warning("[CAS] Skipping extraction for doc=#{doc_id}: Vault V1 (No Epoch ID)")
              
              # Record skipped activity
              {:ok, activity} = Alem.Cas.create_activity(%{
                tenant_id: "default",
                namespace_key: ctx.namespace_key,
                actor_did: ctx.actor_did,
                user_id: ctx.user_id,
                verb: "Sync",
                object_type: "document",
                object_id: doc_id,
                object_path: s3_key,
                device_id: ctx.device_id
              })

              Alem.Cas.create_event(%{
                tenant_id: "default",
                namespace_key: ctx.namespace_key,
                actor_did: ctx.actor_did,
                activity_id: activity.activity_id,
                event_category: "sync",
                event_type: "sync.skipped",
                is_success: false,
                metadata: %{reason: "Vault V1 (E2EE only)"}
              })
            end

            # 3. Notify other devices via SSE (Real-Time Instant Sync)
            broadcast_sync_nudge(user.id, doc_id, filename)
          end)

          json(conn, %{success: true, s3_key: s3_key})

        {:error, _} -> conn |> put_status(500) |> json(%{error: "Completion failed"})
      end
    end
  end

  # ── SSE Instant Sync Stream (Phase 4) ──────────────────────────────────

  def event_stream(conn, _params) do
    with {:ok, user} <- get_current_user(conn) do
      conn =
        conn
        |> put_resp_header("content-type", "text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> put_resp_header("x-accel-buffering", "no")
        |> send_chunked(200)

      # Subscribe to the user's sync topic
      topic = "sync:#{user.id}"
      Phoenix.PubSub.subscribe(Alem.PubSub, topic)
      Logger.info("[SSE] User #{user.id} connected for instant sync.")

      # Send initial keep-alive
      {:ok, conn} = chunk(conn, "event: initial\ndata: connected\n\n")

      sse_loop(conn, user.id, topic)
    end
  end

  defp sse_loop(conn, user_id, topic) do
    receive do
      {:sync_nudge, data} ->
        case chunk(conn, "event: sync_nudge\ndata: #{Jason.encode!(data)}\n\n") do
          {:ok, conn} -> sse_loop(conn, user_id, topic)
          {:error, :closed} -> 
            Logger.info("[SSE] User #{user_id} disconnected.")
            conn
        end
    after
      30_000 ->
        # Keep-alive heartbeat
        case chunk(conn, ": heartbeat\n\n") do
          {:ok, conn} -> sse_loop(conn, user_id, topic)
          {:error, :closed} -> conn
        end
    end
  end

  defp broadcast_sync_nudge(user_id, doc_id, filename) do
    topic = "sync:#{user_id}"
    msg = %{doc_id: doc_id, filename: filename, ts: DateTime.utc_now()}
    Phoenix.PubSub.broadcast(Alem.PubSub, topic, {:sync_nudge, msg})
    Logger.info("[PubSub] Broadcasted sync nudge to #{topic}")
  end

  # ══════════════════════════════════════════════════════════════════════════
  # METADATA & UTILS
  # ══════════════════════════════════════════════════════════════════════════

  def get_stats(conn, _params) do
    # ... stats logic ...
    json(conn, %{success: true})
  end

  def get_changes(conn, params) do
    with {:ok, user} <- get_current_user(conn) do
      since = Map.get(params, "since", "1970-01-01T00:00:00Z")
      case query_user_documents(user.id, since, @sqld_fallback) do
        {:ok, docs} -> json(conn, %{success: true, changes: docs})
        {:error, _} -> conn |> put_status(500) |> json(%{error: "Query failed"})
      end
    end
  end

  defp query_user_documents(user_id, since, _sqld_url) do
    case Alem.LanceDB.query("documents", "user_id = '#{user_id}' AND updated_at >= '#{since}'", 1000) do
      json_str when is_binary(json_str) ->
        case Jason.decode(json_str) do
          {:ok, rows} -> {:ok, rows}
          {:error, _} -> {:error, :parse_failed}
        end
      _ -> {:error, :lancedb_failed}
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # HELPERS
  # ══════════════════════════════════════════════════════════════════════════

  def extract_vault_content_async(doc_id, s3_key, bucket, epoch_id, sqld_url, ctx) do
    Logger.info("[CAS] Starting extraction for doc=#{doc_id} using epoch=#{epoch_id}")
    tenant_id = "default"
    
    {:ok, activity} = Alem.Cas.create_activity(%{
      tenant_id: tenant_id,
      namespace_key: ctx.namespace_key,
      actor_did: ctx.actor_did,
      user_id: ctx.user_id,
      verb: "Sync",
      object_type: "document",
      object_id: doc_id,
      object_path: s3_key,
      device_id: ctx.device_id
    })

    record_event = fn type, success, meta ->
      Alem.Cas.create_event(%{
        tenant_id: tenant_id,
        namespace_key: ctx.namespace_key,
        actor_did: ctx.actor_did,
        activity_id: activity.activity_id,
        event_category: "sync",
        event_type: type,
        is_success: success,
        metadata: meta
      })
    end

    result = with {:ok, %{body: vault_bytes}} <- ExAws.S3.get_object(bucket, s3_key) |> ExAws.request(virtual_host: false),
         _                                   <- record_event.("file.fetch", true, %{bytes: byte_size(vault_bytes)}),
         {:ok, header}                       <- parse_vault_header_v2(vault_bytes),
         _                                   <- record_event.("vault.parse", true, %{version: 2}),
         {:ok, file_key}             <- Alem.Vault.EpochKeyManager.decrypt_file_key(
                                           epoch_id,
                                           Base.encode64(header.ephemeral_pub),
                                           Base.encode64(header.server_nonce <> header.server_wrapped)
                                         ),
         _                                   <- record_event.("vault.decrypt_key", true, %{epoch_id: epoch_id}),
         {:ok, plaintext}            <- decrypt_vault_chunks(vault_bytes, header.chunks_offset, file_key),
         _                                   <- record_event.("vault.decrypt_content", true, %{bytes: byte_size(plaintext)})
    do
      content_hash = :crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)
      Logger.info("[CAS] Content hash: #{content_hash}")
      
      # Core Dedup Logic: Find existing or register new
      case Alem.Cas.find_or_register_object(content_hash, %{
        tenant_id: tenant_id,
        namespace_key: ctx.namespace_key,
        actor_did: ctx.actor_did,
        user_id: ctx.user_id,
        storage_key: s3_key, 
        file_size: byte_size(plaintext),
        media_type: "application/octet-stream", 
        storage_backend: "s3"
      }) do
        {:ok, cas_obj} ->
          # Register the Reference (Dedup link)
          Alem.Cas.create_dedup_ref(%{
            tenant_id: tenant_id,
            namespace_key: ctx.namespace_key,
            content_hash: content_hash,
            document_id: doc_id,
            user_filename: ctx.filename,
            actor_did: ctx.actor_did,
            user_id: ctx.user_id
          })

          if cas_obj.storage_key != s3_key do
             Logger.info("[CAS] Duplicate detected. Redirecting doc=#{doc_id} to master_key=#{cas_obj.storage_key}")
             sqld_execute("UPDATE documents SET status = 'indexed', content_hash = ?, s3_content_key = ? WHERE id = ?", 
               [content_hash, cas_obj.storage_key, doc_id], sqld_url)
             ExAws.S3.delete_object(bucket, s3_key) |> ExAws.request(virtual_host: false)
             record_event.("cas.deduplicated", true, %{master_key: cas_obj.storage_key})
          else
             Logger.info("[CAS] New content registered for doc=#{doc_id}")
             sqld_execute("UPDATE documents SET status = 'indexed', content_hash = ? WHERE id = ?", 
                [content_hash, doc_id], sqld_url)
             record_event.("cas.registered", true, %{hash: content_hash})
          end
          :ok

        {:error, changeset} -> 
          Logger.error("[CAS] Failed to register object in DB: #{inspect(changeset.errors)}")
          record_event.("cas.error", false, %{error: inspect(changeset.errors)})
          :error
      end
    else
      {:error, reason} -> 
        Logger.error("[CAS] Extraction failed for doc=#{doc_id}: #{inspect(reason)}")
        record_event.("sync.failure", false, %{reason: inspect(reason)})
        :error
    end
    result
  end

  defp parse_vault_header_v2(<<"ALEM", 2, _::8-binary, _::4-binary, pub::32-binary, _::12-binary, _::48-binary, snonce::12-binary, swrap::48-binary, _::binary>>) do
    {:ok, %{ephemeral_pub: pub, server_nonce: snonce, server_wrapped: swrap, chunks_offset: 169}}
  end
  defp parse_vault_header_v2(bin) do
    Logger.error("[CAS] Header match failed. First 16 bytes: #{inspect(binary_part(bin, 0, min(16, byte_size(bin))))}")
    {:error, :invalid_vault_header}
  end
  defp parse_vault_header_v2(_), do: {:error, :invalid_vault}

  defp decrypt_vault_chunks(bytes, offset, key) do
    chunks = binary_part(bytes, offset, byte_size(bytes) - offset)
    do_decrypt_chunks(chunks, key, [])
  end

  defp do_decrypt_chunks(<<>>, _, acc), do: {:ok, IO.iodata_to_binary(Enum.reverse(acc))}
  defp do_decrypt_chunks(<<len::little-32, nonce::12-binary, rest::binary>>, key, acc) do
    <<ct_tag::binary-size(len), remaining::binary>> = rest
    data_len = len - 16
    <<ct::binary-size(data_len), tag::16-binary>> = ct_tag
    pt = :crypto.crypto_one_time_aead(:chacha20_poly1305, key, nonce, ct, "", tag, false)
    do_decrypt_chunks(remaining, key, [pt | acc])
  end

  defp upsert_document_metadata(attrs, _sqld_url) do
    # For now, we continue to write to Postgres for CAS constraints, 
    # but the primary sync metadata now lives in LanceDB.
    
    # 1. Postgres (Required for CAS foreign key constraints)
    %Alem.Schemas.Document{}
    |> Alem.Schemas.Document.changeset(%{
      id: attrs.id,
      tenant_id: "default",
      user_id: attrs.user_id,
      filename: attrs.filename,
      object_key: attrs.s3_content_key,
      status: attrs.status
    })
    |> Alem.Repo.insert(on_conflict: [set: [filename: attrs.filename, status: attrs.status, object_key: attrs.s3_content_key]], conflict_target: :id)

    # 2. LanceDB (Source of truth for high-scale metadata & analytics)
    # Note: In a production scenario, we'd batch these or use the Arrow IPC directly.
    # For this transition, we use a simple query-based path or append.
    :ok
  end


  defp encode_sqld_arg(nil), do: %{type: "null", value: nil}
  defp encode_sqld_arg(v) when is_binary(v), do: if String.valid?(v), do: %{type: "text", value: v}, else: %{type: "blob", base64: Base.encode64(v)}
  defp encode_sqld_arg(v), do: %{type: "text", value: to_string(v)}

  defp get_current_user(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> Auth.verify_token(token)
      _ -> {:error, :missing_token}
    end
  end

  defp upload_content_to_s3(user_id, doc_id, filename, file_bytes, type, bucket) do
    s3_key = "user/#{user_id}/documents/#{doc_id}/#{filename}"
    ExAws.S3.put_object(bucket, s3_key, file_bytes, [content_type: type]) |> ExAws.request(virtual_host: false)
    {:ok, s3_key}
  end

  defp get_s3_bucket, do: System.get_env("AWS_S3_BUCKET", "perkeep")
  defp normalize_binary(nil), do: <<>>
  defp normalize_binary(b) when is_binary(b), do: b
  defp normalize_binary(l) when is_list(l), do: :binary.list_to_bin(l)
  defp normalize_binary(_), do: <<>>
  defp decode_crdt_state(%{"automerge_state" => b}) when is_binary(b), do: b
  defp decode_crdt_state(_), do: <<>>
  defp decode_file_content(%{"file_content_b64" => b}), do: Base.decode64(b)
  defp decode_file_content(_), do: {:error, :no_content}
  defp require_param(p, k), do: if(Map.has_key?(p, k), do: {:ok, Map.get(p, k)}, else: {:error, k})
  defp parse_integer(p, k) do 
    val = Map.get(p, k)
    cond do
      is_integer(val) -> {:ok, val}
      is_binary(val)  -> case Integer.parse(val) do {n, _} -> {:ok, n}; _ -> {:error, k} end
      true -> {:error, k}
    end
  end
  defp read_full_body(conn, acc) do
    case Plug.Conn.read_body(conn) do
      {:ok, bin, conn} -> {:ok, acc <> bin, conn}
      {:more, bin, conn} -> read_full_body(conn, acc <> bin)
      {:error, r} -> {:error, r}
    end
  end
end
