# lib/alem_web/schema/types/cas.ex
defmodule AlemWeb.Schema.Types.Cas do
  use Absinthe.Schema.Notation

  object :cas_object do
    field :content_hash,    non_null(:string)
    field :storage_backend, :string
    field :media_type,      :string
    field :file_size,       :integer
    field :ref_count,       :integer

    # Computed field — calls CAS to get a signed download URL
    field :download_url, :string do
      resolve fn cas_obj, _, _ ->
        case Alem.Storage.CAS.get_signed_url(cas_obj.content_hash) do
          {:ok, url} -> {:ok, url}
          _          -> {:ok, nil}
        end
      end
    end
  end

  object :upload_result do
    field :document,     :document
    field :content_hash, :string
    field :is_duplicate, :boolean   # true if CAS dedup happened
    field :bytes_saved,  :integer   # 0 if new, file_size if dedup
  end

  object :delete_result do
    field :success, :boolean
    field :id,      :string
  end
end
