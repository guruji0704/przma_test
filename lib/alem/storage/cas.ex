# lib/alem/storage/cas.ex
defmodule Alem.Storage.CAS do
  @moduledoc """
  Content Addressable Storage.
  Files stored by SHA-256 hash. Same content = same hash = stored once.
  """

  require Logger
  # import Ecto.Query
  alias Alem.{Repo, Storage.ObjectStore}
  alias Alem.Schemas.CasObject

  @bucket System.get_env("AWS_S3_BUCKET", "perkeep")

  # Called content_hash in the table — key fact:
  # two users uploading the same file get the same hash
  # and only ONE S3 upload happens

  def put(data, media_type \\ "application/octet-stream") do
    hash = compute_hash(data)

    case Repo.get(CasObject, hash) do
      nil ->
        # New content — upload to S3
        s3_key = "cas/#{String.slice(hash, 0, 2)}/#{String.slice(hash, 2, 2)}/#{hash}"
        Logger.info("[CAS] New content #{hash} — uploading to S3")

        case ObjectStore.put(@bucket, s3_key, data, %{content_type: media_type}) do
          :ok ->
            attrs = %{
              content_hash: hash,
              storage_backend: "s3",
              storage_key: s3_key,
              media_type: media_type,
              file_size: byte_size(data),
              ref_count: 1
            }

            case Repo.insert(CasObject.changeset(%CasObject{}, attrs)) do
              {:ok, cas_obj} ->
                Logger.info("[CAS] Stored #{hash} (#{byte_size(data)} bytes)")
                {:ok, cas_obj}
              {:error, cs} ->
                {:error, cs}
            end

          {:error, reason} ->
            {:error, reason}
        end

      existing ->
        # Already exists — increment ref_count, skip S3 upload
        Logger.info("[CAS] Dedup hit for #{hash} — reusing existing object")
        existing
        |> Ecto.Changeset.change(ref_count: existing.ref_count + 1)
        |> Repo.update()
    end
  end

  def get_signed_url(content_hash, expires_in \\ 3600) do
    case Repo.get(CasObject, content_hash) do
      nil ->
        {:error, :not_found}
      cas_obj ->
        ObjectStore.presigned_download_url(@bucket, cas_obj.storage_key,
          expires_in: expires_in)
    end
  end

  def exists?(hash), do: Repo.get(CasObject, hash) != nil

  def compute_hash(data) do
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end
end
