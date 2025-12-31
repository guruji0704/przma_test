defmodule Alem.Storage.ObjectStore do
  @moduledoc """
  S3/Linode Object Storage Integration
  """

  require Logger

  @doc """
  Upload a file to S3/Linode Object Storage
  """
  def put(bucket, key, content, opts \\ %{}) do
    Logger.info("[ObjectStore] Uploading to #{bucket}/#{key}")

    request = ExAws.S3.put_object(
      bucket,
      key,
      content,
      content_type: opts[:content_type] || "application/octet-stream",
      meta: opts[:metadata] || %{}
    )

    case ExAws.request(request) do
      {:ok, _response} ->
        Logger.info("[ObjectStore] ✅ Upload successful: #{bucket}/#{key}")
        :ok
      {:error, reason} ->
        Logger.error("[ObjectStore] ❌ Upload failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Download a file from S3
  """
  def get(bucket, key) do
    Logger.info("[ObjectStore] Downloading #{bucket}/#{key}")

    request = ExAws.S3.get_object(bucket, key)

    case ExAws.request(request) do
      {:ok, %{body: body}} ->
        Logger.info("[ObjectStore] ✅ Download successful")
        {:ok, body}
      {:error, reason} ->
        Logger.error("[ObjectStore] ❌ Download failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Delete a file from S3
  """
  def delete(bucket, key) do
    Logger.info("[ObjectStore] Deleting #{bucket}/#{key}")

    request = ExAws.S3.delete_object(bucket, key)

    case ExAws.request(request) do
      {:ok, _} ->
        Logger.info("[ObjectStore] ✅ Delete successful")
        :ok
      {:error, reason} ->
        Logger.error("[ObjectStore] ❌ Delete failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  List objects in a bucket with prefix
  """
  def list(bucket, prefix \\ "") do
    Logger.info("[ObjectStore] Listing #{bucket}/#{prefix}")

    request = ExAws.S3.list_objects_v2(bucket, prefix: prefix)

    case ExAws.request(request) do
      {:ok, %{body: body}} ->
        objects = body
        |> Map.get(:contents, [])
        |> Enum.map(fn obj ->
          %{
            key: obj.key,
            size: obj.size,
            last_modified: obj.last_modified
          }
        end)

        Logger.info("[ObjectStore] ✅ Found #{length(objects)} objects")
        {:ok, objects}

      {:error, reason} ->
        Logger.error("[ObjectStore] ❌ List failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Generate presigned URL for upload
  """
  def presigned_upload_url(bucket, key, opts \\ []) do
    expires_in = Keyword.get(opts, :expires_in, 3600)

    {:ok, url} = ExAws.S3.presigned_url(
      ExAws.Config.new(:s3),
      :put,
      bucket,
      key,
      expires_in: expires_in
    )

    {:ok, url}
  end

  @doc """
  Generate presigned URL for download
  """
  def presigned_download_url(bucket, key, opts \\ []) do
    expires_in = Keyword.get(opts, :expires_in, 3600)

    {:ok, url} = ExAws.S3.presigned_url(
      ExAws.Config.new(:s3),
      :get,
      bucket,
      key,
      expires_in: expires_in
    )

    {:ok, url}
  end
end
