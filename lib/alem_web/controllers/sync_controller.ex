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
    with {:ok, user}     <- get_current_user(conn),
         {:ok, doc_id}   <- require_param(params, "doc_id"),
         {:ok, filename} <- require_param(params, "filename") do
      content_type   = Map.get(params, "content_type", "application/octet-stream")
      vault_category = Map.get(params, "vault_category", "personal")
      bucket = get_s3_bucket()
      if byte_size(file_bytes) == 0 do
        conn |> put_status(400) |> json(%{error: "Empty file content"})
      else
        case upload_content_to_s3(derive_namespace_key(user), vault_category, doc_id, filename, file_bytes, content_type, bucket) do
          {:ok, s3_key} ->
            upsert_document_pg(%{
              id:            doc_id,
              user_id:       user.id,
              filename:      filename,
              object_key:    s3_key,
              content_type:  content_type,
              vault_category: vault_category,
              status:        "synced"
            })
            # Push perception event with vector to LanceDB via Rust NIF
            Task.start(fn ->
              user_did = user.did_id || user.id
              vector = Alem.Lance.VectorEncoder.encode(
                file_bytes,
                content_type,
                %{
                  "seven_p_primary"  => Map.get(params, "seven_p_primary", "portfolio"),
                  "preserve_primary" => Map.get(params, "preserve_primary", "engagement"),
                  "light_element"    => Map.get(params, "light_element", "transform")
                }
              )
              Alem.Lance.DISSupervisor.ensure_writer(user_did)
              Alem.Lance.LanceWriter.insert_perception(user_did, %{
                "id"               => doc_id,
                "vector"           => vector,
                "verb"             => "Create",
                "media_type"       => content_type,
                "filename"         => filename,
                "seven_p_primary"  => Map.get(params, "seven_p_primary", "portfolio"),
                "preserve_primary" => Map.get(params, "preserve_primary", "engagement"),
                "light_element"    => Map.get(params, "light_element", "transform"),
                "altruistic_axis"  => Map.get(params, "altruistic_axis", "serve"),
                "vault_tier"       => Map.get(params, "vault_tier", "private")
              })
            end)
            json(conn, %{success: true, doc_id: doc_id, s3_key: s3_key})
          {:error, reason} ->
            conn |> put_status(500) |> json(%{error: "S3 failed: #{inspect(reason)}"})
        end
      end
    else
      {:error, _} -> conn |> put_status(401) |> json(%{error: "Unauthorized"})
    end
  end

  defp crdt_upload_json(conn, params) do
    with {:ok, user}       <- get_current_user(conn),
         {:ok, doc_id}     <- require_param(params, "doc_id"),
         {:ok, filename}   <- require_param(params, "filename"),
         {:ok, file_bytes} <- decode_file_content(params),
         {:ok, _}          <- {:ok, decode_crdt_state(params)} do
      content_type = "application/octet-stream"
      vault_category = Map.get(params, "vault_category", "personal")
      case upload_content_to_s3(derive_namespace_key(user), vault_category, doc_id, filename, file_bytes,
             content_type, get_s3_bucket()) do
        {:ok, s3_key} ->
          upsert_document_pg(%{
            id:            doc_id,
            user_id:       user.id,
            filename:      filename,
            object_key:    s3_key,
            content_type:  content_type,
            vault_category: vault_category,
            status:        "synced"
          })
          # Push perception event with vector to LanceDB via Rust NIF
          Task.start(fn ->
            user_did = user.did_id || user.id
            vector = Alem.Lance.VectorEncoder.encode(
              file_bytes,
              content_type,
              %{
                "seven_p_primary"  => Map.get(params, "seven_p_primary", "portfolio"),
                "preserve_primary" => Map.get(params, "preserve_primary", "engagement"),
                "light_element"    => Map.get(params, "light_element", "transform")
              }
            )
            Alem.Lance.DISSupervisor.ensure_writer(user_did)
            Alem.Lance.LanceWriter.insert_perception(user_did, %{
              "id"               => doc_id,
              "vector"           => vector,
              "verb"             => "Create",
              "media_type"       => content_type,
              "filename"         => filename,
              "seven_p_primary"  => Map.get(params, "seven_p_primary", "portfolio"),
              "preserve_primary" => Map.get(params, "preserve_primary", "engagement"),
              "light_element"    => Map.get(params, "light_element", "transform"),
              "altruistic_axis"  => Map.get(params, "altruistic_axis", "serve"),
              "vault_tier"       => Map.get(params, "vault_tier", "private")
            })
          end)
          json(conn, %{success: true, s3_key: s3_key})
        {:error, _} ->
          conn |> put_status(500) |> json(%{error: "Upload failed"})
      end
    else
      {:error, _} -> conn |> put_status(401) |> json(%{error: "Unauthorized"})
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # V2 PARALLEL SYNC
  # ══════════════════════════════════════════════════════════════════════════

  def v2_initiate(conn, params) do
    with {:ok, user}     <- get_current_user(conn),
         {:ok, doc_id}   <- require_param(params, "doc_id"),
         {:ok, filename} <- require_param(params, "filename") do
      namespace_key  = derive_namespace_key(user)
      did_id         = user.did_id || "did:przma:#{namespace_key}"
      vault_category = Map.get(params, "vault_category", "personal")
      Alem.Namespace.Manager.start(user.id, namespace_key, [did: did_id])
      content_type = Map.get(params, "content_type", "application/octet-stream")
      bucket = get_s3_bucket()
      s3_key = vault_s3_key(namespace_key, vault_category, doc_id, filename)
      case ExAws.S3.initiate_multipart_upload(bucket, s3_key, content_type: content_type)
           |> ExAws.request(virtual_host: false) do
        {:ok, %{body: %{upload_id: upload_id}}} ->
          json(conn, %{
            success:       true,
            upload_id:     upload_id,
            s3_key:        s3_key,
            namespace_key: namespace_key
          })
        {:error, reason} ->
          conn |> put_status(500) |> json(%{error: "S3 failed: #{inspect(reason)}"})
      end
    else
      {:error, _} -> conn |> put_status(401) |> json(%{error: "Unauthorized"})
    end
  end

  def v2_upload_part(conn, params) do
    with {:ok, user}      <- get_current_user(conn),
         {:ok, upload_id} <- require_param(params, "upload_id"),
         {:ok, doc_id}    <- require_param(params, "doc_id"),
         {:ok, part_num}  <- parse_integer(params, "part_num") do
      case read_full_body(conn, <<>>) do
        {:ok, binary, conn} ->
          namespace_key  = derive_namespace_key(user)
          vault_category = Map.get(params, "vault_category", "personal")
          s3_key = vault_s3_key(namespace_key, vault_category, doc_id, Map.get(params, "filename", "unknown"))
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
    else
      {:error, _} -> conn |> put_status(401) |> json(%{error: "Unauthorized"})
    end
  end

  def v2_complete(conn, params) do
    with {:ok, user}      <- get_current_user(conn),
         {:ok, doc_id}    <- require_param(params, "doc_id"),
         {:ok, upload_id} <- require_param(params, "upload_id"),
         {:ok, filename}  <- require_param(params, "filename"),
         {:ok, parts_raw} <- require_param(params, "parts") do
      namespace_key  = derive_namespace_key(user)
      vault_category = Map.get(params, "vault_category", "personal")
      bucket = get_s3_bucket()
      s3_key = vault_s3_key(namespace_key, vault_category, doc_id, filename)
      parts  = parts_raw
               |> Enum.map(fn p -> {p["part_num"], p["etag"]} end)
               |> Enum.sort_by(fn {n, _} -> n end)
      case ExAws.S3.complete_multipart_upload(bucket, s3_key, upload_id, parts)
           |> ExAws.request(virtual_host: false) do
        {:ok, _} ->
          epoch_id = Map.get(params, "epoch_id")
          user_did = user.did_id || "did:przma:#{namespace_key}"
          ctx = %{
            user_id:       user.id,
            namespace_key: namespace_key,
            actor_did:     user.did_id,
            device_id:     Map.get(params, "device_id", "unknown"),
            filename:      filename
          }
          Task.start(fn ->
            # 1. Save document metadata to PostgreSQL
            upsert_document_pg(%{
              id:            doc_id,
              user_id:       user.id,
              filename:      filename,
              object_key:    s3_key,
              content_type:  "application/octet-stream",
              vault_category: vault_category,
              status:        "synced"
            })

            # 2. Write to server-side vault LanceDB
            Alem.Lance.VaultStore.upsert_document(vault_category, %{
              doc_id:        doc_id,
              user_did:      user_did,
              namespace_key: namespace_key,
              filename:      filename,
              content_type:  "application/octet-stream",
              object_key:    s3_key,
              device_id:     Map.get(params, "device_id", "unknown"),
              epoch_id:      epoch_id,
              status:        "synced"
            })

            # 2. Generate vector + push perception event to LanceDB via Rust NIF
            user_did = user.did_id || user.id
            case ExAws.S3.get_object(bucket, s3_key)
                 |> ExAws.request(virtual_host: false) do
              {:ok, %{body: file_bytes}} ->
                content_type = detect_media_type(filename, file_bytes)
                vector = Alem.Lance.VectorEncoder.encode(
                  file_bytes,
                  content_type,
                  %{
                    "seven_p_primary"  => Map.get(params, "seven_p_primary", "portfolio"),
                    "preserve_primary" => Map.get(params, "preserve_primary", "engagement"),
                    "light_element"    => Map.get(params, "light_element", "transform")
                  }
                )
                Alem.Lance.DISSupervisor.ensure_writer(user_did)
                Alem.Lance.LanceWriter.insert_perception(user_did, %{
                  "id"               => doc_id,
                  "vector"           => vector,
                  "verb"             => "Create",
                  "media_type"       => content_type,
                  "filename"         => filename,
                  "seven_p_primary"  => Map.get(params, "seven_p_primary", "portfolio"),
                  "preserve_primary" => Map.get(params, "preserve_primary", "engagement"),
                  "light_element"    => Map.get(params, "light_element", "transform"),
                  "altruistic_axis"  => Map.get(params, "altruistic_axis", "serve"),
                  "vault_tier"       => Map.get(params, "vault_tier", "private")
                })
              {:error, reason} ->
                Logger.warning("[VectorEncoder] Could not fetch file: #{inspect(reason)}")
            end

            # 3. Extract vault content if E2EE epoch key present
            if is_integer(epoch_id) and epoch_id > 0,
              do: extract_vault_content_async(doc_id, s3_key, bucket, epoch_id, ctx),
              else: Logger.debug("[CAS] Skipping doc=#{doc_id}: No valid epoch_id (#{inspect(epoch_id)})")
          end)
          json(conn, %{success: true, s3_key: s3_key})
        {:error, _} ->
          conn |> put_status(500) |> json(%{error: "Completion failed"})
      end
    else
      {:error, _} -> conn |> put_status(401) |> json(%{error: "Unauthorized"})
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # V1 CHUNK / FINALIZE (delegates to crdt_upload)
  # ══════════════════════════════════════════════════════════════════════════

  def chunk_upload(conn, params), do: crdt_upload(conn, params)
  def finalize_upload(conn, params), do: crdt_upload(conn, params)

  # ══════════════════════════════════════════════════════════════════════════
  # APPLY CHANGES
  # ══════════════════════════════════════════════════════════════════════════

  def apply_changes(conn, _params) do
    json(conn, %{success: true, applied: 0})
  end

  # ══════════════════════════════════════════════════════════════════════════
  # DOWNLOAD FILE — returns presigned S3 URL for a single document
  # ══════════════════════════════════════════════════════════════════════════

  def download_file(conn, %{"doc_id" => doc_id}) do
    with {:ok, user} <- get_current_user(conn) do
      case Repo.one(from d in Document, where: d.id == ^doc_id and d.user_id == ^user.id) do
        nil ->
          conn |> put_status(404) |> json(%{error: "Not found"})
        %{object_key: nil} ->
          conn |> put_status(404) |> json(%{error: "No file stored for this document"})
        doc ->
          case Alem.Storage.ObjectStore.presigned_download_url(get_s3_bucket(), doc.object_key) do
            {:ok, url} ->
              json(conn, %{
                id:           doc.id,
                filename:     doc.filename,
                content_type: doc.content_type,
                download_url: url
              })
            {:error, reason} ->
              Logger.error("[DownloadFile] Presign failed for #{doc_id}: #{inspect(reason)}")
              conn |> put_status(500) |> json(%{error: "Could not generate download URL"})
          end
      end
    else
      {:error, _} -> conn |> put_status(401) |> json(%{error: "Unauthorized"})
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # SSE EVENT STREAM — real-time sync nudges to desktop clients
  # ══════════════════════════════════════════════════════════════════════════

  def event_stream(conn, _params) do
    case get_current_user(conn) do
      {:ok, _user} ->
        conn =
          conn
          |> put_resp_content_type("text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> put_resp_header("x-accel-buffering", "no")
          |> send_chunked(200)
        sse_heartbeat_loop(conn)
      _ ->
        conn |> put_status(401) |> json(%{error: "Unauthorized"})
    end
  end

  defp sse_heartbeat_loop(conn) do
    Process.sleep(25_000)
    case Plug.Conn.chunk(conn, ": heartbeat\n\n") do
      {:ok, conn} -> sse_heartbeat_loop(conn)
      {:error, _} -> conn
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
            id:               d.id,
            filename:         d.filename,
            content_type:     d.content_type,
            object_key:       d.object_key,
            content_hash:     d.content_hash,
            status:           d.status,
            last_modified_at: d.updated_at,
            device_id:        fragment("coalesce((?->>'device_id'), '')", d.metadata),
            vault_category:   d.vault_category
          }
      )
      bucket = get_s3_bucket()
      changes = Enum.map(docs, fn doc ->
        download_url =
          case doc.object_key do
            nil -> nil
            key ->
              case Alem.Storage.ObjectStore.presigned_download_url(bucket, key) do
                {:ok, url} -> url
                _          -> nil
              end
          end
        Map.put(doc, :download_url, download_url)
      end)
      json(conn, %{success: true, changes: changes})
    else
      {:error, _} -> conn |> put_status(401) |> json(%{error: "Unauthorized"})
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

            # Push PRESERVE event to LanceDB after CAS registration
            Task.start(fn ->
              user_did = ctx.actor_did || ctx.user_id
              vector = Alem.Lance.VectorEncoder.encode(
                plaintext,
                detected_type,
                %{
                  "seven_p_primary"  => "portfolio",
                  "preserve_primary" => "engagement",
                  "light_element"    => "transform"
                }
              )
              Alem.Lance.DISSupervisor.ensure_writer(user_did)
              Alem.Lance.LanceWriter.insert_preserve(user_did, %{
                "id"               => doc_id,
                "vector"           => vector,
                "preserve_primary" => "engagement",
                "light_element"    => "transform",
                "vault_tier"       => "private",
                "content_hash"     => content_hash,
                "media_type"       => detected_type
              })
            end)

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
        id:             attrs.id,
        tenant_id:      "default",
        user_id:        attrs.user_id,
        filename:       attrs.filename,
        object_key:     attrs.object_key,
        content_type:   Map.get(attrs, :content_type, "application/octet-stream"),
        vault_category: Map.get(attrs, :vault_category, "personal"),
        status:         Map.get(attrs, :status, "synced"),
        inserted_at:    now,
        updated_at:     now
      },
      on_conflict: {:replace, [:filename, :object_key, :content_type, :vault_category, :status, :updated_at]},
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
      ".wav"  -> "audio/wav"
      ".txt"  -> "text/plain"
      ".md"   -> "text/markdown"
      ".docx" -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
      _       -> nil
    end
    magic = case data do
      <<0x89, 0x50, 0x4E, 0x47, _::binary>> -> "image/png"
      <<0xFF, 0xD8, 0xFF, _::binary>>        -> "image/jpeg"
      <<0x25, 0x50, 0x44, 0x46, _::binary>>  -> "application/pdf"
      <<0x49, 0x44, 0x33, _::binary>>        -> "audio/mpeg"
      <<0x00, 0x00, 0x00, _, 0x66, 0x74, 0x79, 0x70, _::binary>> -> "video/mp4"
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

  defp derive_namespace_key(user) do
    case user.did_id do
      did when is_binary(did) and byte_size(did) > 0 ->
        Alem.DID.namespace_key(did)
      _ ->
        # Stable fallback: SHA-256(user_id), base64url, first 16 chars — never random
        :crypto.hash(:sha256, user.id)
        |> Base.url_encode64(padding: false)
        |> binary_part(0, 16)
    end
  end

  defp upload_content_to_s3(namespace_key, vault_category, doc_id, filename, file_bytes, type, bucket) do
    s3_key = vault_s3_key(namespace_key, vault_category, doc_id, filename)
    case ExAws.S3.put_object(bucket, s3_key, file_bytes, content_type: type)
         |> ExAws.request(virtual_host: false) do
      {:ok, _}         -> {:ok, s3_key}
      {:error, reason} -> {:error, reason}
    end
  end

  defp vault_s3_key(namespace_key, vault_category, doc_id, filename) do
    "user/#{namespace_key}/#{vault_category}_vault/#{doc_id}/#{filename}"
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
