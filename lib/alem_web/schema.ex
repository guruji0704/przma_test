defmodule AlemWeb.Schema do
  use Absinthe.Schema

  # Built-in Absinthe scalars: datetime, naive_datetime, date, time, decimal
  import_types Absinthe.Type.Custom
  # Provides the :upload type for file upload mutations
  import_types Absinthe.Plug.Types

  import_types AlemWeb.Schema.Types.Cas
  import_types AlemWeb.Schema.Types.Document

  # ── Custom scalars ────────────────────────────────────────────────────────

  @desc "Arbitrary JSON value — map, list, string, number, boolean, or null"
  scalar :json do
    parse fn
      %Absinthe.Blueprint.Input.String{value: value} ->
        case Jason.decode(value) do
          {:ok, decoded} -> {:ok, decoded}
          _              -> :error
        end
      %Absinthe.Blueprint.Input.Null{} ->
        {:ok, nil}
      input ->
        # Accept already-decoded maps/lists from HTTP JSON body
        {:ok, input.value}
    end
    serialize &Function.identity/1
  end

  # ── Queries ───────────────────────────────────────────────────────────────

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
      arg :query, non_null(:string)
      arg :limit, :integer, default_value: 20
      resolve &AlemWeb.Resolvers.Document.search/3
    end

    @desc "Look up a CAS object directly by its SHA-256 hash"
    field :cas_object, :cas_object do
      arg :hash, non_null(:string)
      resolve &AlemWeb.Resolvers.Cas.get/3
    end
  end

  # ── Mutations ─────────────────────────────────────────────────────────────

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

  # ── Subscriptions ─────────────────────────────────────────────────────────

  subscription do
    @desc "Fires when a new document is uploaded in the caller's namespace"
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
