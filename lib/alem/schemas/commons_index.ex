defmodule Alem.Schemas.CommonsIndex do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "commons_index" do
    field :content_hash,   :string
    field :document_id,    :binary_id
    field :owner_did,      :string
    field :source_ns_key,  :string
    field :media_type,     :string
    field :media_category, :string
    field :filename,       :string
    field :indexed_at,     :utc_datetime
    field :removed_at,     :utc_datetime
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:id, :content_hash, :document_id, :owner_did,
                    :source_ns_key, :media_type, :media_category,
                    :filename, :indexed_at, :removed_at])
    |> validate_required([:id, :document_id, :owner_did, :source_ns_key, :indexed_at])
  end
end
