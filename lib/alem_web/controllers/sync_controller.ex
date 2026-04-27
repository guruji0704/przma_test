defmodule AlemWeb.SyncController do
  use AlemWeb, :controller
  require Logger
  import Ecto.Query

  alias Alem.{Auth, Repo}
  alias Alem.Schemas.Document

  # ══════════════════════════════════════════════════════════════════════════
  # V1 SYNC
  # ══════════════════════════════════════════════════════════════════════════

  def crdt_upload(conn, params) do
    content_type = get_req_header(conn, "content-type") |> List.first()
    case content_type do
      "application/x-msgpack-stream" ->
        AlemWeb.StreamingSync.handle_stream(conn)
      _ ->
        file_content = Map.get(params, "file_content")
        if is_binary(file_content) and not match?(%Plug.Upload{}, file_content),
          do: crdt_upload_msgpack(conn, params),
          else: crdt_upload_json(conn, params)
    end
  end

  defp crdt_upload_msgpack(conn, params) do
    file_bytes = normalize_binary(Map.get(params, "file_content"))
    arrow_ipc  = normalize_binary(Map.get(params, "arrow_metadata_ipc"))
    with {:ok, user}     <- get_current_user(conn),
         {:ok, doc_id}   <- require_param(params, "doc_id"),
         {:ok, filename} <- require_param(params, "filename") do
      content_type = Map.get(params, "content_type", "application/octet-stream")
      bucket = get_s3_bucket()
      if byte_size(file_bytes) == 0 do
        conn |> put_status(400) |> json(%{error: "Empty file content"})
      else
        case upload_content_to_s3(user.id, doc_id, filename, file_bytes, content_type, bucket) do
          {:ok, s3_key} ->
            if is_binary(arrow_ipc) and byte_size(arrow_ipc) > 0 do
              Task.start(fn -> Alem.Analytics.MetadataStore.ingest(arrow_ipc, user.id, doc_id) end)
            end
            upsert_document_pg(%{
              id:           doc_id,
              user_id:      user.id,
              filename:     filename,
              object_key:   s3_key,
              content_type: content_type,
              status:       "synced"
            })
            json(conn, %{success: true, doc_id: doc_id, s3_key: s3_key})
          {:error, reason} ->
            conn |> put_status(500) |> json(%{error: "S3 failed: #{inspect(reason)}"})
        end
      end
    end
  end

  defp crdt_upload_json(conn, params) do
    with {:ok, user}       <- get_current_user(conn),
         {:ok, doc_id}     <- require_param(params, "doc_id"),
         {:ok, filename}   <- require_param(params, "filename"),
         {:ok, file_bytes} <- decode_file_content(params),
         {:ok, _}          <- {:ok, decode_crdt_state(params)} do
      case upload_content_to_s3(user.id, doc_id, filename, file_bytes,
             "application/octet-stream", get_s3_bucket()) do
        {:ok, s3_key} ->
          upsert_document_pg(%{
            id:           doc_id,
            user_id:      user.id,
            filename:     filename,
            object_key:   s3_key,
            content_type: "application/octet-stream",
            status:       "synced"
          })
          json(conn, %{success: true, s3_key: s3_key})
        {:error, _} ->
          conn |> put_status(500) |> json(%{error: "Upload failed"})
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # V2 PARALLEL SYNC
  # ══════════════════════════════════════════════════════════════════════════

  def v2_initiate(conn, params) do
    with {:ok, user}     <- get_current_user(conn),
         {:ok, doc_id}   <- require_param(params, "doc_id"),
         {:ok, filename} <- require_param(params, "filename") do
      did_id        = user.did_id || Alem.DID.generate(user.id)
      namespace_key = Alem.DID.namespace_key(did_id)
      Alem.Namespace.Manager.start(user.id, namespace_key, [did: did_id])
      content_type = Map.get(params, "content_type", "application/octet-stream")
      bucket = get_s3_bucket()
      s3_key = "user/#{namespace_key}/documents/#{doc_id}/#{filename}"
      case ExAws.S3.initiate_multipart_upload(bucket, s3_key, content_type: content_type)
           |> ExAws.request(virtual_host: false) do
        {:ok, %{body: %{upload_id: upload_id}}} ->
          arrow_ipc = normalize_binary(Map.get(params, "arrow_metadata_ipc"))
          if is_binary(arrow_ipc) and byte_size(arrow_ipc) > 0 do
            Task.start(fn -> Alem.Analytics.MetadataStore.ingest(arrow_ipc, user.id, doc_id) end)
          end
          json(conn, %{
            success:       true,
            upload_id:     upload_id,
            s3_key:        s3_key,
            namespace_key: namespace_key
          })
        {:error, reason} ->
          conn |> put_status(500) |> json(%{error: "S3 failed: #{inspect(reason)}"})
      end
    end
  end

  def v2_upload_part(conn, params) do
    with {:ok, user}      <- get_current_user(conn),
         {:ok, upload_id} <- require_param(params, "upload_id"),
         {:ok, doc_id}    <- require_param(params, "doc_id"),
         {:ok, part_num}  <- parse_integer(params, "part_num") do
      case read_full_body(conn, <<>>) do
        {:ok, binary, conn} ->
          namespace_key = Alem.DID.namespace_key(user.did_id || Alem.DID.generate(user.id))
          s3_key = "user/#{namespace_key}/documents/#{doc_id}/#{Map.get(params, "filename", "unknown")}"
          case ExAws.S3.upload_part(get_s3_bucket(), s3_key, upload_id, part_num, binary)
               |> ExAws.request(virtual_host: false) do
            {:ok, res} ->
              etag = res.headers
                     |> Enum.find_value(fn {k, v} ->
                       if String.downcase(k) == "etag", do: v
                     end)
              json(conn, %{success: true, etag: etag, part_num: part_num})
            {:error, _} ->
              conn |> put_status(500) |> json(%{error: "UploadPart failed"})
          end
        {:error, _} ->
          conn |> put_status(400) |> json(%{error: "Body read failed"})
      end
    end
  end

  def v2_complete(conn, params) do
    with {:ok, user}      <- get_current_user(conn),
         {:ok, doc_id}    <- require_param(params, "doc_id"),
         {:ok, upload_id} <- require_param(params, "upload_id"),
         {:ok, filename}  <- require_param(params, "filename"),
         {:ok, parts_raw} <- require_param(params, "parts") do
      namespace_key = Alem.DID.namespace_key(user.did_id || Alem.DID.generate(user.id))
      bucket = get_s3_bucket()
      s3_key = "user/#{namespace_key}/documents/#{doc_id}/#{filename}"
      parts  = parts_raw
               |> Enum.map(fn p -> {p["part_num"], p["etag"]} end)
               |> Enum.sort_by(fn {n, _} -> n end)
      case ExAws.S3.complete_multipart_upload(bucket, s3_key, upload_id, parts)
           |> ExAws.request(virtual_host: false) do
        {:ok, _} ->
          epoch_id = Map.get(params, "epoch_id")
          ctx = %{
            user_id:       user.id,
            namespace_key: user.id,
            actor_did:     user.did_id,
            device_id:     Map.get(params, "device_id", "unknown"),
            filename:      filename
          }
          Task.start(fn ->
            upsert_document_pg(%{
              id:           doc_id,
              user_id:      user.id,
              filename:     filename,
              object_key:   s3_key,
              content_type: "application/octet-stream",
              status:       "synced"
            })
            if is_integer(epoch_id),
              do: extract_vault_content_async(doc_id, s3_key, bucket, epoch_id, ctx),
              else: Logger.warning("[CAS] Skipping doc=#{doc_id}: No epoch_id")
          end)
          json(conn, %{success: true, s3_key: s3_key})
        {:error, _} ->
          conn |> put_status(500) |> json(%{error: "Completion failed"})
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # QUERIES
  # ══════════════════════════════════════════════════════════════════════════

  def get_stats(conn, _params), do: json(conn, %{success: true})

  def get_changes(conn, params) do
    with {:ok, user} <- get_current_user(conn) do
      since = Map.get(params, "since", "1970-01-01T00:00:00Z")
      since_dt = case DateTime.from_iso8601(since) do
        {:ok, dt, _} -> dt
        _            -> ~U[1970-01-01 00:00:00Z]
      end
      docs = Repo.all(
        from d in Document,
          where: d.user_id == ^user.id and d.updated_at >= ^since_dt,
          order_by: [desc: d.updated_at],
          select: %{
            id:           d.id,
            filename:     d.filename,
            content_type: d.content_type,
            object_key:   d.object_key,
            content_hash: d.content_hash,
            status:       d.status,
            updated_at:   d.updated_at
          }
      )
      json(conn, %{success: true, changes: docs})
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # CAS EXTRACTION
  # ══════════════════════════════════════════════════════════════════════════

  def extract_vault_content_async(doc_id, s3_key, bucket, epoch_id, ctx) do
    Logger.info("[CAS] Starting extraction doc=#{doc_id} epoch=#{epoch_id}")
    tenant_id = "default"

    {:ok, activity} = Alem.Cas.create_activity(%{
      tenant_id:     tenant_id,
      namespace_key: ctx.namespace_key,
      actor_did:     ctx.actor_did,
      user_id:       ctx.user_id,
      verb:          "Sync",
      object_type:   "document",
      object_id:     doc_id,
      object_path:   s3_key,
      device_id:     ctx.device_id
    })

    record_event = fn type, success, meta ->
      Alem.Cas.create_event(%{
        tenant_id:      tenant_id,
        namespace_key:  ctx.namespace_key,
        actor_did:      ctx.actor_did,
        activity_id:    activity.activity_id,
        event_category: "sync",
        event_type:     type,
        is_success:     success,
        metadata:       meta
      })
    end

    result =
      with {:ok, %{body: vault_bytes}} <-
             ExAws.S3.get_object(bucket, s3_key) |> ExAws.request(virtual_host: false),
           _ <- record_event.("file.fetch", true, %{bytes: byte_size(vault_bytes)}),
           {:ok, header} <- parse_vault_header_v2(vault_bytes),
           _ <- record_event.("vault.parse", true, %{version: 2}),
           {:ok, file_key} <- Alem.Vault.EpochKeyManager.decrypt_file_key(
             epoch_id,
             Base.encode64(header.ephemeral_pub),
             Base.encode64(header.server_nonce <> header.server_wrapped)
           ),
           _ <- record_event.("vault.decrypt_key", true, %{epoch_id: epoch_id}),
           {:ok, plaintext} <- decrypt_vault_chunks(vault_bytes, header.chunks_offset, file_key),
           _ <- record_event.("vault.decrypt_content", true, %{bytes: byte_size(plaintext)}) do

        content_hash  = :crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)
        detected_type = detect_media_type(ctx.filename, plaintext)

        case Alem.Cas.find_or_register_object(content_hash, %{
          tenant_id:       tenant_id,
          namespace_key:   ctx.namespace_key,
          actor_did:       ctx.actor_did,
          user_id:         ctx.user_id,
          storage_key:     s3_key,
          file_size:       byte_size(plaintext),
          media_type:      detected_type,
          storage_backend: "s3"
        }) do
          {:ok, cas_obj} ->
            Alem.Cas.create_dedup_ref(%{
              tenant_id:     tenant_id,
              namespace_key: ctx.namespace_key,
              content_hash:  content_hash,
              document_id:   doc_id,
              user_filename: ctx.filename,
              actor_did:     ctx.actor_did,
              user_id:       ctx.user_id
            })
            if cas_obj.storage_key != s3_key do
              update_document_pg(doc_id, %{
                content_hash: content_hash,
                object_key:   cas_obj.storage_key,
                content_type: detected_type,
                status:       "indexed"
              })
              ExAws.S3.delete_object(bucket, s3_key) |> ExAws.request(virtual_host: false)
              record_event.("cas.deduplicated", true, %{master_key: cas_obj.storage_key})
            else
              update_document_pg(doc_id, %{
                content_hash: content_hash,
                content_type: detected_type,
                status:       "indexed"
              })
              record_event.("cas.registered", true, %{hash: content_hash})
            end
            :ok
          {:error, changeset} ->
            Logger.error("[CAS] Failed: #{inspect(changeset.errors)}")
            record_event.("cas.error", false, %{error: inspect(changeset.errors)})
            :error
        end
      else
        {:error, reason} ->
          Logger.error("[CAS] Failed doc=#{doc_id}: #{inspect(reason)}")
          record_event.("sync.failure", false, %{reason: inspect(reason)})
          :error
      end

    result
  end

  # ══════════════════════════════════════════════════════════════════════════
  # POSTGRESQL HELPERS
  # ══════════════════════════════════════════════════════════════════════════

  defp upsert_document_pg(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    Repo.insert!(
      %Document{
        id:           attrs.id,
        tenant_id:    "default",
        user_id:      attrs.user_id,
        filename:     attrs.filename,
        object_key:   attrs.object_key,
        content_type: Map.get(attrs, :content_type, "application/octet-stream"),
        status:       Map.get(attrs, :status, "synced"),
        inserted_at:  now,
        updated_at:   now
      },
      on_conflict: {:replace, [:filename, :object_key, :content_type, :status, :updated_at]},
      conflict_target: :id
    )
    :ok
  rescue
    e ->
      Logger.error("[SyncController] upsert failed: #{inspect(e)}")
      :error
  end

  defp update_document_pg(doc_id, fields) do
    Repo.update_all(
      from(d in Document, where: d.id == ^doc_id),
      set: Enum.to_list(fields)
    )
  end

  # ══════════════════════════════════════════════════════════════════════════
  # VAULT CRYPTO HELPERS
  # ══════════════════════════════════════════════════════════════════════════

  defp parse_vault_header_v2(<<"ALEM", 2, _::8-binary, _::4-binary,
                               pub::32-binary, _::12-binary, _::48-binary,
                               snonce::12-binary, swrap::48-binary, _::binary>>) do
    {:ok, %{
      ephemeral_pub:  pub,
      server_nonce:   snonce,
      server_wrapped: swrap,
      chunks_offset:  169
    }}
  end
  defp parse_vault_header_v2(bin) do
    Logger.error("[CAS] Header mismatch: #{inspect(binary_part(bin, 0, min(16, byte_size(bin))))}")
    {:error, :invalid_vault_header}
  end

  defp decrypt_vault_chunks(bytes, offset, key) do
    do_decrypt_chunks(binary_part(bytes, offset, byte_size(bytes) - offset), key, [])
  end

  defp do_decrypt_chunks(<<>>, _, acc),
    do: {:ok, IO.iodata_to_binary(Enum.reverse(acc))}

  defp do_decrypt_chunks(<<len::little-32, nonce::12-binary, rest::binary>>, key, acc) do
    <<ct_tag::binary-size(len), remaining::binary>> = rest
    data_len = len - 16
    <<ct::binary-size(data_len), tag::16-binary>> = ct_tag
    pt = :crypto.crypto_one_time_aead(:chacha20_poly1305, key, nonce, ct, "", tag, false)
    do_decrypt_chunks(remaining, key, [pt | acc])
  end

  defp detect_media_type(filename, data) do
    ext = filename |> String.downcase() |> Path.extname() |> case do
      ".jpg"  -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".png"  -> "image/png"
      ".gif"  -> "image/gif"
      ".pdf"  -> "application/pdf"
      ".mp4"  -> "video/mp4"
      ".mov"  -> "video/quicktime"
      ".mp3"  -> "audio/mpeg"
      ".txt"  -> "text/plain"
      ".md"   -> "text/markdown"
      ".docx" -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
      _       -> nil
    end
    magic = case data do
      <<0x89, 0x50, 0x4E, 0x47, _::binary>> -> "image/png"
      <<0xFF, 0xD8, 0xFF, _::binary>>        -> "image/jpeg"
      <<0x25, 0x50, 0x44, 0x46, _::binary>>  -> "application/pdf"
      _                                       -> nil
    end
    magic || ext || "application/octet-stream"
  end

  # ══════════════════════════════════════════════════════════════════════════
  # GENERAL HELPERS
  # ══════════════════════════════════════════════════════════════════════════

  defp get_current_user(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> Auth.verify_token(token)
      _                        -> {:error, :missing_token}
    end
  end

  defp upload_content_to_s3(user_id, doc_id, filename, file_bytes, type, bucket) do
    s3_key = "user/#{user_id}/documents/#{doc_id}/#{filename}"
    ExAws.S3.put_object(bucket, s3_key, file_bytes, content_type: type)
    |> ExAws.request(virtual_host: false)
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

  defp require_param(p, k),
    do: if(Map.has_key?(p, k), do: {:ok, Map.get(p, k)}, else: {:error, k})

  defp parse_integer(p, k) do
    val = Map.get(p, k)
    cond do
      is_integer(val) -> {:ok, val}
      is_binary(val)  ->
        case Integer.parse(val) do
          {n, _} -> {:ok, n}
          _      -> {:error, k}
        end
      true -> {:error, k}
    end
  end

  defp read_full_body(conn, acc) do
    case Plug.Conn.read_body(conn) do
      {:ok, b, c}   -> {:ok, acc <> b, c}
      {:more, b, c} -> read_full_body(c, acc <> b)
      {:error, r}   -> {:error, r}
    end
  end
end
