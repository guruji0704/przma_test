defmodule Alem.Schemas.Document do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @folders     ~w(personal private public)
  @categories  ~w(images videos audio documents encrypted)

  schema "documents" do
    field :tenant_id,      :string
    field :user_id,        :string
    field :filename,       :string
    field :content_type,   :string
    field :object_key,     :string
    field :content_hash,   :string
    field :text_content,   :string
    field :metadata,       :map
    field :status,         :string, default: "processing"
    # ── Home Folder Fields ─────────────────────────────────────────
    field :folder,         :string, default: "personal"
    # personal | private | public
    field :media_category, :string, default: "documents"
    # images | videos | audio | documents
    field :is_encrypted,   :boolean, default: false
    # true for private folder — server stores opaque ciphertext only

    timestamps(type: :utc_datetime)
  end

  def changeset(document, attrs) do
    document
    |> cast(attrs, [:id, :tenant_id, :user_id, :filename, :content_type,
                    :object_key, :content_hash, :text_content, :metadata,
                    :status, :folder, :media_category, :is_encrypted])
    |> validate_required([:id, :tenant_id, :user_id, :filename])
    |> validate_inclusion(:folder, @folders)
    |> validate_inclusion(:media_category, @categories)
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  @doc """
  Derives the S3 sub-folder from a MIME content_type string.
    image/png   → images
    video/mp4   → videos
    audio/mpeg  → audio
    application/pdf → documents
    (everything else) → documents
  """
  def media_category(ct) when is_binary(ct) do
    cond do
      String.starts_with?(ct, "image/")  -> "images"
      String.starts_with?(ct, "video/")  -> "videos"
      String.starts_with?(ct, "audio/")  -> "audio"
      String.contains?(ct, "pdf")        -> "documents"
      String.contains?(ct, "word")       -> "documents"
      String.contains?(ct, "text")       -> "documents"
      true                               -> "documents"
    end
  end
  def media_category(_), do: "documents"

  @doc """
  Builds the canonical S3 object key.
    user/{namespace_prefix}/{folder}/{category}/{doc_id}/{filename}

  Examples:
    user/CZNkZ0P5pAzWGLtM/personal/images/uuid/photo.png
    user/CZNkZ0P5pAzWGLtM/public/videos/uuid/talk.mp4
    user/CZNkZ0P5pAzWGLtM/private/encrypted/uuid/note.enc
  """
  def s3_key(namespace_prefix, folder, doc_id, filename, content_type) do
    category =
      if folder == "private",
        do: "encrypted",
        else: media_category(content_type)

    "user/#{namespace_prefix}/#{folder}/#{category}/#{doc_id}/#{filename}"
  end
end
