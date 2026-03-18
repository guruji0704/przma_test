# lib/alem_web/schema/types/document.ex
defmodule AlemWeb.Schema.Types.Document do
  use Absinthe.Schema.Notation

  object :document do
    field :id,           non_null(:id)
    field :filename,     :string
    field :user_id,      :string
    field :tenant_id,    :string
    field :content_hash, :string
    field :media_type,   :string
    field :file_size,    :integer
    field :status,       :string
    field :metadata,     :json
    field :inserted_at,  :datetime
    field :updated_at,   :datetime

    # Nested CAS object with signed URL
    field :cas_object, :cas_object do
      resolve fn doc, _, _ ->
        case Alem.Repo.get(Alem.Schemas.CasObject, doc.content_hash) do
          nil     -> {:ok, nil}
          cas_obj -> {:ok, cas_obj}
        end
      end
    end
  end
end
