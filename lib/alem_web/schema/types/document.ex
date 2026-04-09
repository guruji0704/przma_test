defmodule AlemWeb.Schema.Types.Document do
  use Absinthe.Schema.Notation

  @desc "A document stored in the user's namespace"
  object :document do
    field :id,            non_null(:id)
    field :filename,      :string
    field :user_id,       :string
    field :tenant_id,     :string
    field :content_hash,  :string
    field :content_type,  :string
    field :file_size,     :integer
    field :status,        :string
    field :activity_verb, :string
    field :metadata,      :json
    field :text_content,  :string
    field :inserted_at,   :datetime
    field :updated_at,    :datetime

    @desc "The CAS object for this document (includes signed download URL)"
    field :cas_object, :cas_object do
      resolve fn doc, _, _ ->
        case doc.content_hash && Alem.Repo.get(Alem.Cas.CasObject, doc.content_hash) do
          nil     -> {:ok, nil}
          cas_obj -> {:ok, cas_obj}
        end
      end
    end
  end
end
