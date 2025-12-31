defmodule Alem.Schemas.Document do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "documents" do
    field :user_id, :string
    field :filename, :string
    field :content_type, :string
    field :object_key, :string
    field :text_content, :string
    field :metadata, :map
    field :status, :string, default: "processing"

    timestamps(type: :utc_datetime)
  end

  def changeset(document, attrs) do
    document
    |> cast(attrs, [:id, :user_id, :filename, :content_type, :object_key, :text_content, :metadata, :status])
    |> validate_required([:id, :user_id, :filename])
  end
end
