# lib/alem/schemas/cas_object.ex
defmodule Alem.Schemas.CasObject do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:content_hash, :string, autogenerate: false}

  schema "cas_objects" do
    field :storage_backend, :string, default: "s3"
    field :storage_key,     :string
    field :media_type,      :string
    field :file_size,       :integer, default: 0
    field :ref_count,       :integer, default: 1
    field :verified_at,     :utc_datetime

    has_many :documents, Alem.Schemas.Document,
      foreign_key: :content_hash, references: :content_hash

    timestamps(type: :utc_datetime)
  end

  def changeset(cas_object, attrs) do
    cas_object
    |> cast(attrs, [:content_hash, :storage_backend, :storage_key,
                    :media_type, :file_size, :ref_count])
    |> validate_required([:content_hash, :storage_key])
    |> validate_inclusion(:storage_backend, ["s3", "local"])
  end
end
