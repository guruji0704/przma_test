defmodule AlemWeb.FileController do
  @moduledoc """
  Serves secure presigned S3 URLs for files belonging to the logged-in user.
  Never exposes raw S3 paths or allows cross-user access.
  """
  use AlemWeb, :controller
  import Ecto.Query
  alias Alem.Repo
  alias Alem.Schemas.Document
  require Logger

  # GET /api/v1/files/:id/url
  def presign(conn, %{"id" => doc_id}) do
    user_id = get_session(conn, :user_id)

    if is_nil(user_id) do
      conn |> put_status(401) |> json(%{error: "Unauthorized"})
    else
      case Repo.one(
        from d in Document,
        where: d.id == ^doc_id and d.user_id == ^user_id,
        select: %{id: d.id, filename: d.filename, content_type: d.content_type,
                  object_key: d.object_key, status: d.status,
                  inserted_at: d.inserted_at}
      ) do
        nil ->
          conn |> put_status(404) |> json(%{error: "File not found"})

        doc ->
          case generate_presigned_url(doc.object_key) do
            {:ok, url} ->
              json(conn, %{
                url:          url,
                filename:     doc.filename,
                content_type: doc.content_type,
                status:       doc.status
              })

            {:error, reason} ->
              Logger.error("Presign failed: #{inspect(reason)}")
              conn |> put_status(500) |> json(%{error: "Could not generate download URL"})
          end
      end
    end
  end

  defp generate_presigned_url(nil), do: {:error, :no_key}
  defp generate_presigned_url(object_key) do
    bucket = System.get_env("AWS_S3_BUCKET", "perkeep")
    config = ExAws.Config.new(:s3,
      host:   System.get_env("AWS_S3_ENDPOINT", "in-maa-1.linodeobjects.com")
              |> String.replace(~r/^https?:\/\//, ""),
      region: System.get_env("AWS_DEFAULT_REGION", "in-maa-1")
    )
    ExAws.S3.presigned_url(config, :get, bucket, object_key, expires_in: 3600)
  end
end