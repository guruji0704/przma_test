defmodule AlemWeb.Vault.Helpers do
  import Ecto.Query
  alias Alem.{Auth, Repo}
  alias Alem.Schemas.{Document, VaultShare}
  require Logger

  def get_current_user(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> Auth.verify_token(token)
      _                        -> {:error, :missing_token}
    end
  end

  def list_vault_files(user_id, vault_category) do
    Repo.all(
      from d in Document,
        where: d.user_id == ^user_id and d.vault_category == ^vault_category,
        order_by: [desc: d.inserted_at],
        select: %{
          id:            d.id,
          filename:      d.filename,
          content_type:  d.content_type,
          object_key:    d.object_key,
          content_hash:  d.content_hash,
          vault_category: d.vault_category,
          status:        d.status,
          inserted_at:   d.inserted_at,
          updated_at:    d.updated_at
        }
    )
  end

  def get_vault_file(user_id, doc_id) do
    Repo.one(from d in Document,
      where: d.id == ^doc_id and d.user_id == ^user_id)
  end

  def delete_vault_file(user_id, doc_id) do
    case Repo.one(from d in Document,
           where: d.id == ^doc_id and d.user_id == ^user_id) do
      nil -> {:error, :not_found}
      doc ->
        bucket = System.get_env("AWS_S3_BUCKET", "perkeep")
        if doc.object_key do
          ExAws.S3.delete_object(bucket, doc.object_key)
          |> ExAws.request(virtual_host: false)
        end
        Repo.delete!(doc)
        :ok
    end
  end

  def presigned_url(object_key) do
    Alem.Storage.ObjectStore.presigned_download_url(
      System.get_env("AWS_S3_BUCKET", "perkeep"),
      object_key
    )
  end

  def create_share(owner_user_id, doc_id, target_vault, params) do
    case Repo.one(from d in Document,
           where: d.id == ^doc_id and d.user_id == ^owner_user_id) do
      nil -> {:error, :not_found}
      doc ->
        token      = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
        expires_in = Map.get(params, "expires_in", 86_400)
        expires_at = DateTime.add(DateTime.utc_now(), expires_in, :second)
                     |> DateTime.truncate(:second)

        Repo.insert(%VaultShare{
          owner_user_id:    owner_user_id,
          doc_id:           doc_id,
          source_vault:     doc.vault_category,
          target_vault:     target_vault,
          source_s3_key:    doc.object_key,
          filename:         doc.filename,
          content_type:     doc.content_type,
          recipient_user_id: Map.get(params, "recipient_user_id"),
          share_token:      token,
          permission:       Map.get(params, "permission", "read"),
          expires_at:       expires_at
        })
    end
  end

  def resolve_share(share_token, requesting_user_id, expected_target_vault) do
    case Repo.one(from s in VaultShare,
           where: s.share_token == ^share_token) do
      nil   -> {:error, :not_found}
      share ->
        cond do
          share.revoked_at != nil ->
            {:error, :revoked}
          share.expires_at != nil and
            DateTime.compare(share.expires_at, DateTime.utc_now()) == :lt ->
            {:error, :expired}
          share.target_vault != expected_target_vault ->
            {:error, :wrong_vault}
          share.recipient_user_id != nil and
            share.recipient_user_id != requesting_user_id ->
            {:error, :unauthorized}
          true ->
            {:ok, share}
        end
    end
  end

  def list_outgoing_shares(user_id) do
    Repo.all(from s in VaultShare,
      where: s.owner_user_id == ^user_id and is_nil(s.revoked_at),
      order_by: [desc: s.inserted_at])
  end

  def list_incoming_shares(user_id) do
    Repo.all(from s in VaultShare,
      where: s.recipient_user_id == ^user_id and is_nil(s.revoked_at),
      order_by: [desc: s.inserted_at])
  end

  def revoke_share(share_id, owner_user_id) do
    case Repo.one(from s in VaultShare,
           where: s.share_id == ^share_id and s.owner_user_id == ^owner_user_id) do
      nil   -> {:error, :not_found}
      share ->
        Repo.update!(Ecto.Changeset.change(share, revoked_at: DateTime.utc_now() |> DateTime.truncate(:second)))
        :ok
    end
  end
end
