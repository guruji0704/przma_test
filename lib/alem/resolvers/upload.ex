# lib/alem_web/resolvers/upload.ex
defmodule AlemWeb.Resolvers.Upload do
  require Logger
  alias Alem.{Repo, Storage.CAS}
  alias Alem.Schemas.Document

  def upload(_parent, %{file: upload, filename: filename} = args, %{context: ctx}) do
    user_id   = ctx.current_user.id
    tenant_id = ctx.current_user.tenant_id
    doc_id    = args[:doc_id] || UUID.uuid4()

    # Read file bytes
    {:ok, data} = File.read(upload.path)
    media_type = upload.content_type || "application/octet-stream"

    # CAS: compute hash, check if exists, store if not
    was_duplicate = CAS.exists?(CAS.compute_hash(data))

    case CAS.put(data, media_type) do
      {:ok, cas_obj} ->
        # Create document record pointing to the CAS object
        attrs = %{
          id:             doc_id,
          user_id:        user_id,
          tenant_id:      tenant_id,
          filename:       filename,
          content_hash:   cas_obj.content_hash,
          content_type:   media_type,
          file_size:      byte_size(data),
          metadata:       args[:metadata] || %{},
          status:         "synced",
          activity_verb:  "Create",
          actor_id:       user_id
        }

        case Repo.insert(Document.changeset(%Document{}, attrs)) do
          {:ok, doc} ->
            Logger.info("[Upload] Document #{doc_id} created (dedup=#{was_duplicate})")

            # Push to subscription if not duplicate
            if not was_duplicate do
              Absinthe.Subscription.publish(
                AlemWeb.Endpoint, doc,
                document_uploaded: "uploads:#{user_id}"
              )
            end

            {:ok, %{
              document:     doc,
              content_hash: cas_obj.content_hash,
              is_duplicate: was_duplicate,
              bytes_saved:  if(was_duplicate, do: byte_size(data), else: 0)
            }}

          {:error, changeset} ->
            {:error, "Failed to create document: #{inspect(changeset.errors)}"}
        end

      {:error, reason} ->
        {:error, "CAS storage failed: #{inspect(reason)}"}
    end
  end
end
