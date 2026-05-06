defmodule Alem.Home.Access do
  @moduledoc """
  Generates 1-hour presigned S3 URLs.
  Always verifies ownership or valid share token before granting access.
  Never gives permanent access — every URL expires in 1 hour.
  """

  import Ecto.Query
  alias Alem.{Repo, Schemas.Document, Schemas.ShareToken}
  require Logger

  @bucket System.get_env("AWS_S3_BUCKET", "perkeep")
  @url_ttl 3600  # 1 hour

  @doc """
  Generate presigned URL for document owner.
  user_id must match document's user_id.
  """
  def presign(doc_id, user_id) do
    case Repo.one(from d in Document,
           where: d.id == ^doc_id and d.user_id == ^user_id) do
      nil ->
        Logger.warning("[Access] presign denied: doc #{doc_id} not owned by #{user_id}")
        {:error, :not_found}

      doc ->
        generate_presigned_url(doc)
    end
  end

  @doc """
  Generate presigned URL via share token.
  Validates: signature, expiry, revocation, target_did match.
  """
  def presign_via_token(token_id, requester_did) do
    token = Repo.get(ShareToken, token_id)

    cond do
      is_nil(token) ->
        {:error, :token_not_found}

      not ShareToken.valid?(token) ->
        {:error, :token_expired_or_revoked}

      token.target_did != nil and token.target_did != requester_did ->
        Logger.warning("[Access] token #{token_id} target_did mismatch")
        {:error, :access_denied}

      true ->
        # Log the access
        Repo.update_all(
          from(t in ShareToken, where: t.id == ^token_id),
          set: [last_used_at: DateTime.utc_now()],
          inc: [use_count: 1]
        )

        if token.document_id do
          doc = Repo.get(Document, token.document_id)
          generate_presigned_url(doc)
        else
          # Namespace-level token — caller must request specific doc
          {:ok, :namespace_access_granted, token.namespace_key}
        end
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp generate_presigned_url(nil), do: {:error, :not_found}
  defp generate_presigned_url(%Document{object_key: nil}), do: {:error, :no_s3_key}
  defp generate_presigned_url(%Document{object_key: key} = doc) do
    host   = System.get_env("AWS_S3_ENDPOINT", "in-maa-1.linodeobjects.com")
             |> String.replace(~r/^https?:\/\//, "") |> String.trim_trailing("/")
    region = System.get_env("AWS_DEFAULT_REGION", "in-maa-1")
    cfg    = ExAws.Config.new(:s3, scheme: "https://", host: host, region: region, port: 443)

    case ExAws.S3.presigned_url(cfg, :get, @bucket, key, expires_in: @url_ttl) do
      {:ok, url} ->
        url = String.replace(url, ~r/^http:\/\//, "https://")
        {:ok, %{url: url, expires_in: @url_ttl, filename: doc.filename,
                content_type: doc.content_type, is_encrypted: doc.is_encrypted}}

      error ->
        Logger.error("[Access] presign failed for #{key}: #{inspect(error)}")
        {:error, :presign_failed}
    end
  end
end
