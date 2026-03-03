defmodule AlemWeb.SyncController do
  use AlemWeb, :controller
  require Logger
  alias Alem.Auth

  @sqld_fallback "http://172.235.17.68:8080"

  # ══════════════════════════════════════════════════════════════════════════
  # POST /api/v1/sync/crdt/upload
  # ══════════════════════════════════════════════════════════════════════════

  def crdt_upload(conn, %{
    "doc_id" => doc_id,
    "filename" => filename,
    "automerge_state" => automerge_state_b64,
    "text_content" => text_content,
    "device_id" => device_id,
    "last_modified_at" => last_modified_at
  }) do
    with {:ok, user} <- get_current_user(conn) do
      user_id = user.id
      bucket  = System.get_env("AWS_S3_BUCKET", "perkeep")

      Logger.info("🔄 [Sync] Upload: '#{filename}' from device #{String.slice(device_id, 0..7)}")

      # 1. Decode CRDT state
      automerge_state =
        case Base.decode64(automerge_state_b64) do
          {:ok, bin} -> bin
          :error -> nil
        end

      # 2. Upload ACTUAL FILE CONTENT to S3
      case upload_content_to_s3(user_id, doc_id, filename, text_content, bucket) do
        {:ok, s3_key} ->
          # 3. Save Metadata + CRDT to SQLd
          sqld_url = @sqld_fallback

          case upsert_document_metadata(%{
            id:               doc_id,
            user_id:          user_id,
            filename:         filename,
            automerge_state:  automerge_state, # SQLd (Blob)
            s3_content_key:   s3_key,          # SQLd (Text Pointer)
            device_id:        device_id,
            last_modified_at: last_modified_at,
            file_size:        byte_size(text_content),
            status:           "synced"
          }, sqld_url) do
            :ok ->
              Logger.info("✅ [Sync] Complete: File in S3, Meta+CRDT in sqld")

              json(conn, %{
                success:       true,
                doc_id:        doc_id,
                s3_key:        s3_key,
                storage_type:  "hybrid"
              })

            {:error, reason} ->
              Logger.error("❌ [Sync] sqld write failed: #{inspect(reason)}")
              conn |> put_status(500) |> json(%{error: "Database write failed"})
          end

        {:error, reason} ->
          Logger.error("❌ [Sync] S3 upload failed: #{inspect(reason)}")
          conn |> put_status(500) |> json(%{error: "Storage upload failed"})
      end
    else
      {:error, :missing_token} -> conn |> put_status(401) |> json(%{error: "Missing auth token"})
      {:error, :invalid_token} -> conn |> put_status(401) |> json(%{error: "Invalid token"})
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # S3 Helper - ONLY uploads the file content now
  # ══════════════════════════════════════════════════════════════════════════

  defp upload_content_to_s3(user_id, doc_id, filename, text_content, bucket) do
    # Path: user/{user_id}/documents/{doc_id}/filename
    s3_key = "user/#{user_id}/documents/#{doc_id}/#{filename}"

    case ExAws.S3.put_object(bucket, s3_key, text_content) |> ExAws.request() do
      {:ok, _} ->
        Logger.info("✅ [S3] Uploaded file content: #{s3_key}")
        {:ok, s3_key}
      {:error, reason} ->
        {:error, reason}
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # SQLd Helper - Stores Metadata + CRDT
  # ══════════════════════════════════════════════════════════════════════════

  defp upsert_document_metadata(attrs, sqld_url) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    # Schema: id, user_id, filename, automerge_state, s3_content_key, device_id...
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
      attrs.automerge_state, # Binary handled by encoder
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

  # ... (Keep sqld_execute and encode_sqld_arg helpers from previous example) ...
  # Ensure encode_sqld_arg handles binary automerge_state as blob base64

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
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status, body: resp_body}} ->
          Logger.error("[sqld] HTTP #{status}: #{inspect(resp_body)}")
          {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp encode_sqld_arg(nil), do: %{"type" => "null", "value" => nil}
  defp encode_sqld_arg(v) when is_integer(v), do: %{"type" => "integer", "value" => to_string(v)}
  defp encode_sqld_arg(v) when is_binary(v) do
    if String.valid?(v) do
      %{"type" => "text", "value" => v}
    else
      # Handle CRDT Binary Blob
      %{"type" => "blob", "base64" => Base.encode64(v)}
    end
  end
  defp encode_sqld_arg(v), do: %{"type" => "text", "value" => to_string(v)}

  # ══════════════════════════════════════════════════════════════════════════
  # Auth Helper
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
