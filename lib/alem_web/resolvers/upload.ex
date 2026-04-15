defmodule AlemWeb.Resolvers.Upload do
  @moduledoc """
  GraphQL uploadDocument mutation.

  The resolver does exactly three things:
    1. Derive ns_key from the user's DID
    2. Call Namespace.ingest_document — Namespace handles everything else
    3. Publish the subscription event

  The resolver NEVER calls CAS, S3, or Repo directly.
  Namespace is the only gateway.
  """

  require Logger
  alias Alem.{DID, Namespace}

  # Maximum file size: 5GB
  @max_file_size 5 * 1024 * 1024 * 1024

  # Allowed MIME types (security: whitelist approach)
  @allowed_types [
    "application/pdf",
    "application/msword",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "application/vnd.ms-excel",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "application/vnd.ms-powerpoint",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    "text/plain",
    "text/csv",
    "image/jpeg",
    "image/png",
    "image/gif",
    "image/webp",
    "image/svg+xml",
    "video/mp4",
    "video/webm",
    "audio/mpeg",
    "audio/wav",
    "application/zip",
    "application/x-rar-compressed",
    "application/gzip",
    "application/x-tar",
    "application/json",
    "application/xml",
    "text/xml"
  ]

  def upload(_parent, %{file: upload, filename: filename} = args, %{context: ctx}) do
    user   = ctx.current_user
    ns_key = DID.namespace_key(user.did_id)
    doc_id = args[:doc_id] || UUID.uuid4()

    # Validate filename - prevent path traversal
    sanitized_filename = sanitize_filename(filename)

    with {:ok, data} <- File.read(upload.path),
         :ok <- validate_file_size(byte_size(data)),
         :ok <- validate_file_type(upload.content_type) do
      doc_attrs = %{
        doc_id:       doc_id,
        filename:     sanitized_filename,
        file_data:    data,
        content_type: upload.content_type || "application/octet-stream",
        file_size:    byte_size(data),
        metadata:     Map.merge(args[:metadata] || %{}, %{
          "uploaded_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "original_filename" => filename
        })
      }

      # Namespace handles: CAS hash → dedup check → S3 (if new) →
      #   cas_objects → documents → cas_dedup_refs → cas_activities
      case Namespace.ingest_document(ns_key, doc_attrs) do
        {:ok, doc, cas_obj, is_duplicate} ->
          result = %{
            document:     doc,
            content_hash: cas_obj.content_hash,
            is_duplicate: is_duplicate,
            bytes_saved:  if(is_duplicate, do: byte_size(data), else: 0)
          }

          Absinthe.Subscription.publish(
            AlemWeb.Endpoint, result,
            document_uploaded: "uploads:#{ns_key}"
          )

          Logger.info("[Upload.Resolver] #{doc.id} ns=#{ns_key} dedup=#{is_duplicate} size=#{byte_size(data)}")
          {:ok, result}

        {:error, reason} ->
          {:error, "Upload failed: #{inspect(reason)}"}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Sanitize filename - remove dangerous characters
  defp sanitize_filename(filename) do
    filename
    |> String.trim()
    |> String.replace(~r/[\/\\:*?"<>|]/, "_")
    |> String.replace(~r/^\.+/, "_")
    |> case do
      "" -> "unnamed_file_#{System.unique_integer([:positive])}"
      name -> name
    end
  end

  # Validate file size
  defp validate_file_size(size) when size > 0 and size <= @max_file_size do
    :ok
  end

  defp validate_file_size(size) when size <= 0 do
    {:error, "File is empty"}
  end

  defp validate_file_size(_size) do
    {:error, "File exceeds maximum size of #{@max_file_size |> div(1024 * 1024 * 1024)}GB"}
  end

  # Validate MIME type
  defp validate_file_type(nil), do: :ok

  defp validate_file_type(mime_type) do
    base_type = mime_type |> String.split(";") |> List.first() |> String.trim()

    if base_type in @allowed_types do
      :ok
    else
      {:error, "File type #{base_type} is not allowed"}
    end
  end
end
