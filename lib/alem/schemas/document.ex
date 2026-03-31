defmodule Alem.Schemas.Document do
  @moduledoc "A document record — metadata only. Bytes are in CAS (S3)."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "documents" do
    field :tenant_id,     :string
    field :user_id,       :string
    field :filename,      :string
    field :content_type,  :string
    field :object_key,    :string
    # Legacy S3 path. New uploads use content_hash instead.
    field :content_hash,  :string
    # FK → cas_objects.content_hash
    field :text_content,  :string
    field :metadata,      :map
    field :status,        :string, default: "processing"

    # CAS fields — added by migration 20260325_add_cas_fields_to_documents
    field :file_size,     :integer, default: 0
    field :activity_verb, :string,  default: "Create"
    field :actor_id,      :string

    timestamps(type: :utc_datetime)
  end

  @castable [:id, :tenant_id, :user_id, :filename, :content_type,
             :object_key, :content_hash, :text_content, :metadata,
             :status, :file_size, :activity_verb, :actor_id]

  def changeset(document, attrs) do
    document
    |> cast(attrs, @castable)
    |> validate_required([:id, :tenant_id, :user_id, :filename])
  end
end
