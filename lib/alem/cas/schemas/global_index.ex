defmodule Alem.CAS.GlobalIndex do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:cid, :string, autogenerate: false}

  schema "cas_global_index" do
    field :size_bytes, :integer
    field :mime_type,  :string,  default: "application/octet-stream"
    field :s3_key,     :string
    field :ref_count,  :integer, default: 0
    field :status,     :string,  default: "uploading"
    field :first_seen, :utc_datetime
    field :last_seen,  :utc_datetime
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:cid, :size_bytes, :mime_type, :s3_key, :ref_count, :status])
    |> validate_required([:cid, :size_bytes])
    |> validate_inclusion(:status, ["uploading", "complete", "failed"])
  end
end
