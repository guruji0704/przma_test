defmodule AlemWeb.Schema do
  use Absinthe.Schema

  import_types Absinthe.Type.Custom
  import_types AlemWeb.Schema.Types.Cas
  import_types AlemWeb.Schema.Types.Document

  # ── Queries (read) ──────────────────────────────────────────────────────────

  query do
    @desc "List documents in the caller's namespace"
    field :documents, list_of(:document) do
      arg :limit,  :integer, default_value: 20
      arg :offset, :integer, default_value: 0
      arg :status, :string
      resolve &AlemWeb.Resolvers.Document.list/3
    end

    @desc "Get a single document by ID"
    field :document, :document do
      arg :id, non_null(:id)
      resolve &AlemWeb.Resolvers.Document.get/3
    end

    @desc "Full-text search within the caller's namespace"
    field :search_documents, list_of(:document) do
      arg :query,  non_null(:string)
      arg :limit,  :integer, default_value: 20
      resolve &AlemWeb.Resolvers.Document.search/3
    end

    @desc "Look up a CAS object directly by its SHA-256 hash"
    field :cas_object, :cas_object do
      arg :hash, non_null(:string)
      resolve &AlemWeb.Resolvers.Cas.get/3
    end
  end

  # ── Mutations (write) ───────────────────────────────────────────────────────

  mutation do
    @desc "Upload a file — CAS dedup applied automatically"
    field :upload_document, :upload_result do
      arg :file,     non_null(:upload)
      arg :filename, non_null(:string)
      arg :doc_id,   :string
      arg :metadata, :json
      resolve &AlemWeb.Resolvers.Upload.upload/3
    end

    @desc "Delete a document from the caller's namespace"
    field :delete_document, :delete_result do
      arg :id, non_null(:id)
      resolve &AlemWeb.Resolvers.Document.delete/3
    end
  end

  # ── Subscriptions (real-time) ───────────────────────────────────────────────

  subscription do
    @desc "Fires when a new document is successfully uploaded in the caller's namespace"
    field :document_uploaded, :document do
      arg :namespace_key, non_null(:string)

      config fn args, _ctx ->
        {:ok, topic: "uploads:#{args.namespace_key}"}
      end

      trigger :upload_document, topic: fn
        %{document: doc} -> "uploads:#{doc.tenant_id}"
        _ -> nil
      end
    end
  end
end
