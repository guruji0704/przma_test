# lib/alem_web/schema.ex
defmodule AlemWeb.Schema do
  use Absinthe.Schema

  import_types AlemWeb.Schema.Types.Document
  import_types AlemWeb.Schema.Types.Cas
  import_types Absinthe.Type.Custom

  query do
    field :documents, list_of(:document) do
      arg :limit,   :integer, default_value: 20
      arg :offset,  :integer, default_value: 0
      arg :status,  :string
      resolve &AlemWeb.Resolvers.Document.list/3
    end

    field :document, :document do
      arg :id, non_null(:id)
      resolve &AlemWeb.Resolvers.Document.get/3
    end

    field :cas_object, :cas_object do
      arg :hash, non_null(:string)
      resolve &AlemWeb.Resolvers.Cas.get/3
    end
  end

  mutation do
    field :upload_document, :upload_result do
      arg :file,      non_null(:upload)   # Absinthe.Upload
      arg :filename,  non_null(:string)
      arg :doc_id,    :string
      arg :metadata,  :json
      resolve &AlemWeb.Resolvers.Upload.upload/3
    end

    field :delete_document, :delete_result do
      arg :id, non_null(:id)
      resolve &AlemWeb.Resolvers.Document.delete/3
    end
  end

  subscription do
    field :document_uploaded, :document do
      arg :user_id, non_null(:string)

      config fn args, %{context: ctx} ->
        {:ok, topic: "uploads:#{args.user_id}"}
      end

      trigger :upload_document, topic: fn doc ->
        "uploads:#{doc.user_id}"
      end
    end
  end
end
