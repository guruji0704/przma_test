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

  def upload(_parent, %{file: upload, filename: filename} = args, %{context: ctx}) do
    user   = ctx.current_user
    ns_key = DID.namespace_key(user.did_id)
    doc_id = args[:doc_id] || UUID.uuid4()

    {:ok, data} = File.read(upload.path)

    doc_attrs = %{
      doc_id:       doc_id,
      filename:     filename,
      file_data:    data,
      content_type: upload.content_type || "application/octet-stream",
      metadata:     args[:metadata] || %{}
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

        Logger.info("[Upload.Resolver] #{doc.id} ns=#{ns_key} dedup=#{is_duplicate}")
        {:ok, result}

      {:error, reason} ->
        {:error, "Upload failed: #{inspect(reason)}"}
    end
  end
end
