defmodule AlemWeb.Schema.Types.Cas do
  use Absinthe.Schema.Notation

  @desc "A content-addressed object — one row per unique file, identified by SHA-256 hash"
  object :cas_object do
    field :content_hash,    non_null(:string)
    field :storage_backend, :string
    field :media_type,      :string
    field :file_size,       :integer
    field :ref_count,       :integer

    @desc "Signed S3 download URL (valid for 1 hour)"
    field :download_url, :string do
      resolve fn cas_obj, _, _ ->
        case Alem.Storage.CAS.get_signed_url(cas_obj.content_hash) do
          {:ok, url} -> {:ok, url}
          _          -> {:ok, nil}
        end
      end
    end
  end

  @desc "Result returned from uploadDocument mutation"
  object :upload_result do
    field :document,     :document
    field :content_hash, :string
    field :is_duplicate, :boolean  # true = CAS dedup saved space
    field :bytes_saved,  :integer  # 0 if new, file_size if duplicate
  end

  @desc "Result returned from deleteDocument mutation"
  object :delete_result do
    field :success, :boolean
    field :id,      :string
  end
end
