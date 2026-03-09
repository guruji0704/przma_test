defmodule AlemWeb.SyncController do
  use AlemWeb, :controller
  require Logger
  alias Alem.Auth

  @sqld_fallback "http://172.235.17.68:8080"

  # ══════════════════════════════════════════════════════════════════════════
  # POST /api/v1/sync/crdt/upload
  # ══════════════════════════════════════════════════════════════════════════

  def crdt_upload(conn, params) do
    Logger.info("[SyncController] Upload received — doc_id=#{Map.get(params, "doc_id")}, " <>
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
                  file_size:    byte_size(file_bytes),
                  storage_type: "hybrid"
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

  # ══════════════════════════════════════════════════════════════════════════
  # Decode file content from request
  # ══════════════════════════════════════════════════════════════════════════

  # ✅ KEY FIX: Decode the base64 file_content_b64 field → real binary bytes
  defp decode_file_content(params) do
    b64      = Map.get(params, "file_content_b64")
    text     = Map.get(params, "text_content")

    cond do
      is_binary(b64) and b64 != "" ->
        case Base.decode64(b64) do
          {:ok, bytes} ->
            Logger.info("[Decode] file_content_b64 → #{byte_size(bytes)} bytes")
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

  defp decode_crdt_state(params) do
    case Map.get(params, "automerge_state") do
      nil -> {:ok, <<>>}
      b64 ->
        case Base.decode64(b64) do
          {:ok, bin} -> {:ok, bin}
          :error     -> {:ok, <<>>}  # non-fatal — CRDT state is optional
        end
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
      device_id, last_modified_at, file_size, status, inserted_at, updated_at
    )
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      filename         = excluded.filename,
      automerge_state  = excluded.automerge_state,
      s3_content_key   = excluded.s3_content_key,
      device_id        = excluded.device_id,
      last_modified_at = excluded.last_modified_at,
      file_size        = excluded.file_size,
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
end
